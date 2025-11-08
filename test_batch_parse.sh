#!/bin/bash
API_KEY=$(grep API_KEY .env | cut -d '=' -f2)
curl -X POST http://localhost:8000/batch-parse \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "files": [
      {
        "drive_file_id": "1Abc",
        "name": "test.pdf",
        "download_url": "https://www.googleapis.com/drive/v3/files/1Abc?alt=media"
      }
    ]
  }' \
  -v
