# sourcestack-api/app/main.py
import os
import time
import logging
import asyncio
from typing import Optional
from dotenv import load_dotenv
import httpx
from fastapi import FastAPI, File, UploadFile, Depends, Header, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from .schemas import (
    ParsedCandidate, 
    BatchParseRequest, 
    BatchParseJobRequest,
    JobStatus,
    JobSubmitResponse,
    Health
)
from .security import verify_api_key
from .parsing import parse_resume_bytes
from .utils import (
    download_with_bearer, 
    list_drive_folder_files, 
    download_drive_file,
    get_drive_file_url,
    create_spreadsheet,
    write_to_spreadsheet
)
from .logging_conf import setup_logging, log_parse_result
from .celery_app import celery_app
from .tasks import batch_parse_task

logger = logging.getLogger(__name__)

# Load environment variables from .env file
load_dotenv()

# Setup logging
setup_logging()

# Configuration for scalability
MAX_CONCURRENT_REQUESTS = int(os.getenv("MAX_CONCURRENT_REQUESTS", "10"))  # Max parallel file processing
SPREADSHEET_BATCH_SIZE = int(os.getenv("SPREADSHEET_BATCH_SIZE", "100"))  # Write to spreadsheet in batches
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))  # Retry failed requests
RETRY_DELAY = float(os.getenv("RETRY_DELAY", "1.0"))  # Delay between retries (seconds)

# Create FastAPI app
app = FastAPI(title="SourceStack API", version="1.0.0")

# CORS configuration
cors_origins = os.getenv("CORS_ALLOW_ORIGINS", "*")
if cors_origins == "*":
    allow_origins = ["*"]
else:
    allow_origins = [origin.strip() for origin in cors_origins.split(",")]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allow_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health", response_model=Health)
async def health_check():
    """Health check endpoint."""
    return Health(ok=True)

@app.post("/parse", response_model=ParsedCandidate, dependencies=[Depends(verify_api_key)])
async def parse_resume(
    file: UploadFile = File(...)
):
    """
    Parse a single resume file uploaded via multipart form-data.
    """
    start_time = time.time()
    errors = []
    
    try:
        # Read file content
        data = await file.read()
        filename = file.filename or "unknown"
        
        # Parse resume
        parsed, parse_errors, ocr_used = parse_resume_bytes(filename, data)
        errors.extend(parse_errors)
        
        timing_ms = (time.time() - start_time) * 1000
        log_parse_result(filename, ocr_used, timing_ms, len(errors) > 0)
        
        return ParsedCandidate(
            drive_file_id=None,
            source_file=filename,
            name=parsed.get("name"),
            email=parsed.get("email"),
            phone=parsed.get("phone"),
            linkedin=parsed.get("linkedin"),
            github=parsed.get("github"),
            confidence=parsed.get("confidence", 0.0),
            errors=errors
        )
    
    except Exception as e:
        errors.append(f"Unexpected error: {str(e)}")
        timing_ms = (time.time() - start_time) * 1000
        log_parse_result(file.filename or "unknown", False, timing_ms, True)
        return ParsedCandidate(
            drive_file_id=None,
            source_file=file.filename,
            name=None,
            email=None,
            phone=None,
            linkedin=None,
            github=None,
            confidence=0.0,
            errors=errors
        )

async def process_single_file(
    file_info: dict,
    bearer_token: str,
    semaphore: asyncio.Semaphore
) -> ParsedCandidate:
    """
    Process a single file from Google Drive.
    Uses semaphore to limit concurrent requests.
    """
    async with semaphore:
        start_time = time.time()
        errors = []
        file_id = file_info.get("id")
        file_name = file_info.get("name", "unknown")
        
        # Skip if file_id is missing
        if not file_id:
            logger.warning(f"Skipping file with missing ID: {file_name}")
            return ParsedCandidate(
                drive_file_id=None,
                source_file=file_name,
                name=None,
                email=None,
                phone=None,
                linkedin=None,
                github=None,
                confidence=0.0,
                errors=["Missing file ID"]
            )
        
        # Retry logic for downloading and parsing
        for attempt in range(MAX_RETRIES):
            try:
                # Download file from Google Drive
                file_data = await download_drive_file(file_id, bearer_token)
                
                # Determine file extension from mimeType or filename
                mime_type = file_info.get("mimeType", "")
                if mime_type == "application/pdf":
                    filename = file_name if file_name.endswith(".pdf") else f"{file_name}.pdf"
                elif mime_type == "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
                    filename = file_name if file_name.endswith(".docx") else f"{file_name}.docx"
                else:
                    filename = file_name
                
                # Parse resume
                parsed, parse_errors, ocr_used = parse_resume_bytes(filename, file_data)
                errors.extend(parse_errors)
                
                timing_ms = (time.time() - start_time) * 1000
                log_parse_result(filename, ocr_used, timing_ms, len(errors) > 0)
                
                return ParsedCandidate(
                    drive_file_id=file_id,
                    source_file=file_name,
                    name=parsed.get("name"),
                    email=parsed.get("email"),
                    phone=parsed.get("phone"),
                    linkedin=parsed.get("linkedin"),
                    github=parsed.get("github"),
                    confidence=parsed.get("confidence", 0.0),
                    errors=errors
                )
            
            except httpx.HTTPStatusError as e:
                # Handle rate limiting (429) and server errors (5xx) with retry
                if e.response.status_code == 429 or (500 <= e.response.status_code < 600):
                    if attempt < MAX_RETRIES - 1:
                        wait_time = RETRY_DELAY * (2 ** attempt)  # Exponential backoff
                        logger.warning(
                            f"Retry {attempt + 1}/{MAX_RETRIES} for file {file_name} "
                            f"after {wait_time}s (status: {e.response.status_code})"
                        )
                        await asyncio.sleep(wait_time)
                        continue
                
                # Non-retryable error or max retries reached
                error_msg = f"HTTP error processing file: {e.response.status_code} - {e.response.text}"
                errors.append(error_msg)
                logger.error(f"Error processing file {file_name}: {error_msg}", exc_info=True)
                break
            
            except Exception as e:
                # Other errors - retry if it's a network/transient error
                if attempt < MAX_RETRIES - 1 and isinstance(e, (httpx.TimeoutException, httpx.NetworkError)):
                    wait_time = RETRY_DELAY * (2 ** attempt)
                    logger.warning(
                        f"Retry {attempt + 1}/{MAX_RETRIES} for file {file_name} "
                        f"after {wait_time}s (network error)"
                    )
                    await asyncio.sleep(wait_time)
                    continue
                
                # Non-retryable error or max retries reached
                error_msg = f"Error processing file: {str(e)}"
                errors.append(error_msg)
                logger.error(f"Error processing file {file_name}: {error_msg}", exc_info=True)
                break
        
        # If we get here, all retries failed
        timing_ms = (time.time() - start_time) * 1000
        log_parse_result(file_name, False, timing_ms, True)
        return ParsedCandidate(
            drive_file_id=file_id,
            source_file=file_name,
            name=None,
            email=None,
            phone=None,
            linkedin=None,
            github=None,
            confidence=0.0,
            errors=errors
        )


@app.post("/batch-parse", response_model=list[ParsedCandidate], dependencies=[Depends(verify_api_key)])
async def batch_parse_resumes(
    request: BatchParseRequest,
    x_google_bearer: Optional[str] = Header(None, alias="X-Google-Bearer")
):
    """
    Parse multiple resumes from a Google Drive folder.
    The API will fetch all PDF and DOCX files from the specified folder,
    download each file, and parse them in parallel with concurrency limits.
    
    Expected request body:
    {
        "folder_id": "google_drive_folder_id",
        "spreadsheet_id": "optional_existing_spreadsheet_id"
    }
    
    Headers:
    - X-API-Key: API key for authentication (required)
    - X-Google-Bearer: Google access token for Drive API (required)
    
    Scalability features:
    - Parallel processing with configurable concurrency limits
    - Incremental spreadsheet writes to avoid memory issues
    - Automatic retry with exponential backoff for rate limits
    - Per-file error handling (continues processing on individual failures)
    """
    if not x_google_bearer:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="X-Google-Bearer header is required to access Google Drive"
        )
    
    spreadsheet_id = request.spreadsheet_id
    results = []
    
    try:
        # List files in the folder
        logger.info(f"Listing files in folder: {request.folder_id}")
        drive_files = await list_drive_folder_files(request.folder_id, x_google_bearer)
        
        if not drive_files:
            logger.info("No files found in folder")
            return []
        
        total_files = len(drive_files)
        logger.info(f"Found {total_files} files to process")
        
        # Create spreadsheet if not provided (before processing starts)
        if not spreadsheet_id:
            spreadsheet_title = f"Resume Parse Results - {time.strftime('%Y-%m-%d %H:%M:%S')}"
            spreadsheet_id = await create_spreadsheet(spreadsheet_title, x_google_bearer)
            logger.info(f"Created new spreadsheet: {spreadsheet_id}")
            
            # Write headers immediately
            header_row = [["Name", "Resume Link", "Phone Number", "Email ID", "LinkedIn", "GitHub"]]
            await write_to_spreadsheet(spreadsheet_id, header_row, x_google_bearer)
        
        # Create semaphore to limit concurrent requests
        semaphore = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
        
        # Process files in parallel
        logger.info(f"Processing {total_files} files with max {MAX_CONCURRENT_REQUESTS} concurrent requests")
        tasks = [
            process_single_file(file_info, x_google_bearer, semaphore)
            for file_info in drive_files
        ]
        
        # Collect results as they complete
        batch_results = []
        processed_count = 0
        
        # Process in batches to write to spreadsheet incrementally
        for i in range(0, len(tasks), SPREADSHEET_BATCH_SIZE):
            batch_tasks = tasks[i:i + SPREADSHEET_BATCH_SIZE]
            batch_results = await asyncio.gather(*batch_tasks, return_exceptions=True)
            
            # Handle exceptions from gather
            for idx, result in enumerate(batch_results):
                if isinstance(result, Exception):
                    file_name = drive_files[i + idx].get("name", "unknown")
                    logger.error(f"Task exception for file {file_name}: {str(result)}", exc_info=True)
                    batch_results[idx] = ParsedCandidate(
                        drive_file_id=None,
                        source_file=file_name,
                        name=None,
                        email=None,
                        phone=None,
                        linkedin=None,
                        github=None,
                        confidence=0.0,
                        errors=[f"Task exception: {str(result)}"]
                    )
            
            # Write batch to spreadsheet incrementally
            try:
                data_rows = []
                for candidate in batch_results:
                    if isinstance(candidate, ParsedCandidate):
                        drive_file_link = ""
                        if candidate.drive_file_id:
                            drive_file_link = get_drive_file_url(candidate.drive_file_id)
                        
                        row = [
                            candidate.name or "",
                            drive_file_link,
                            candidate.phone or "",
                            candidate.email or "",
                            candidate.linkedin or "",
                            candidate.github or ""
                        ]
                        data_rows.append(row)
                
                if data_rows:
                    # Append to spreadsheet (skip_headers=True since headers already written)
                    await write_to_spreadsheet(spreadsheet_id, data_rows, x_google_bearer, skip_headers=True)
                    processed_count += len(data_rows)
                    logger.info(
                        f"Wrote batch to spreadsheet: {len(data_rows)} rows "
                        f"(total processed: {processed_count}/{total_files})"
                    )
            
            except Exception as e:
                logger.error(f"Error writing batch to spreadsheet: {str(e)}", exc_info=True)
                # Continue processing even if spreadsheet write fails
            
            # Add to results list
            results.extend(batch_results)
        
        logger.info(f"Completed processing {len(results)} files")
    
    except httpx.HTTPStatusError as e:
        logger.error(f"HTTP error accessing Google Drive: {e.response.text}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Error accessing Google Drive folder: {e.response.text}"
        )
    except Exception as e:
        logger.error(f"Unexpected error in batch-parse: {str(e)}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Unexpected error: {str(e)}"
        )
    
    return results


@app.post("/batch-parse-job", response_model=JobSubmitResponse, dependencies=[Depends(verify_api_key)])
async def submit_batch_parse_job(
    request: BatchParseJobRequest,
    x_google_bearer: Optional[str] = Header(None, alias="X-Google-Bearer")
):
    """
    Submit a batch parse job to the queue for asynchronous processing.
    Returns immediately with a job ID that can be used to check status and retrieve results.
    
    This endpoint is recommended for large folders (100+ files) as it:
    - Returns immediately without waiting for processing
    - Allows progress tracking via job status endpoint
    - Handles long-running jobs without HTTP timeouts
    - Scales horizontally with multiple Celery workers
    
    Expected request body:
    {
        "folder_id": "google_drive_folder_id",
        "spreadsheet_id": "optional_existing_spreadsheet_id"
    }
    
    Headers:
    - X-API-Key: API key for authentication (required)
    - X-Google-Bearer: Google access token for Drive API (required)
    
    Returns:
    {
        "job_id": "unique-job-id",
        "status": "pending",
        "message": "Job submitted successfully"
    }
    """
    import uuid
    import redis
    import json
    
    if not x_google_bearer:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="X-Google-Bearer header is required to access Google Drive"
        )
    
    # Generate unique job ID
    job_id = str(uuid.uuid4())
    
    # Initialize job status in Redis
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    redis_client = redis.from_url(redis_url, decode_responses=True)
    
    # Get current timestamp in ISO format
    from datetime import datetime
    created_at = datetime.utcnow().isoformat() + "Z"
    
    redis_client.setex(
        f"job:{job_id}:status",
        3600,  # 1 hour TTL
        json.dumps({
            "status": "pending",
            "progress": 0,
            "total_files": 0,
            "processed_files": 0,
            "spreadsheet_id": request.spreadsheet_id,
            "created_at": created_at
        })
    )
    
    # Submit task to Celery
    try:
        task = batch_parse_task.delay(
            folder_id=request.folder_id,
            spreadsheet_id=request.spreadsheet_id,
            bearer_token=x_google_bearer,
            job_id=job_id
        )
        logger.info(f"Submitted batch parse job {job_id} (Celery task: {task.id})")
        
        return JobSubmitResponse(
            job_id=job_id,
            status="pending",
            message="Job submitted successfully. Use /batch-parse-job/{job_id}/status to check progress."
        )
    
    except Exception as e:
        logger.error(f"Error submitting job {job_id}: {str(e)}", exc_info=True)
        # Update status to failed with timestamp
        from datetime import datetime
        completed_at = datetime.utcnow().isoformat() + "Z"
        redis_client.setex(
            f"job:{job_id}:status",
            3600,
            json.dumps({
                "status": "failed",
                "error": str(e),
                "progress": 0,
                "total_files": 0,
                "processed_files": 0,
                "created_at": created_at,
                "completed_at": completed_at
            })
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to submit job: {str(e)}"
        )


@app.get("/batch-parse-job/{job_id}/status", response_model=JobStatus, dependencies=[Depends(verify_api_key)])
async def get_job_status(job_id: str):
    """
    Get the status of a batch parse job.
    
    Returns:
    {
        "job_id": "job-id",
        "status": "pending|processing|completed|failed|revoked",
        "progress": 0-100,
        "total_files": 1000,
        "processed_files": 500,
        "spreadsheet_id": "spreadsheet-id",
        "results_count": 1000,
        "error": null
    }
    """
    import redis
    import json
    
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    redis_client = redis.from_url(redis_url, decode_responses=True)
    
    status_data = redis_client.get(f"job:{job_id}:status")
    
    if not status_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id} not found"
        )
    
    try:
        status_dict = json.loads(status_data)
        return JobStatus(job_id=job_id, **status_dict)
    except Exception as e:
        logger.error(f"Error parsing job status for {job_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error retrieving job status: {str(e)}"
        )


@app.get("/batch-parse-job/{job_id}/results", response_model=list[ParsedCandidate], dependencies=[Depends(verify_api_key)])
async def get_job_results(job_id: str):
    """
    Get the results of a completed batch parse job.
    
    Returns the list of parsed candidates. Only available if job status is "completed".
    """
    import redis
    import json
    
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    redis_client = redis.from_url(redis_url, decode_responses=True)
    
    # Check job status first
    status_data = redis_client.get(f"job:{job_id}:status")
    if not status_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id} not found"
        )
    
    status_dict = json.loads(status_data)
    if status_dict.get("status") != "completed":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Job {job_id} is not completed yet. Current status: {status_dict.get('status')}"
        )
    
    # Get results
    results_data = redis_client.get(f"job:{job_id}:results")
    if not results_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Results for job {job_id} not found"
        )
    
    try:
        results_list = json.loads(results_data)
        return [ParsedCandidate(**result) for result in results_list]
    except Exception as e:
        logger.error(f"Error parsing job results for {job_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error retrieving job results: {str(e)}"
        )

