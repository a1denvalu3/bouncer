#!/bin/bash

set -o pipefail

# Obtain IP address for the container's isolated network interface
dhclient host0 >/dev/null 2>&1

gh auth setup-git
export OPENCODE_AUTO_CONFIRM=true
export OPENCODE_PERMISSION='{"external_directory": {"*": "allow"}}'

# 1. Run discovery
echo "Running discovery..."
echo "DEBUG: PR_REPORT is set to: $PR_REPORT"
if ! opencode run -m "$OPENCODE_MODEL" "$(cat .opencode_discovery_prompt)"; then
    echo "ERROR: OpenCode discovery failed."
    exit 1
fi

if [ ! -s "$PR_REPORT" ]; then
    echo "ERROR: OpenCode discovery completed without producing a report."
    exit 1
fi

# 2. Verify the discovery result. The verifier may delete a clean or rejected
# report; that is a successful review, distinct from discovery producing none.
echo "Running verification..."
if ! opencode run -m "$OPENCODE_MODEL" "$(cat .opencode_verifier_prompt)"; then
    echo "ERROR: OpenCode verification failed."
    exit 1
fi

# Extract token usage and cost metrics and save to the metrics file
if [ -n "$PR_METRICS" ]; then
    if ! opencode stats | sed 's/\x1B\[[0-9;]\{1,\}[A-Za-z]//g' | tr -d '│' | awk '
    /Total Cost/ {cost=$3}
    /Input/ {input=$2}
    /Output/ {output=$2}
    /Cache Read/ {cache_read=$3}
    END {
        printf "{\"cost\":\"%s\", \"input\":\"%s\", \"output\":\"%s\", \"cache_read\":\"%s\"}\n", cost, input, output, cache_read
    }' > "$PR_METRICS"; then
        echo "ERROR: Failed to collect OpenCode metrics."
        exit 1
    fi
    echo "Metrics logged to $PR_METRICS:"
    cat "$PR_METRICS"
fi
