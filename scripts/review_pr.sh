#!/bin/bash

# Source env vars for cron
if [ -f /etc/environment ]; then
    . /etc/environment
fi

source /app/scripts/db_helper.sh

CURRENT_REPO="$1"
PR="$2"

if [ -z "$CURRENT_REPO" ] || [ -z "$PR" ]; then
    echo "Usage: $0 <repository> <pr_number>"
    echo "Example: $0 cashubtc/nutshell 42"
    exit 1
fi

if [ -z "$GITHUB_TOKEN" ] || [ -z "$OPENROUTER_API_KEY" ] || [ -z "$REPORT_REPO" ]; then
    echo "ERROR: GITHUB_TOKEN, OPENROUTER_API_KEY, and REPORT_REPO must be set."
    exit 1
fi

# Set the default model if not provided
if [ -z "$OPENCODE_MODEL" ]; then
    OPENCODE_MODEL="openrouter/anthropic/claude-3.7-sonnet"
fi

mkdir -p /out
cd /app

# Setup GitHub CLI auth
gh auth setup-git

echo "=================================================="
echo "Starting single PR review job at $(date)"
echo "Repository: $CURRENT_REPO"
echo "PR Number: $PR"

SAFE_REPO_NAME=$(echo "$CURRENT_REPO" | tr '/' '_')
BASE_CLONE_DIR="/app/target-repo-${SAFE_REPO_NAME}"

# Clone repository if it doesn't exist, else fetch latest
if [ ! -d "$BASE_CLONE_DIR" ]; then
    echo "Cloning $CURRENT_REPO..."
    if ! gh repo clone "$CURRENT_REPO" "$BASE_CLONE_DIR"; then
        echo "Failed to clone $CURRENT_REPO. Exiting..."
        exit 1
    fi
fi

cd "$BASE_CLONE_DIR" || exit 1

if ! git fetch origin; then
    echo "Failed to fetch origin for $CURRENT_REPO. Exiting..."
    exit 1
fi

# Fetch specific PR details
PR_DATA=$(gh pr view "$PR" --json number,headRefOid,headRefName 2>/dev/null)

if [ -z "$PR_DATA" ]; then
    echo "PR #$PR not found in $CURRENT_REPO or other error occurred."
    exit 1
fi

HEAD_OID=$(echo "$PR_DATA" | jq -r '.headRefOid')
HEAD_REF_NAME=$(echo "$PR_DATA" | jq -r '.headRefName')

if [ -z "$HEAD_OID" ] || [ "$HEAD_OID" == "null" ]; then
    echo "Could not extract headRefOid for PR #$PR"
    exit 1
fi

LOCK_FILE="/out/lock_${SAFE_REPO_NAME}_${PR}.lock"
exec 8> "$LOCK_FILE"
if ! flock -n 8; then
    echo "----------------------------------------"
    echo "PR #$PR for $CURRENT_REPO is currently being processed by another session. Exiting."
    exit 1
fi

echo "----------------------------------------"
echo "Preparing workspace for PR #$PR in $CURRENT_REPO..."

PR_WORKSPACE="/app/target-repo-${SAFE_REPO_NAME}-${PR}"
# Copy the already fetched target-repo to save clone time
cp -a "$BASE_CLONE_DIR" "$PR_WORKSPACE"
cd "$PR_WORKSPACE"

echo "Checking out PR #$PR (Commit: $HEAD_OID)..."
if ! gh pr checkout "$PR"; then
    echo "Failed to checkout PR #$PR for $CURRENT_REPO"
    cd /app
    rm -rf "$PR_WORKSPACE"
    exit 1
fi

REVIEW_TIMEOUT=${REVIEW_TIMEOUT:-"30m"}
echo "Running opencode analysis on PR #$PR for $CURRENT_REPO (Timeout: $REVIEW_TIMEOUT)..."

PR_REPORT="/out/report_${SAFE_REPO_NAME}_${PR}.txt"
PR_METRICS="/out/metrics_${SAFE_REPO_NAME}_${PR}.json"

# Export variables used in the prompt template
export CURRENT_REPO PR_REPORT PR_METRICS REPORT_REPO PR HEAD_REF_NAME PR_WORKSPACE

# Prepare runner for systemd-nspawn
envsubst < /app/templates/prompt_template.txt > "$PR_WORKSPACE/.opencode_prompt"
cp /app/scripts/opencode_runner.sh "$PR_WORKSPACE/.opencode_runner.sh"

# Generate a valid, unique machine name (alphanumeric and dashes only)
MACHINE_NAME="pr-${PR}-$(tr -dc 'a-f0-9' < /dev/urandom | head -c 8)"

# Run the bot in its own ephemeral nspawn container using overlayfs
if ! timeout -k 5m "$REVIEW_TIMEOUT" systemd-nspawn --quiet --keep-unit --register=no \
    --machine="$MACHINE_NAME" \
    --volatile=overlay \
    -D /nspawn-root \
    --network-bridge=br-nspawn \
    --bind="$PR_WORKSPACE" \
    --bind=/out \
    -E GITHUB_TOKEN="$GITHUB_TOKEN" \
    -E OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
    -E REPORT_REPO="$REPORT_REPO" \
    -E OPENCODE_MODEL="$OPENCODE_MODEL" \
    -E PR_METRICS="$PR_METRICS" \
    /bin/bash -c "cd $PR_WORKSPACE && ./.opencode_runner.sh"; then
    
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ] || [ $EXIT_CODE -eq 137 ]; then
        echo "⚠️ Review for PR #$PR in $CURRENT_REPO timed out after $REVIEW_TIMEOUT."
    else
        echo "⚠️ Review for PR #$PR in $CURRENT_REPO failed with exit code $EXIT_CODE."
    fi
fi

# Ingest report and metrics securely into the encrypted SQL database
if [ -f "$PR_REPORT" ]; then
    execute_sql_insert_file "$CURRENT_REPO" "$PR" "$HEAD_OID" "$PR_REPORT" "$PR_METRICS"
    echo "✅ Report and metrics for PR #$PR securely saved to encrypted database."
    
    # Cleanup the flat files from the volume after successful database ingestion
    rm -f "$PR_REPORT" "$PR_METRICS"
else
    echo "⚠️ No report was generated for PR #$PR by opencode."
fi

# Update the PR state in the database using the unified helper
execute_sql "INSERT OR REPLACE INTO pr_reviews (repo, pr_number, head_oid) VALUES ('${CURRENT_REPO}', ${PR}, '${HEAD_OID}');"

# Cleanup
cd /app
rm -rf "$PR_WORKSPACE"

echo "Finished PR review job at $(date)"
echo "=================================================="