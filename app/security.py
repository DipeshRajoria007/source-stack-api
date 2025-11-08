# sourcestack-api/app/security.py
import os
from fastapi import Header, HTTPException, status

API_KEY_HEADER = "X-API-Key"

def get_api_key() -> str:
    """Get API key from environment."""
    api_key = os.getenv("API_KEY")
    if not api_key:
        raise ValueError("API_KEY environment variable not set")
    return api_key

def verify_api_key(x_api_key: str = Header(..., alias=API_KEY_HEADER)) -> str:
    """Verify API key from header."""
    expected_key = get_api_key()
    if x_api_key != expected_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key"
        )
    return x_api_key

