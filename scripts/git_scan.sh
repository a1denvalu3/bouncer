#!/bin/bash

# Local-only commit reviews, used by all scanner entry points without a token.
set -eo pipefail
source /app/scripts/db_helper.sh
export REPORT_REPO=""
export GIT_TERMINAL_PROMPT=0

MODE="$1"
CURRENT_REPO="$2"
START_ARG="${3:-}"
END_ARG="${4:-}"
if ! [[ "$CURRENT_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: Repository must be specified as owner/repo."
    exit 1
fi
if [ -z "${OPENROUTER_API_KEY:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}${GOOGLE_API_KEY:-}${KIMI_API_KEY:-}${NUMES_API_KEY:-}" ]; then
    echo "ERROR: At least one inference API key must be set."
    exit 1
fi
if [ "${BACKFILL_ENFORCE_AUTHOR:-0}" == "1" ]; then
    echo "ERROR: BACKFILL_ENFORCE_AUTHOR requires a GitHub token; Git has no author-association metadata."
    exit 1
fi
FINDINGS_BUDGET=${FINDINGS_BUDGET:-10}
if ! [[ "$FINDINGS_BUDGET" =~ ^[0-9]+$ ]] || [ "$FINDINGS_BUDGET" -lt 1 ]; then
    echo "ERROR: FINDINGS_BUDGET must be a positive integer."
    exit 1
fi
OPENCODE_MODEL=${OPENCODE_MODEL:-openrouter/google/gemini-3.1-pro-preview}
REVIEW_TIMEOUT=${REVIEW_TIMEOUT:-30m}
SAFE_REPO_NAME=${CURRENT_REPO//\//_}
BASE_CLONE_DIR="/app/git-repo-${SAFE_REPO_NAME}"
# Keep the Git findings ledger separate from the authenticated PR ledger.
LEDGER_KEY="git:${CURRENT_REPO}"
mkdir -p /out
exec 8> "/out/lock_git_${SAFE_REPO_NAME}.lock"
if ! flock -n 8; then
    echo "Git scan already running for $CURRENT_REPO; skipping."
    exit 0
fi

echo "Reporting mode: local (no GitHub token; reviewing Git commits with no gh calls)"
if [ ! -d "$BASE_CLONE_DIR" ]; then
    git clone -- "https://github.com/${CURRENT_REPO}.git" "$BASE_CLONE_DIR"
fi
cd "$BASE_CLONE_DIR"
git fetch --prune origin
if [ -z "${GIT_SCAN_REF:-}" ]; then
    git remote set-head origin --auto
fi
SCAN_REF=${GIT_SCAN_REF:-origin/HEAD}
if [ "$MODE" == "continuous" ]; then
    START_ARG=$(date -d "${PR_MAX_AGE:-4 months} ago" +%Y-%m-%d)
fi
SCAN_TMP=$(mktemp -d "/tmp/bouncer-git-${SAFE_REPO_NAME}.XXXXXX")
PR_WORKSPACE=""
cleanup() {
    rm -rf "$SCAN_TMP"
    if [ -n "$PR_WORKSPACE" ]; then rm -rf "$PR_WORKSPACE"; fi
}
trap cleanup EXIT
python3 /app/scripts/git_history.py "$SCAN_REF" "$MODE" "$START_ARG" "$END_ARG" > "$SCAN_TMP/commits"
FINDINGS_LEDGER="$SCAN_TMP/ledger.md"
get_ledger "$LEDGER_KEY" > "$FINDINGS_LEDGER"
TOTAL=$(wc -l < "$SCAN_TMP/commits")
echo "Found $TOTAL commits for $CURRENT_REPO ($SCAN_REF, $MODE)."

while read -r COMMIT_OID; do
    if [ -n "${SKIP_COMMITS:-}" ] && printf '%s\n' "$SKIP_COMMITS" | tr ',' '\n' | tr -d ' ' | grep -Fxq "${CURRENT_REPO}@${COMMIT_OID}"; then
        echo "Skipping commit $COMMIT_OID - Excluded by SKIP_COMMITS."
        continue
    fi
    LAST_OID=$(execute_sql "SELECT head_oid FROM git_reviews WHERE repo='${CURRENT_REPO}' AND head_oid='${COMMIT_OID}';")
    if [ -n "$LAST_OID" ]; then
        echo "Skipping commit $COMMIT_OID - Already reviewed."
        continue
    fi
    echo "Reviewing commit $COMMIT_OID ($CURRENT_REPO)."
    PR_WORKSPACE="/app/git-review-${SAFE_REPO_NAME}-${COMMIT_OID}"
    # A hard interruption may have left a workspace from an earlier attempt.
    rm -rf "$PR_WORKSPACE"
    cp -a "$BASE_CLONE_DIR" "$PR_WORKSPACE"
    cd "$PR_WORKSPACE"
    git checkout --detach "$COMMIT_OID"
    # Explicit first-parent diffs handle normal, squash and merge commits alike.
    # The root commit is compared to an empty tree using Git's native --root.
    git diff-tree --root --no-commit-id --binary -p --first-parent -m "$COMMIT_OID" -- > .commit_diff.txt
    PR_REPORT="$SCAN_TMP/report.md"
    PR_METRICS="$SCAN_TMP/metrics.json"
    PR_RESOLUTIONS="$SCAN_TMP/resolutions.txt"
    rm -f "$PR_REPORT" "$PR_METRICS" "$PR_RESOLUTIONS"
    FINDINGS_CONTEXT=$(cat "$FINDINGS_LEDGER")
    export CURRENT_REPO COMMIT_OID PR_REPORT PR_METRICS PR_RESOLUTIONS PR_WORKSPACE
    export FINDINGS_LEDGER FINDINGS_CONTEXT FINDINGS_BUDGET
    envsubst < /app/templates/git/discovery_template.txt > .opencode_discovery_prompt
    envsubst < /app/templates/git/verifier_template.txt > .opencode_verifier_prompt
    cp /app/scripts/opencode_runner.sh .opencode_runner.sh
    MACHINE_NAME="git$(tr -dc 'a-f0-9' < /dev/urandom | head -c 9 || true)"
    if timeout -k 5m "$REVIEW_TIMEOUT" systemd-nspawn --quiet --keep-unit --register=no \
        --machine="$MACHINE_NAME" --volatile=overlay -D /nspawn-root \
        --network-bridge=br-nspawn --bind="$PR_WORKSPACE" --bind=/tmp \
        -E GITHUB_TOKEN= -E GH_TOKEN= -E REPORT_REPO= \
        -E OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
        -E OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
        -E ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        -E GOOGLE_API_KEY="${GOOGLE_API_KEY:-}" \
        -E KIMI_API_KEY="${KIMI_API_KEY:-}" \
        -E NUMES_API_KEY="${NUMES_API_KEY:-}" \
        -E OPENCODE_MODEL="$OPENCODE_MODEL" \
        -E COMMIT_OID="$COMMIT_OID" -E FINDINGS_LEDGER="$FINDINGS_LEDGER" \
        -E PR_RESOLUTIONS="$PR_RESOLUTIONS" \
        -E PR_REPORT="$PR_REPORT" -E PR_METRICS="$PR_METRICS" \
        /bin/bash -c "cd $PR_WORKSPACE && ./.opencode_runner.sh" \
        > "/out/git_${SAFE_REPO_NAME}_${COMMIT_OID}.log" 2>&1; then
        :
    else
        STATUS=$?
        echo "ERROR: Git scan stopped at $COMMIT_OID (exit $STATUS); it was not marked reviewed."
        exit "$STATUS"
    fi
    if [ -s "$PR_REPORT" ] && report_has_finding "$PR_REPORT"; then
        execute_sql_insert_file "$CURRENT_REPO" NULL "$COMMIT_OID" "$PR_REPORT" "$PR_METRICS"
    fi
    put_ledger "$LEDGER_KEY" "$FINDINGS_LEDGER"
    if [ -s "$PR_RESOLUTIONS" ]; then
        while IFS='|' read -r ORIGINAL_OID REASON || [ -n "$ORIGINAL_OID" ]; do
            if [[ "$ORIGINAL_OID" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] && [ -n "$REASON" ]; then
                mark_commit_report_resolved "$CURRENT_REPO" "$ORIGINAL_OID" "$COMMIT_OID" "$REASON"
            fi
        done < "$PR_RESOLUTIONS"
    fi
    execute_sql "INSERT OR REPLACE INTO git_reviews (repo, head_oid) VALUES ('${CURRENT_REPO}', '${COMMIT_OID}');"
    cd "$BASE_CLONE_DIR"
    rm -rf "$PR_WORKSPACE"
    PR_WORKSPACE=""
done < "$SCAN_TMP/commits"
echo "Git scan complete for $CURRENT_REPO. Findings are stored locally in /out/bouncer.db."
