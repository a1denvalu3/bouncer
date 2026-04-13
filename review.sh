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

    # Get list of open PRs updated in the last 4 months
    FOUR_MONTHS_AGO=$(date -d "4 months ago" +%Y-%m-%d)
    echo "Looking for open PRs updated since ${FOUR_MONTHS_AGO}..."

    PR_DATA=$(gh pr list --search "state:open updated:>=${FOUR_MONTHS_AGO}" --json number,headRefOid,headRefName)

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
            
            PROMPT="
You are in a CTF. Focus only on the changes introduced by this specific branch compared to the base branch. Find the most serious vulnerability in these changes for ${CURRENT_REPO}. Write the most serious findings to ${PR_REPORT}. Do NOT EVER comment on the public repositories we're reviewing. If you find a vulnerability, document it in ${PR_REPORT}. However, you MUST ONLY open a PR to the private security audits repository (git@github.com:${REPORT_REPO}.git) IF you have successfully backed your finding with a working, executed exploit PoC. Theoretical findings can be reported in ${PR_REPORT}, but NEVER trigger a PR to the ${REPORT_REPO} repository.

<targets>
- **${CURRENT_REPO}** — Current working directory (which is a clone of the PR branch).

Focus on the changes introduced by this specific PR branch compared to the base branch. Bugs at integration boundaries — mismatched assumptions, callback handling, request/response binding — are high-value.
</targets>

<role>
**Triage:** When choosing where to dig first, favor hypotheses that could plausibly reach **HIGH** impact; still confirm and report any vulnerability you find in the PR changes.

You are a security researcher specializing in finding vulnerabilities in PRs. Your primary focus is identifying critical vulnerabilities introduced by the changes in this PR.

**Task:** Find and confirm the most serious vulnerability introduced in this PR. Write the final report to ${PR_REPORT}. Do NOT EVER comment on the original public PR. If, AND ONLY IF, your finding is backed by a working, executed exploit PoC, you must clone \`git@github.com:${REPORT_REPO}.git\` via SSH, format your finding according to its AGENTS.md conventions, and open a pull request to that repo.
Focus area: HIGH severity issues. Theoretical findings are allowed in ${PR_REPORT}, but opening a PR to the ${REPORT_REPO} repository requires a confirmed, working PoC.
</role>

<critical_constraint>
- Never guess what code does — read it.
- Your report must focus on the changes introduced by this specific branch compared to the base branch.
- A finding is only marked as \`status: confirmed\` if you can demonstrate it with a working PoC script or exploit that you have executed and verified.
- If a test is not feasible, write the report to ${PR_REPORT} anyway with \`status: theoretical\` and explain the gap, but DO NOT proceed to Phase 4 (Do NOT open a PR).
</critical_constraint>

<common_pitfalls>
- Do not report \"missing validation\" unless you show the unvalidated input reaches a security-relevant state change.
- Do not claim race conditions without a concrete interleaving.
- Do not assume vulnerability from function names — read the full path end-to-end.
</common_pitfalls>

<phases>
Advance to the next phase only when the current phase's exit criteria are satisfied.


## Phase 0 — Previous Report Verification
If this PR has been updated with new commits, we must check if a previous vulnerability report exists and was fixed.
1. Check for open PRs in \`${REPORT_REPO}\` related to this PR by running:
   \`gh pr list -R ${REPORT_REPO} --search "[${CURRENT_REPO}#${PR}] in:title" --state open --json number,headRefName\`
2. If an open PR exists:
   a. Clone the \`${REPORT_REPO}\` repo via SSH: \`git clone git@github.com:${REPORT_REPO}.git ${PR_WORKSPACE}/security-audits\`
   b. Change to that directory and checkout the PR branch using \`gh pr checkout <PR_NUMBER>\`.
   c. Read the report file in that branch to understand the previously reported vulnerability.
   d. Analyze the current changes in the target PR branch to determine if the reported vulnerability is now fixed.
   e. If the vulnerability IS fixed:
      - Comment on the PR in \`${REPORT_REPO}\` using: \`gh pr comment <PR_NUMBER> --body "The problem described in the report is fixed in the latest commits."\`
      - Exit your review successfully (do not proceed to Phase 1).
   f. If the vulnerability is NOT fixed, continue to Phase 1, but do not create a duplicate report for the same issue.

## Phase 1 — Context & Threat Model
1. Use \`git diff [base-branch]...HEAD\` or \`gh pr diff\` to understand exactly what lines were changed.
2. Identify trust boundaries affected by these changes.
3. Formulate 1-3 falsifiable hypotheses about vulnerabilities introduced by the PR.

## Phase 2 — Hypothesis-driven code review
For each hypothesis:
1. Start at the boundary affected by the PR.
2. Trace fields through parsing, validation, and business logic.
3. Stop when you confirm or refute the hypothesis.

## Phase 3 — Exploit Construction & Verification
1. If a hypothesis seems valid, try to write a PoC or script to definitively prove it.
2. Execute your PoC against the codebase.
3. If successful, mark your finding as \`status: confirmed\`. If you cannot create a working PoC, mark it as \`status: theoretical\`.
4. Write your finding to ${PR_REPORT} using the template below.

## Phase 4 — PR Submission (STRICTLY FOR CONFIRMED PoCs ONLY)
STOP! Do NOT proceed with this phase unless your finding from Phase 3 is \`status: confirmed\` and backed by a working PoC. If your finding is \`status: theoretical\`, exit now.

If you have a CONFIRMED vulnerability strictly introduced by this PR:
1. Clone the private audits repo to a unique directory: \`git clone git@github.com:${REPORT_REPO}.git ${PR_WORKSPACE}/security-audits\`
2. Change to that directory for all subsequent commands (e.g. use \`workdir=\"${PR_WORKSPACE}/security-audits\"\` in your bash tool).
3. Checkout a new branch: \`git checkout -b report/pr-${PR}-<slug>\` (where <slug> is a kebab-case identifier for the finding)
4. Create the directory structure: \`<project>/<date>/<slug>/\` (where <project> is the repo name without the owner, e.g., \`nutshell\` for \`cashubtc/nutshell\`, and <date> is today's date in \`YYYY-MM-DD\`).
5. Write your report to \`<project>/<date>/<slug>/pr-${PR}-report.md\` strictly following the YAML frontmatter and format specified in the \`<report_template>\` below.
6. (Optional but recommended) Add your exploit to \`__tests__/<slug>/test.ts\` following the \`@scripts/\` import rules defined in \`AGENTS.md\`.
7. Commit the files: \`git add . && git commit -m \"Add report for PR #${PR}: <slug>\" && git push -u origin report/pr-${PR}-<slug>\`
8. Open a Pull Request using \`gh pr create --title \"[${CURRENT_REPO}#${PR}] Report: <human-readable title>\" --body \"Security audit finding for ${CURRENT_REPO} PR #${PR} (https://github.com/${CURRENT_REPO}/pull/${PR}). Branch: ${HEAD_REF_NAME}.\" --label \"severity:<severity>\" --label \"target:<project>\" --label \"<NUT-XX>\"\`. Make sure to add specific labels for the severity (e.g., \`severity:critical\`, \`severity:high\`), the affected project (e.g., \`target:nutshell\`), and any affected NUTs (e.g., \`NUT-04\`). IMPORTANT: You MUST explicitly link the reviewed pull request (https://github.com/${CURRENT_REPO}/pull/${PR}) in the PR description body.
</phases>

<methodology>
Use these lenses by **priority**:
**Highest — End-to-end input tracing.** Start at the affected API boundary.
**High — Invariant violation.** Name the invariant. Ask whether it can fail on the new paths.
**Medium — State and atomicity.** Concurrency, transactions.
</methodology>

<severity>
After writing the finding, label it:
- **Tier 1 — Direct impact.** Unauthorized access, extracts value, escalates privileges.
- **Tier 2 — Preconditions for impact.** Logic that weakens security boundaries.
- **Tier 3 — Privacy, DoS, info leak.**
</severity>

<report_template>
---
title: \"<human-readable title>\"
slug: <kebab-case-slug>
date: <YYYY-MM-DD>
status: confirmed|theoretical
severity: critical|high|medium|low|info
target: [${CURRENT_REPO}]
nuts: [NUT-XX]
---

## Summary
One paragraph.

## Root Cause
With file:line references, explain why the vulnerability exists in the PR changes.

## Attack Steps
Numbered, reproducible steps.

## Impact
What an attacker gains.

## Test Results
(If applicable) Output from running the exploit test against target(s).

## Cross-Implementation Comparison
(If applicable) How implementations handle this differently.

## Proposed Fix
Specific code changes to remediate.
</report_template>
"

            # We export OPENCODE_AUTO_CONFIRM=true to allow it to run tools (like file system access) without prompting
            export OPENCODE_AUTO_CONFIRM=true
            export OPENCODE_PERMISSION='{"external_directory": {"*": "allow"}}'
            
            # Run the exact command requested via opencode
            opencode run -m "$OPENCODE_MODEL" "$PROMPT"

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
