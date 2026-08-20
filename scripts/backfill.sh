#!/bin/bash

# backfill.sh — Historical chained PR scan.
# Reviews every MERGED PR of a repository sequentially (oldest to newest), carrying a
# budget-bounded findings ledger forward from one review to the next. Resumable: PRs
# already recorded in the pr_reviews table are skipped.

# Source env vars for cron
if [ -f /etc/environment ]; then
    . /etc/environment
fi

source /app/scripts/db_helper.sh

CURRENT_REPO="$1"
START_ARG="$2"
END_ARG="$3"

if [ -z "$CURRENT_REPO" ]; then
    echo "Usage: $0 <repository> [start] [end]"
    echo "  start/end: a PR number (e.g. 42) or a date (e.g. 2023-01-01). Optional."
    echo "Example: $0 cashubtc/nutshell            # every merged PR, from the beginning"
    echo "Example: $0 cashubtc/nutshell 100 500    # merged PRs between PR #100 and PR #500"
    echo "Example: $0 cashubtc/nutshell 2023-01-01 # merged PRs since 2023-01-01"
    exit 1
fi

# Sanitize repo for SQL interpolation (same pattern as migrate_db.sh)
CURRENT_REPO=$(echo "$CURRENT_REPO" | tr -d "'")

if [ -z "$GITHUB_TOKEN" ]; then
    echo "ERROR: GITHUB_TOKEN must be set."
    exit 1
fi

# REPORT_REPO is optional: when unset, findings are only stored in the local
# encrypted database and no report PRs are opened (local-only reporting mode).
if [ -n "$REPORT_REPO" ]; then
    SUBMISSION_SNIPPET="/app/templates/submission/remote.txt"
    echo "Reporting mode: remote (findings PRs go to $REPORT_REPO)"
else
    SUBMISSION_SNIPPET="/app/templates/submission/local.txt"
    echo "Reporting mode: local (REPORT_REPO unset — findings stay in the encrypted database)"
fi

if [ -z "$OPENROUTER_API_KEY" ] && [ -z "$OPENAI_API_KEY" ] && [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$GOOGLE_API_KEY" ] && [ -z "$KIMI_API_KEY" ]; then
    echo "ERROR: At least one API key (OPENROUTER_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, GOOGLE_API_KEY, or KIMI_API_KEY) must be set."
    exit 1
fi

# Set the default model if not provided
if [ -z "$OPENCODE_MODEL" ]; then
    OPENCODE_MODEL="openrouter/anthropic/claude-3.7-sonnet"
fi

# Maximum number of entries kept in the carry-forward findings ledger
FINDINGS_BUDGET=${FINDINGS_BUDGET:-10}
if ! [[ "$FINDINGS_BUDGET" =~ ^[0-9]+$ ]] || [ "$FINDINGS_BUDGET" -lt 1 ]; then
    echo "ERROR: FINDINGS_BUDGET must be a positive integer (got '${FINDINGS_BUDGET}')."
    exit 1
fi

# Backfill reviews maintainer-merged historical PRs, so the author-association filter is
# skipped by default. Set BACKFILL_ENFORCE_AUTHOR=1 to apply ALLOWED_AUTHOR_ASSOCIATIONS.
BACKFILL_ENFORCE_AUTHOR=${BACKFILL_ENFORCE_AUTHOR:-0}
ALLOWED_AUTHOR_ASSOCIATIONS=${ALLOWED_AUTHOR_ASSOCIATIONS:-"COLLABORATOR,CONTRIBUTOR,MEMBER,OWNER"}

mkdir -p /out
cd /app

# Setup GitHub CLI auth
gh auth setup-git

echo "=================================================="
echo "Starting historical backfill job at $(date)"
echo "Repository: $CURRENT_REPO"
echo "Findings budget: $FINDINGS_BUDGET"

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

# Resolve a range bound (PR number or date string) to a YYYY-MM-DD date
resolve_bound() {
    local arg="$1"
    if [[ "$arg" =~ ^#?[0-9]+$ ]]; then
        local pr_num="${arg#\#}"
        local merged_at
        merged_at=$(gh pr view "$pr_num" -R "$CURRENT_REPO" --json mergedAt --jq '.mergedAt' 2>/dev/null)
        if [ -z "$merged_at" ] || [ "$merged_at" == "null" ]; then
            echo "ERROR: PR #${pr_num} in ${CURRENT_REPO} is not merged or does not exist." >&2
            exit 1
        fi
        date -d "$merged_at" +%Y-%m-%d
    else
        if ! date -d "$arg" >/dev/null 2>&1; then
            echo "ERROR: '$arg' is neither a PR number nor a valid date." >&2
            exit 1
        fi
        date -d "$arg" +%Y-%m-%d
    fi
}

if [ -n "$START_ARG" ]; then
    START_DATE=$(resolve_bound "$START_ARG")
else
    # Default: from the repository's creation
    START_DATE=$(gh repo view "$CURRENT_REPO" --json createdAt --jq '.createdAt' | cut -dT -f1)
fi

if [ -n "$END_ARG" ]; then
    END_DATE=$(resolve_bound "$END_ARG")
else
    END_DATE=$(date +%Y-%m-%d)
fi

echo "Scanning merged PRs in window: ${START_DATE} .. ${END_DATE}"

# List merged PRs for a merged-date window. GitHub's search API caps at 1000 results,
# so a window that hits the cap is recursively split in half to avoid missing PRs.
list_merged_window() {
    local start="$1" end="$2"
    local result count
    result=$(gh pr list -R "$CURRENT_REPO" --state merged --search "merged:${start}..${end}" \
        --limit 1000 --json number,mergedAt,headRefOid,headRefName,baseRefName 2>/dev/null)
    if [ -z "$result" ]; then
        result="[]"
    fi
    count=$(echo "$result" | jq 'length')
    if [ "$count" -lt 1000 ]; then
        echo "$result"
        return
    fi
    if [ "$start" == "$end" ]; then
        echo "WARNING: Over 1000 PRs merged on ${start} in ${CURRENT_REPO}; window cannot be split further." >&2
        echo "$result"
        return
    fi
    local start_s end_s mid mid_next
    start_s=$(date -d "$start" +%s)
    end_s=$(date -d "$end" +%s)
    mid=$(date -d "@$(( (start_s + end_s) / 2 ))" +%Y-%m-%d)
    # Guard: in a 2-day window the midpoint can equal the end date
    if [ "$mid" == "$end" ]; then
        mid=$(date -d "$end - 1 day" +%Y-%m-%d)
    fi
    mid_next=$(date -d "$mid + 1 day" +%Y-%m-%d)
    list_merged_window "$start" "$mid"
    list_merged_window "$mid_next" "$end"
}

PR_LIST_FILE=$(mktemp)
list_merged_window "$START_DATE" "$END_DATE" | jq -s 'add | unique_by(.number) | sort_by(.mergedAt)' > "$PR_LIST_FILE"

TOTAL=$(jq 'length' < "$PR_LIST_FILE")
if [ "$TOTAL" -eq 0 ]; then
    echo "No merged PRs found for $CURRENT_REPO in the given window."
    rm -f "$PR_LIST_FILE"
    exit 0
fi
echo "Found $TOTAL merged PRs to review."

# Load the carry-forward findings ledger for this repo
LEDGER_FILE="/tmp/ledger_${SAFE_REPO_NAME}.md"
# Command substitution strips trailing newlines so they don't accumulate across round-trips
printf '%s' "$(get_ledger "$CURRENT_REPO")" > "$LEDGER_FILE"

REVIEW_TIMEOUT=${REVIEW_TIMEOUT:-"30m"}
IDX=0
REVIEWED=0
SKIPPED=0

while read -r row; do
    IDX=$((IDX+1))
    (
        PR=$(echo "$row" | jq -r '.number')
        HEAD_OID=$(echo "$row" | jq -r '.headRefOid')
        HEAD_REF_NAME=$(echo "$row" | jq -r '.headRefName')
        BASE_REF_NAME=$(echo "$row" | jq -r '.baseRefName')

        echo "----------------------------------------"
        echo "[$IDX/$TOTAL] PR #$PR ($CURRENT_REPO)"

        # Use flock to ensure we don't process the same PR concurrently across sessions
        LOCK_FILE="/out/lock_${SAFE_REPO_NAME}_${PR}.lock"
        exec 8> "$LOCK_FILE"
        if ! flock -n 8; then
            echo "Skipping PR #$PR - Already being processed by another session."
            exit 2
        fi

        if [ -n "$SKIP_PRS" ] && echo "$SKIP_PRS" | tr ',' '\n' | tr -d ' ' | grep -qx "${CURRENT_REPO}#${PR}"; then
            echo "Skipping PR #$PR - Excluded by SKIP_PRS configuration."
            exit 2
        fi

        LAST_OID=$(execute_sql "SELECT head_oid FROM pr_reviews WHERE repo='${CURRENT_REPO}' AND pr_number=${PR};")
        if [ -n "$LAST_OID" ]; then
            echo "Skipping PR #$PR - Already reviewed (Hash: $LAST_OID)."
            exit 2
        fi

        if [ "$BACKFILL_ENFORCE_AUTHOR" == "1" ]; then
            AUTHOR_ASSOCIATION=$(gh api "repos/${CURRENT_REPO}/pulls/${PR}" --jq '.author_association' 2>/dev/null)
            if ! echo "$ALLOWED_AUTHOR_ASSOCIATIONS" | tr ',' '\n' | grep -ixq "$AUTHOR_ASSOCIATION"; then
                echo "Skipping PR #$PR - Author association ($AUTHOR_ASSOCIATION) not in ALLOWED_AUTHOR_ASSOCIATIONS."
                exit 2
            fi
        fi

        echo "Preparing workspace for PR #$PR..."

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

        echo "Generating PR diff..."
        gh pr diff "$PR" > "$PR_WORKSPACE/.pr_diff.txt" || touch "$PR_WORKSPACE/.pr_diff.txt"

        echo "Running opencode analysis on PR #$PR (Timeout: $REVIEW_TIMEOUT)..."

        PR_REPORT="/tmp/report_${SAFE_REPO_NAME}-${PR}.txt"
        PR_METRICS="/tmp/metrics_${SAFE_REPO_NAME}_${PR}.json"
        FINDINGS_LEDGER="$LEDGER_FILE"
        FINDINGS_CONTEXT=$(cat "$LEDGER_FILE")

        # Export variables used in the prompt templates
        export CURRENT_REPO PR_REPORT PR_METRICS REPORT_REPO PR HEAD_REF_NAME BASE_REF_NAME PR_WORKSPACE
        export FINDINGS_LEDGER FINDINGS_CONTEXT FINDINGS_BUDGET

        # Render the submission phase (remote PRs vs local-only) for the prompt templates
        PR_SUBMISSION_PHASE=$(envsubst < "$SUBMISSION_SNIPPET")
        export PR_SUBMISSION_PHASE

        # Prepare runner for systemd-nspawn (same filenames the shared runner expects)
        envsubst < /app/templates/backfill/discovery_template.txt > "$PR_WORKSPACE/.opencode_discovery_prompt"
        envsubst < /app/templates/backfill/verifier_template.txt > "$PR_WORKSPACE/.opencode_verifier_prompt"
        cp /app/scripts/opencode_runner.sh "$PR_WORKSPACE/.opencode_runner.sh"

        # Generate a valid, unique machine name (alphanumeric and dashes only)
        MACHINE_NAME="bf-${PR}-$(tr -dc 'a-f0-9' < /dev/urandom | head -c 8)"

        # Run the bot in its own ephemeral nspawn container using overlayfs
        if ! timeout -k 5m "$REVIEW_TIMEOUT" systemd-nspawn --quiet --keep-unit --register=no \
            --machine="$MACHINE_NAME" \
            --volatile=overlay \
            -D /nspawn-root \
            --network-bridge=br-nspawn \
            --bind="$PR_WORKSPACE" \
            --bind=/tmp \
            -E GITHUB_TOKEN="$GITHUB_TOKEN" \
            -E OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
            -E OPENAI_API_KEY="$OPENAI_API_KEY" \
            -E ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
            -E GOOGLE_API_KEY="$GOOGLE_API_KEY" \
            -E KIMI_API_KEY="$KIMI_API_KEY" \
            -E REPORT_REPO="$REPORT_REPO" \
            -E OPENCODE_MODEL="$OPENCODE_MODEL" \
            -E PR_METRICS="$PR_METRICS" \
            -E PR_REPORT="$PR_REPORT" \
            -E FINDINGS_LEDGER="$FINDINGS_LEDGER" \
            /bin/bash -c "cd $PR_WORKSPACE && ./.opencode_runner.sh" > "/out/nspawn_${SAFE_REPO_NAME}_${PR}.log" 2>&1; then

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

        # Persist the carry-forward findings ledger (the agent maintains the file in /tmp)
        if [ -f "$LEDGER_FILE" ]; then
            put_ledger "$CURRENT_REPO" "$LEDGER_FILE"
        fi

        # Update the PR state in the database using the unified helper
        execute_sql "INSERT OR REPLACE INTO pr_reviews (repo, pr_number, head_oid) VALUES ('${CURRENT_REPO}', ${PR}, '${HEAD_OID}');"

        # Cleanup
        cd /app
        rm -rf "$PR_WORKSPACE"
        exit 0
    )
    case $? in
        0) REVIEWED=$((REVIEWED+1)) ;;
        2) SKIPPED=$((SKIPPED+1)) ;;
        *) SKIPPED=$((SKIPPED+1)) ;;
    esac
done < <(jq -c '.[]' "$PR_LIST_FILE")

rm -f "$PR_LIST_FILE"

echo "=================================================="
echo "Backfill finished at $(date)"
echo "Repository: $CURRENT_REPO — Reviewed: $REVIEWED, Skipped: $SKIPPED, Total: $TOTAL"
echo "Current findings ledger:"
cat "$LEDGER_FILE" 2>/dev/null || echo "(empty)"
echo "=================================================="
