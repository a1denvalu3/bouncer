#!/bin/bash

# Source env vars for cron
. /etc/environment

echo "=================================================="
echo "Starting PR review job at $(date)"

# Support both REPOS and REPO_NAME for backwards compatibility
if [ -z "$REPOS" ] && [ -n "$REPO_NAME" ]; then
    REPOS="$REPO_NAME"
fi

if [ -z "$REPOS" ] || [ -z "$GITHUB_TOKEN" ] || [ -z "$OPENROUTER_API_KEY" ] || [ -z "$REPORT_REPO" ]; then
    echo "ERROR: REPOS (or REPO_NAME), GITHUB_TOKEN, OPENROUTER_API_KEY, and REPORT_REPO must be set."
    exit 1
fi

# Set the default model if not provided
if [ -z "$OPENCODE_MODEL" ]; then
    OPENCODE_MODEL="openrouter/anthropic/claude-3.7-sonnet"
fi

mkdir -p /out
cd /app

# Initialize state file for tracking reviewed commits
STATE_FILE="/out/state.json"
if [ ! -f "$STATE_FILE" ]; then
    echo "{}" > "$STATE_FILE"
fi

# Setup GitHub CLI auth
gh auth setup-git

# Iterate over repos (split by comma or space)
for CURRENT_REPO in $(echo "$REPOS" | tr ',' ' ' | tr '\n' ' '); do
    echo "=================================================="
    echo "Processing repository: $CURRENT_REPO"
    
    SAFE_REPO_NAME=$(echo "$CURRENT_REPO" | tr '/' '_')
    BASE_CLONE_DIR="/app/target-repo-${SAFE_REPO_NAME}"
    
    # Clone repository if it doesn't exist, else fetch latest
    if [ ! -d "$BASE_CLONE_DIR" ]; then
        echo "Cloning $CURRENT_REPO..."
        if ! gh repo clone "$CURRENT_REPO" "$BASE_CLONE_DIR"; then
            echo "Failed to clone $CURRENT_REPO. Skipping..."
            continue
        fi
    fi

    cd "$BASE_CLONE_DIR" || continue
    
    if ! git fetch origin; then
        echo "Failed to fetch origin for $CURRENT_REPO. Skipping..."
        continue
    fi

    # Get list of open PRs updated within the configured time window
    PR_MAX_AGE=${PR_MAX_AGE:-"4 months"}
    CUTOFF_DATE=$(date -d "${PR_MAX_AGE} ago" +%Y-%m-%d)
    echo "Looking for open PRs updated since ${CUTOFF_DATE} (Max age: ${PR_MAX_AGE})..."

    PR_DATA=$(gh pr list --search "state:open updated:>=${CUTOFF_DATE}" --json number,headRefOid,headRefName)

    if [ -z "$PR_DATA" ] || [ "$PR_DATA" == "[]" ]; then
        echo "No recent open PRs found for $CURRENT_REPO."
        continue
    fi

    # Iterate over each PR using jq and run in parallel
    for row in $(echo "${PR_DATA}" | jq -r '.[] | @base64'); do
        (
            _jq() {
             echo ${row} | base64 --decode | jq -r ${1}
            }

            PR=$(_jq '.number')
            HEAD_OID=$(_jq '.headRefOid')
            HEAD_REF_NAME=$(_jq '.headRefName')
            
            # Use flock to ensure we don't process the same PR concurrently across different cron runs
            LOCK_FILE="/out/lock_${SAFE_REPO_NAME}_${PR}.lock"
            exec 8> "$LOCK_FILE"
            if ! flock -n 8; then
                echo "----------------------------------------"
                echo "Skipping PR #$PR for $CURRENT_REPO - Already being processed by another session."
                exit 0
            fi

            if [ -n "$SKIP_PRS" ] && echo "$SKIP_PRS" | tr ',' '\n' | tr -d ' ' | grep -qx "${CURRENT_REPO}#${PR}"; then
                echo "----------------------------------------"
                echo "Skipping PR #$PR for $CURRENT_REPO - Excluded by SKIP_PRS configuration."
                exit 0
            fi
            
            LAST_OID=$(jq -r ".[\"${CURRENT_REPO}_${PR}\"] // empty" "$STATE_FILE")
            
            if [ "$HEAD_OID" == "$LAST_OID" ]; then
                echo "----------------------------------------"
                echo "Skipping PR #$PR for $CURRENT_REPO - No new commits since last review (Hash: $HEAD_OID)."
                exit 0
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

            echo "Running opencode analysis on PR #$PR for $CURRENT_REPO..."
            
            PR_REPORT="/out/report_${SAFE_REPO_NAME}_${PR}.txt"
            
            # Export variables used in the prompt template
            export CURRENT_REPO PR_REPORT REPORT_REPO PR HEAD_REF_NAME PR_WORKSPACE

            # Prepare runner for systemd-nspawn
            envsubst < /app/prompt_template.txt > "$PR_WORKSPACE/.opencode_prompt"
            cp /app/opencode_runner.sh "$PR_WORKSPACE/.opencode_runner.sh"

            # Run the bot in its own ephemeral nspawn container
            systemd-nspawn --ephemeral --quiet --keep-unit --register=no \
                -D /nspawn-root \
                --bind="$PR_WORKSPACE" \
                --bind=/out \
                -E GITHUB_TOKEN="$GITHUB_TOKEN" \
                -E OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
                -E REPORT_REPO="$REPORT_REPO" \
                -E OPENCODE_MODEL="$OPENCODE_MODEL" \
                /bin/bash -c "cd $PR_WORKSPACE && ./.opencode_runner.sh"

            # Handle the permanent storage requirement safely
            if [ -f "$PR_REPORT" ]; then
                TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                REPORT_DIR="/out/${SAFE_REPO_NAME}/${PR}"
                mkdir -p "$REPORT_DIR"
                FINAL_REPORT_PATH="${REPORT_DIR}/${TIMESTAMP}.txt"
                
                mv "$PR_REPORT" "$FINAL_REPORT_PATH"
                echo "✅ Report for PR #$PR saved to: $FINAL_REPORT_PATH"
            else
                echo "⚠️ No report was generated for PR #$PR by opencode."
            fi
            
            # Update the state file with the new commit hash safely using a lock
            (
                flock -x 9
                jq ".[\"${CURRENT_REPO}_${PR}\"] = \"${HEAD_OID}\"" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            ) 9>"${STATE_FILE}.lock"

            # Cleanup
            cd /app
            rm -rf "$PR_WORKSPACE"
        ) &
    done
done

# Wait for all background processes to finish
wait

echo "Finished PR review job at $(date)"
echo "=================================================="
