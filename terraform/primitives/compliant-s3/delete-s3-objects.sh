#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "LOG_BUCKET=$LOG_BUCKET"

if [ -z "$LOG_BUCKET" ]; then
  echo "ERROR: LOG_BUCKET is not set"
  exit 1
fi

echo "Listing object versions in bucket: $LOG_BUCKET"
aws s3api list-object-versions \
  --profile default \
  --bucket "$LOG_BUCKET" \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
  --output json > /tmp/delete.json

echo "=== Objects to delete ==="
cat /tmp/delete.json

echo ""
echo "Deleting objects..."
aws s3api delete-objects \
  --profile default \
  --bucket "$LOG_BUCKET" \
  --delete file:///tmp/delete.json || true

echo "Done!"
rm -f /tmp/delete.json
