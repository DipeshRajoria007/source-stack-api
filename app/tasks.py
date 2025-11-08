# sourcestack-api/app/tasks.py
import os
import time
import logging
import asyncio
from typing import List, Dict, Any
import httpx
from celery import Task
from .celery_app import celery_app
from .parsing import parse_resume_bytes
from .utils import (
    list_drive_folder_files,
    download_drive_file,
    get_drive_file_url,
    create_spreadsheet,
    write_to_spreadsheet
)
from .logging_conf import setup_logging, log_parse_result

# Setup logging for Celery workers
setup_logging()
logger = logging.getLogger(__name__)

# Configuration
MAX_CONCURRENT_REQUESTS = int(os.getenv("MAX_CONCURRENT_REQUESTS", "10"))
SPREADSHEET_BATCH_SIZE = int(os.getenv("SPREADSHEET_BATCH_SIZE", "100"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
RETRY_DELAY = float(os.getenv("RETRY_DELAY", "1.0"))


class CallbackTask(Task):
    """Custom task class that updates job status."""
    
    def on_success(self, retval, task_id, args, kwargs):
        """Called when task succeeds."""
        logger.info(f"Task {task_id} completed successfully")
    
    def on_failure(self, exc, task_id, args, kwargs, einfo):
        """Called when task fails."""
        logger.error(f"Task {task_id} failed: {str(exc)}", exc_info=einfo)


async def process_single_file_async(
    file_info: dict,
    bearer_token: str,
    semaphore: asyncio.Semaphore,
    job_id: str
) -> Dict[str, Any]:
    """
    Process a single file from Google Drive (async version for Celery).
    Updates job progress via Redis.
    """
    from .schemas import ParsedCandidate
    
    async with semaphore:
        start_time = time.time()
        errors = []
        file_id = file_info.get("id")
        file_name = file_info.get("name", "unknown")
        
        # Skip if file_id is missing
        if not file_id:
            logger.warning(f"Skipping file with missing ID: {file_name}")
            return {
                "drive_file_id": None,
                "source_file": file_name,
                "name": None,
                "email": None,
                "phone": None,
                "linkedin": None,
                "github": None,
                "confidence": 0.0,
                "errors": ["Missing file ID"]
            }
        
        # Retry logic
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
                
                return {
                    "drive_file_id": file_id,
                    "source_file": file_name,
                    "name": parsed.get("name"),
                    "email": parsed.get("email"),
                    "phone": parsed.get("phone"),
                    "linkedin": parsed.get("linkedin"),
                    "github": parsed.get("github"),
                    "confidence": parsed.get("confidence", 0.0),
                    "errors": errors
                }
            
            except httpx.HTTPStatusError as e:
                if e.response.status_code == 429 or (500 <= e.response.status_code < 600):
                    if attempt < MAX_RETRIES - 1:
                        wait_time = RETRY_DELAY * (2 ** attempt)
                        logger.warning(
                            f"Retry {attempt + 1}/{MAX_RETRIES} for file {file_name} "
                            f"after {wait_time}s (status: {e.response.status_code})"
                        )
                        await asyncio.sleep(wait_time)
                        continue
                
                error_msg = f"HTTP error processing file: {e.response.status_code} - {e.response.text}"
                errors.append(error_msg)
                logger.error(f"Error processing file {file_name}: {error_msg}", exc_info=True)
                break
            
            except Exception as e:
                if attempt < MAX_RETRIES - 1 and isinstance(e, (httpx.TimeoutException, httpx.NetworkError)):
                    wait_time = RETRY_DELAY * (2 ** attempt)
                    logger.warning(
                        f"Retry {attempt + 1}/{MAX_RETRIES} for file {file_name} "
                        f"after {wait_time}s (network error)"
                    )
                    await asyncio.sleep(wait_time)
                    continue
                
                error_msg = f"Error processing file: {str(e)}"
                errors.append(error_msg)
                logger.error(f"Error processing file {file_name}: {error_msg}", exc_info=True)
                break
        
        # All retries failed
        timing_ms = (time.time() - start_time) * 1000
        log_parse_result(file_name, False, timing_ms, True)
        return {
            "drive_file_id": file_id,
            "source_file": file_name,
            "name": None,
            "email": None,
            "phone": None,
            "linkedin": None,
            "github": None,
            "confidence": 0.0,
            "errors": errors
        }


@celery_app.task(bind=True, base=CallbackTask, name="app.tasks.batch_parse_task")
def batch_parse_task(
    self,
    folder_id: str,
    spreadsheet_id: str | None,
    bearer_token: str,
    job_id: str
) -> Dict[str, Any]:
    """
    Celery task to process batch of resumes from Google Drive.
    This runs in a separate worker process.
    """
    import redis
    import json
    
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    redis_client = redis.from_url(redis_url, decode_responses=True)
    
    results = []
    total_files = 0
    processed_count = 0
    
    try:
        # Update job status
        redis_client.setex(
            f"job:{job_id}:status",
            3600,  # 1 hour TTL
            json.dumps({
                "status": "processing",
                "progress": 0,
                "total_files": 0,
                "processed_files": 0,
                "spreadsheet_id": spreadsheet_id
            })
        )
        
        # List files in the folder (run async function in event loop)
        logger.info(f"[Job {job_id}] Listing files in folder: {folder_id}")
        try:
            loop = asyncio.get_event_loop()
        except RuntimeError:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
        drive_files = loop.run_until_complete(list_drive_folder_files(folder_id, bearer_token))
        
        if not drive_files:
            logger.info(f"[Job {job_id}] No files found in folder")
            redis_client.setex(
                f"job:{job_id}:status",
                3600,
                json.dumps({
                    "status": "completed",
                    "progress": 100,
                    "total_files": 0,
                    "processed_files": 0,
                    "spreadsheet_id": spreadsheet_id,
                    "results_count": 0
                })
            )
            redis_client.setex(f"job:{job_id}:results", 3600, json.dumps([]))
            return {"status": "completed", "results_count": 0}
        
        total_files = len(drive_files)
        logger.info(f"[Job {job_id}] Found {total_files} files to process")
        
        # Create spreadsheet if not provided
        if not spreadsheet_id:
            spreadsheet_title = f"Resume Parse Results - {time.strftime('%Y-%m-%d %H:%M:%S')}"
            spreadsheet_id = loop.run_until_complete(create_spreadsheet(spreadsheet_title, bearer_token))
            logger.info(f"[Job {job_id}] Created new spreadsheet: {spreadsheet_id}")
            
            # Write headers
            header_row = [["Name", "Resume Link", "Phone Number", "Email ID", "LinkedIn", "GitHub"]]
            loop.run_until_complete(write_to_spreadsheet(spreadsheet_id, header_row, bearer_token))
        
        # Update job status with spreadsheet ID
        redis_client.setex(
            f"job:{job_id}:status",
            3600,
            json.dumps({
                "status": "processing",
                "progress": 0,
                "total_files": total_files,
                "processed_files": 0,
                "spreadsheet_id": spreadsheet_id
            })
        )
        
        # Create semaphore for concurrency control
        semaphore = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
        
        # Process files in batches
        for i in range(0, len(drive_files), SPREADSHEET_BATCH_SIZE):
            batch_files = drive_files[i:i + SPREADSHEET_BATCH_SIZE]
            
            # Process batch
            tasks = [
                process_single_file_async(file_info, bearer_token, semaphore, job_id)
                for file_info in batch_files
            ]
            
            batch_results = loop.run_until_complete(asyncio.gather(*tasks, return_exceptions=True))
            
            # Handle exceptions
            for idx, result in enumerate(batch_results):
                if isinstance(result, Exception):
                    file_name = batch_files[idx].get("name", "unknown")
                    logger.error(f"[Job {job_id}] Task exception for file {file_name}: {str(result)}", exc_info=True)
                    batch_results[idx] = {
                        "drive_file_id": None,
                        "source_file": file_name,
                        "name": None,
                        "email": None,
                        "phone": None,
                        "linkedin": None,
                        "github": None,
                        "confidence": 0.0,
                        "errors": [f"Task exception: {str(result)}"]
                    }
            
            # Write batch to spreadsheet
            try:
                data_rows = []
                for candidate in batch_results:
                    if isinstance(candidate, dict):
                        drive_file_link = ""
                        if candidate.get("drive_file_id"):
                            drive_file_link = get_drive_file_url(candidate["drive_file_id"])
                        
                        row = [
                            candidate.get("name") or "",
                            drive_file_link,
                            candidate.get("phone") or "",
                            candidate.get("email") or "",
                            candidate.get("linkedin") or "",
                            candidate.get("github") or ""
                        ]
                        data_rows.append(row)
                
                if data_rows:
                    loop.run_until_complete(write_to_spreadsheet(spreadsheet_id, data_rows, bearer_token, skip_headers=True))
                    processed_count += len(data_rows)
                    logger.info(
                        f"[Job {job_id}] Wrote batch: {len(data_rows)} rows "
                        f"(total: {processed_count}/{total_files})"
                    )
            
            except Exception as e:
                logger.error(f"[Job {job_id}] Error writing batch to spreadsheet: {str(e)}", exc_info=True)
            
            # Update progress
            results.extend(batch_results)
            progress = int((processed_count / total_files) * 100) if total_files > 0 else 0
            
            redis_client.setex(
                f"job:{job_id}:status",
                3600,
                json.dumps({
                    "status": "processing",
                    "progress": progress,
                    "total_files": total_files,
                    "processed_files": processed_count,
                    "spreadsheet_id": spreadsheet_id
                })
            )
            
            # Check if task was revoked
            if self.is_aborted():
                logger.warning(f"[Job {job_id}] Task was revoked")
                redis_client.setex(
                    f"job:{job_id}:status",
                    3600,
                    json.dumps({
                        "status": "revoked",
                        "progress": progress,
                        "total_files": total_files,
                        "processed_files": processed_count,
                        "spreadsheet_id": spreadsheet_id
                    })
                )
                return {"status": "revoked", "results_count": len(results)}
        
        # Store final results
        redis_client.setex(f"job:{job_id}:results", 3600, json.dumps(results))
        
        # Update final status
        redis_client.setex(
            f"job:{job_id}:status",
            3600,
            json.dumps({
                "status": "completed",
                "progress": 100,
                "total_files": total_files,
                "processed_files": processed_count,
                "spreadsheet_id": spreadsheet_id,
                "results_count": len(results)
            })
        )
        
        logger.info(f"[Job {job_id}] Completed processing {len(results)} files")
        return {"status": "completed", "results_count": len(results)}
    
    except Exception as e:
        logger.error(f"[Job {job_id}] Unexpected error: {str(e)}", exc_info=True)
        redis_client.setex(
            f"job:{job_id}:status",
            3600,
            json.dumps({
                "status": "failed",
                "error": str(e),
                "total_files": total_files,
                "processed_files": processed_count,
                "spreadsheet_id": spreadsheet_id
            })
        )
        raise

