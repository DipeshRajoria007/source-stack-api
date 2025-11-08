# sourcestack-api/app/logging_conf.py
import logging
import sys
from typing import Any

def setup_logging() -> None:
    """Configure structured logging without PII."""
    logging.basicConfig(
        level=logging.INFO,
        format='{"timestamp": "%(asctime)s", "level": "%(levelname)s", "logger": "%(name)s", "message": "%(message)s"}',
        datefmt='%Y-%m-%dT%H:%M:%S',
        stream=sys.stdout
    )

def log_parse_result(filename: str, ocr_used: bool, timing_ms: float, has_errors: bool) -> None:
    """Log parse result without PII."""
    logger = logging.getLogger("parsing")
    logger.info(
        f"Parsed file: {filename}, OCR: {ocr_used}, Timing: {timing_ms}ms, Errors: {has_errors}",
        extra={
            "file_name": filename,  # Changed from 'filename' to avoid conflict with LogRecord attribute
            "ocr_used": ocr_used,
            "timing_ms": timing_ms,
            "has_errors": has_errors
        }
    )

