# sourcestack-api/app/utils.py
import httpx
from typing import Optional, List, Dict, Any
import logging

logger = logging.getLogger(__name__)

async def download_with_bearer(url: str, bearer: Optional[str] = None) -> bytes:
    """Download file from URL with optional Bearer token."""
    headers = {}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        return response.content

async def list_drive_folder_files(folder_id: str, bearer: Optional[str] = None) -> List[Dict[str, Any]]:
    """
    List files in a Google Drive folder.
    Returns list of file info dicts with id, name, and mimeType.
    """
    headers = {}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    
    # Query for files in the folder (excluding subfolders)
    # Only get PDF and DOCX files
    query = f"'{folder_id}' in parents and trashed=false and (mimeType='application/pdf' or mimeType='application/vnd.openxmlformats-officedocument.wordprocessingml.document')"
    url = f"https://www.googleapis.com/drive/v3/files"
    params = {
        "q": query,
        "fields": "files(id,name,mimeType)",
        "pageSize": 1000  # Max allowed by Google Drive API
    }
    
    files = []
    async with httpx.AsyncClient(timeout=30.0) as client:
        while True:
            response = await client.get(url, headers=headers, params=params)
            response.raise_for_status()
            data = response.json()
            
            files.extend(data.get("files", []))
            
            # Check if there are more pages
            next_page_token = data.get("nextPageToken")
            if not next_page_token:
                break
            params["pageToken"] = next_page_token
    
    return files

async def download_drive_file(file_id: str, bearer: Optional[str] = None) -> bytes:
    """Download a file from Google Drive by file ID."""
    headers = {}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    
    url = f"https://www.googleapis.com/drive/v3/files/{file_id}?alt=media"
    
    async with httpx.AsyncClient(timeout=60.0) as client:  # Longer timeout for file downloads
        response = await client.get(url, headers=headers)
        response.raise_for_status()
        return response.content

def get_drive_file_url(file_id: str) -> str:
    """Generate Google Drive file URL from file ID."""
    return f"https://drive.google.com/file/d/{file_id}/view"

async def create_spreadsheet(title: str, bearer: Optional[str] = None) -> str:
    """Create a new Google Sheets spreadsheet and return its ID."""
    headers = {
        "Authorization": f"Bearer {bearer}",
        "Content-Type": "application/json"
    }
    
    url = "https://sheets.googleapis.com/v4/spreadsheets"
    payload = {
        "properties": {
            "title": title
        },
        "sheets": [{
            "properties": {
                "title": "Resume Data"
            }
        }]
    }
    
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(url, headers=headers, json=payload)
        response.raise_for_status()
        data = response.json()
        return data.get("spreadsheetId")

async def write_to_spreadsheet(
    spreadsheet_id: str,
    data_rows: List[List[str]],
    bearer: Optional[str] = None,
    skip_headers: bool = False
) -> None:
    """
    Write data to Google Sheets spreadsheet.
    data_rows should be a list of rows, where each row is a list of cell values.
    
    Args:
        spreadsheet_id: Google Sheets spreadsheet ID
        data_rows: List of rows to write. If skip_headers=False, first row is treated as headers.
        bearer: Google access token
        skip_headers: If True, all rows in data_rows are appended as data (no header row).
                      If False, first row is treated as headers if spreadsheet is empty.
    """
    headers = {
        "Authorization": f"Bearer {bearer}",
        "Content-Type": "application/json"
    }
    
    # Prepare values for batch update
    values = [row for row in data_rows]
    
    # Check if spreadsheet has data (to determine if we need headers)
    url = f"https://sheets.googleapis.com/v4/spreadsheets/{spreadsheet_id}/values/A1:Z1"
    async with httpx.AsyncClient(timeout=30.0) as client:
        check_response = await client.get(url, headers=headers)
        
        # If spreadsheet is empty or first row is empty, write headers + data
        # Otherwise, just append data
        if check_response.status_code == 200:
            existing_data = check_response.json().get("values", [])
            if not existing_data or not existing_data[0] or len(existing_data[0]) == 0:
                # Empty spreadsheet, write all data using PUT
                url = f"https://sheets.googleapis.com/v4/spreadsheets/{spreadsheet_id}/values/A1"
                params = {
                    "valueInputOption": "USER_ENTERED"
                }
                body = {
                    "values": values
                }
                async with httpx.AsyncClient(timeout=30.0) as client:
                    response = await client.put(url, headers=headers, params=params, json=body)
                    response.raise_for_status()
                return
            else:
                # Has data, append new rows
                if skip_headers:
                    # All rows are data rows, append all
                    rows_to_append = values
                else:
                    # First row is headers, skip it
                    rows_to_append = values[1:] if len(values) > 1 else []
                
                if rows_to_append:
                    url = f"https://sheets.googleapis.com/v4/spreadsheets/{spreadsheet_id}/values/A:append"
                    params = {
                        "valueInputOption": "USER_ENTERED",
                        "insertDataOption": "INSERT_ROWS"
                    }
                    body = {
                        "values": rows_to_append
                    }
                    async with httpx.AsyncClient(timeout=30.0) as client:
                        response = await client.post(url, headers=headers, params=params, json=body)
                        response.raise_for_status()
                    return
                else:
                    return  # No data to append
        else:
            # Error checking, assume empty and write all using PUT
            url = f"https://sheets.googleapis.com/v4/spreadsheets/{spreadsheet_id}/values/A1"
            params = {
                "valueInputOption": "USER_ENTERED"
            }
            body = {
                "values": values
            }
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.put(url, headers=headers, params=params, json=body)
                response.raise_for_status()
            return

