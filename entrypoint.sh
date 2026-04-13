#!/bin/bash
set -e

# Make sure opencode is in the PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.opencode/bin:$PATH"

# Default sleep duration to 60 seconds if not provided
SLEEP_DURATION=${SLEEP_DURATION:-60}

echo "Starting PR reviewer in a loop with a ${SLEEP_DURATION}s sleep interval..."

while true; do
    /app/review.sh 2>&1
    
    echo "Sleeping for ${SLEEP_DURATION} seconds before next run..."
    sleep "${SLEEP_DURATION}"
done
