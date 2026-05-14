#!/bin/bash

# Obtain IP address for the container's isolated network interface
dhclient host0 >/dev/null 2>&1

gh auth setup-git
export OPENCODE_AUTO_CONFIRM=true
export OPENCODE_PERMISSION='{"external_directory": {"*": "allow"}}'

# 1. Run discovery
echo "Running discovery..."
# Create discovery prompt
envsubst < /app/templates/discovery/discovery_template.txt > .opencode_discovery_prompt
opencode run -m "$OPENCODE_MODEL" "$(cat .opencode_discovery_prompt)"

# 2. Run verifier only if discovery produced a non-empty report
if [ -f "$PR_REPORT" ] && [ -s "$PR_REPORT" ]; then
    echo "Running verification..."
    # Create verifier prompt
    envsubst < /app/templates/verifier/verifier_template.txt > .opencode_verifier_prompt
    opencode run -m "$OPENCODE_MODEL" "$(cat .opencode_verifier_prompt)"
else
    echo "No findings report to verify, skipping."
fi

# Extract token usage and cost metrics and save to the metrics file
if [ -n "$PR_METRICS" ]; then
    opencode stats | sed 's/\x1B\[[0-9;]\{1,\}[A-Za-z]//g' | tr -d '│' | awk '
    /Total Cost/ {cost=$3}
    /Input/ {input=$2}
    /Output/ {output=$2}
    /Cache Read/ {cache_read=$3}
    END {
        printf "{\"cost\":\"%s\", \"input\":\"%s\", \"output\":\"%s\", \"cache_read\":\"%s\"}\n", cost, input, output, cache_read
    }' > "$PR_METRICS"
    echo "Metrics logged to $PR_METRICS:"
    cat "$PR_METRICS"
fi
