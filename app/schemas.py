# sourcestack-api/app/schemas.py
from typing import Optional
from pydantic import BaseModel, Field

class ParsedCandidate(BaseModel):
    """Parsed candidate information from resume."""
    drive_file_id: Optional[str] = None
    source_file: Optional[str] = None
    name: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None
    linkedin: Optional[str] = None
    github: Optional[str] = None
    confidence: float = Field(ge=0.0, le=1.0)
    errors: list[str] = Field(default_factory=list)

class BatchParseRequest(BaseModel):
    """Request model for batch parsing."""
    folder_id: str = Field(..., description="Google Drive folder ID to parse files from")
    spreadsheet_id: Optional[str] = Field(None, description="Optional Google Sheets spreadsheet ID to save results. If not provided, a new spreadsheet will be created.")

class BatchParseJobRequest(BaseModel):
    """Request model for async batch parsing job."""
    folder_id: str = Field(..., description="Google Drive folder ID to parse files from")
    spreadsheet_id: Optional[str] = Field(None, description="Optional Google Sheets spreadsheet ID to save results. If not provided, a new spreadsheet will be created.")

class JobStatus(BaseModel):
    """Job status information."""
    job_id: str
    status: str = Field(..., description="Job status: pending, processing, completed, failed, revoked")
    progress: int = Field(ge=0, le=100, description="Progress percentage")
    total_files: int = Field(ge=0, description="Total number of files to process")
    processed_files: int = Field(ge=0, description="Number of files processed so far")
    spreadsheet_id: Optional[str] = None
    results_count: Optional[int] = None
    error: Optional[str] = None

class JobSubmitResponse(BaseModel):
    """Response when submitting a job."""
    job_id: str
    status: str = "pending"
    message: str

class Health(BaseModel):
    """Health check response."""
    ok: bool

