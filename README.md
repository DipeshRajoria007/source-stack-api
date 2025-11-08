# SourceStack API

Production-ready FastAPI service for parsing resumes from Google Drive and extracting structured candidate information.

## Features

- PDF text extraction with OCR fallback for image-only PDFs
- DOCX parsing support
- Field extraction: name, email, phone, LinkedIn, GitHub
- Confidence scoring
- API key authentication
- Batch processing with per-file error handling
- **Scalable parallel processing** for large Google Drive folders
- **Automatic retry** with exponential backoff for rate limits
- **Incremental spreadsheet writes** to handle thousands of files
- **Queue-based async processing** with Celery for long-running jobs
- **Job status tracking** and progress monitoring
- Docker support

## Quick Start

### Local Development

1. Create a virtual environment:
```bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

3. Set up environment variables:
```bash
cp .env.example .env
# Edit .env with your API_KEY and CORS_ALLOW_ORIGINS
```

4. Start Redis (required for async job processing):
```bash
make redis
# Or: docker run -d --name redis-sourcestack -p 6379:6379 redis:7-alpine
```

5. Run the server:
```bash
make dev
# Or: uvicorn app.main:app --reload
```

6. (Optional) Start Celery worker for async job processing:
```bash
# In a separate terminal
make worker
# Or: celery -A app.celery_app worker --loglevel=info
```

The API will be available at `http://localhost:8000`

**Note:** For async job processing (recommended for large folders), you need both Redis and a Celery worker running.

### Docker

1. Build the image:
```bash
make build
# Or: docker build -t sourcestack-api .
```

2. Run the container:
```bash
make run
# Or: docker run -p 8000:8000 --env-file .env sourcestack-api
```

**Note:** Tesseract OCR is pre-installed in the Docker image. For local development, install it:
- macOS: `brew install tesseract`
- Ubuntu/Debian: `sudo apt-get install tesseract-ocr`
- Windows: Download from [GitHub](https://github.com/UB-Mannheim/tesseract/wiki)

## API Endpoints

### Health Check

```bash
curl http://localhost:8000/health
```

Response:
```json
{"ok": true}
```

### Parse Single Resume

```bash
curl -X POST http://localhost:8000/parse \
  -H "X-API-Key: dev-api-key" \
  -F "file=@resume.pdf"
```

Response:
```json
{
  "drive_file_id": null,
  "source_file": "resume.pdf",
  "name": "John Doe",
  "email": "john.doe@example.com",
  "phone": "+919876543210",
  "confidence": 0.95,
  "errors": []
}
```

### Batch Parse Resumes

```bash
curl -X POST http://localhost:8000/batch-parse \
  -H "X-API-Key: dev-api-key" \
  -H "X-Google-Bearer: <google_access_token>" \
  -H "Content-Type: application/json" \
  -d '{
    "folder_id": "1Abc123XYZ",
    "spreadsheet_id": "optional_existing_spreadsheet_id"
  }'
```

The API will automatically:
1. List all PDF and DOCX files in the specified Google Drive folder
2. Download each file
3. Parse each resume and extract candidate information
4. Save results to a Google Sheets spreadsheet (creates new one if `spreadsheet_id` not provided)

**Spreadsheet Columns:**
- Name
- Resume Link (Google Drive link to the resume file)
- Phone Number
- Email ID
- LinkedIn
- GitHub

Response:
```json
[
  {
    "drive_file_id": "1Abc",
    "source_file": "Jane_Doe.pdf",
    "name": "Jane Doe",
    "email": "jane.doe@example.com",
    "phone": "+919876543210",
    "confidence": 0.92,
    "errors": []
  },
  {
    "drive_file_id": "1Xyz",
    "source_file": "John_Smith.docx",
    "name": "John Smith",
    "email": "john.smith@example.com",
    "phone": "+919876543211",
    "confidence": 0.88,
    "errors": []
  }
]
```

**Note:** The `X-Google-Bearer` header is required to access Google Drive. The token is used per-request and never persisted. Only PDF and DOCX files in the folder will be processed.

**Scalability Features:**
- **Parallel Processing**: Files are processed concurrently with configurable limits to handle large folders efficiently
- **Incremental Writes**: Results are written to the spreadsheet in batches to avoid memory issues
- **Automatic Retries**: Failed requests are automatically retried with exponential backoff for rate limits and transient errors
- **Per-File Error Handling**: Individual file failures don't stop the entire batch processing
- **Progress Logging**: Detailed logging shows progress as files are processed

For folders with thousands of files, adjust `MAX_CONCURRENT_REQUESTS` based on your server capacity and Google Drive API quotas.

### Async Batch Parse (Recommended for Large Folders)

For folders with 100+ files, use the async job-based endpoint:

```bash
# Submit job
curl -X POST http://localhost:8000/batch-parse-job \
  -H "X-API-Key: dev-api-key" \
  -H "X-Google-Bearer: <google_access_token>" \
  -H "Content-Type: application/json" \
  -d '{
    "folder_id": "1Abc123XYZ",
    "spreadsheet_id": "optional_existing_spreadsheet_id"
  }'
```

Response:
```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "pending",
  "message": "Job submitted successfully. Use /batch-parse-job/{job_id}/status to check progress."
}
```

**Check job status:**
```bash
curl -X GET http://localhost:8000/batch-parse-job/{job_id}/status \
  -H "X-API-Key: dev-api-key"
```

Response:
```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "processing",
  "progress": 45,
  "total_files": 1000,
  "processed_files": 450,
  "spreadsheet_id": "1xyz789ABC",
  "results_count": null,
  "error": null
}
```

**Get results (when completed):**
```bash
curl -X GET http://localhost:8000/batch-parse-job/{job_id}/results \
  -H "X-API-Key: dev-api-key"
```

**Benefits of async job processing:**
- ✅ Returns immediately (no HTTP timeout)
- ✅ Progress tracking via status endpoint
- ✅ Scales horizontally with multiple workers
- ✅ Job persistence (survives server restarts)
- ✅ Better resource management
- ✅ Can handle thousands of files without blocking

**When to use which endpoint:**
- `/batch-parse`: Synchronous, good for small batches (< 100 files)
- `/batch-parse-job`: Async, recommended for large batches (100+ files)

## Environment Variables

- `API_KEY`: API key for authentication (required)
- `CORS_ALLOW_ORIGINS`: Comma-separated list of allowed CORS origins (default: `*`)
- `REDIS_URL`: Redis connection URL for Celery broker/backend (default: `redis://localhost:6379/0`)
- `MAX_CONCURRENT_REQUESTS`: Maximum number of files to process in parallel (default: `10`)
- `SPREADSHEET_BATCH_SIZE`: Number of rows to write to spreadsheet in each batch (default: `100`)
- `MAX_RETRIES`: Maximum number of retries for failed requests (default: `3`)
- `RETRY_DELAY`: Base delay in seconds between retries, uses exponential backoff (default: `1.0`)

## Testing

Run tests:
```bash
make test
# Or: pytest tests/ -v
```

## Development

- `make dev`: Run development server with auto-reload
- `make worker`: Start Celery worker for async job processing
- `make redis`: Start Redis container (required for async jobs)
- `make lint`: Check code (placeholder)
- `make test`: Run tests
- `make build`: Build Docker image
- `make run`: Run Docker container

## Architecture

- `app/main.py`: FastAPI application and route handlers
- `app/security.py`: API key authentication
- `app/schemas.py`: Pydantic models for request/response
- `app/parsing.py`: Resume parsing logic (PDF, DOCX, OCR)
- `app/utils.py`: Utility functions (HTTP downloads)
- `app/logging_conf.py`: Structured logging configuration
- `app/celery_app.py`: Celery application configuration
- `app/tasks.py`: Celery tasks for async batch processing

## Queue-Based Processing

The service supports two modes of batch processing:

1. **Synchronous** (`/batch-parse`): Processes files in the same request, returns when done
   - Good for small batches (< 100 files)
   - Simple to use, no additional infrastructure needed
   - May timeout on very large batches

2. **Asynchronous** (`/batch-parse-job`): Submits job to queue, returns immediately
   - Recommended for large batches (100+ files)
   - Requires Redis and Celery worker
   - Provides progress tracking and better scalability
   - Can handle thousands of files without timeouts

### Setting Up Async Processing

1. **Start Redis:**
   ```bash
   make redis
   # Or use your own Redis instance
   ```

2. **Start Celery Worker:**
   ```bash
   make worker
   # Or: celery -A app.celery_app worker --loglevel=info
   ```

3. **Configure Redis URL** (if not using default):
   ```bash
   export REDIS_URL=redis://your-redis-host:6379/0
   ```

4. **Scale Workers** (optional):
   ```bash
   # Run multiple workers on different machines/ports
   celery -A app.celery_app worker --loglevel=info --concurrency=4
   ```

The system will automatically distribute jobs across available workers.

