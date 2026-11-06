#!/bin/bash

# Normalize supported token names for both Compose and direct script invocation.
export GITHUB_TOKEN="${GITHUB_TOKEN:-${GITHUB_PAT:-${GH_TOKEN:-}}}"

# A report repository alone must never enable publishing without authentication.
if [ -z "$GITHUB_TOKEN" ]; then
    if [ -n "${REPORT_REPO:-}" ]; then
        echo "No GitHub token provided; ignoring REPORT_REPO and keeping findings local."
    fi
    export REPORT_REPO=""
fi
