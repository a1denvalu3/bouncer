<p align="center">
  <img src="assets/icon.png" alt="Bouncer Icon" width="200"/>
</p>

# Bouncer

Bouncer is an automated, continuous security review tool that monitors GitHub Pull Requests for vulnerabilities. It runs inside a Docker container, periodically polling configured repositories. Using AI (`opencode-ai` + OpenRouter), it strictly analyzes new PR diffs to discover critical security vulnerabilities and attempts to verify them. 

If a serious vulnerability is confirmed with a working Proof of Concept (PoC), Bouncer automatically drafts a formatted security report and opens a pull request directly to your designated private security repository.

## Features
- **Continuous Monitoring:** Runs in a continuous loop to check for new or updated PRs.
- **Secure Isolation (systemd-nspawn):** Safely isolates each PR review and its AI agent inside a nested, ephemeral `systemd-nspawn` container, allowing the AI to execute arbitrary test code and PoCs safely.
- **State Tracking:** Remembers previously scanned commits to avoid redundant work.
- **AI-Powered Analysis:** Leverages LLMs to perform hypothesis-driven code review and exploit construction.
- **Automated Reporting:** Submits actionable, formatted vulnerability reports directly to a private GitHub repo.

## Architecture

Bouncer operates with a nested sandbox approach for maximum safety and modularity:
1. **Outer Loop (Docker):** The main Bouncer application runs as a privileged Docker container. It polls GitHub for open PRs, maintains the `state.json` tracker, and checks out PR branches into isolated workspace directories.
2. **Inner Sandbox (systemd-nspawn):** For each PR, Bouncer provisions a temporary, disposable filesystem snapshot (using `rsync`) and injects a customizable prompt (`prompt_template.txt`) alongside an execution script (`opencode_runner.sh`). It then launches an ephemeral `systemd-nspawn` container specifically for that single PR review. 
3. **Cleanup:** Once the LLM finishes verifying its hypothesis or building a PoC, the ephemeral nspawn container is immediately destroyed. Only the final output report is persisted securely to the outer `/out` volume.

## Configuration

Bouncer is configured using environment variables. Create a `.env` file in the project root or configure them directly in `docker-compose.yml`.

### Required Variables
- `GITHUB_PAT` (or `GITHUB_TOKEN`): A GitHub Personal Access Token. Needs read access to the target `REPOS` and read/write access to the `REPORT_REPO`.
- `OPENROUTER_API_KEY`: Your OpenRouter API key for LLM access.
- `REPOS`: A comma-separated list of target repositories to monitor (e.g., `org/repo1,org/repo2`).

### Optional Variables
- `REPORT_REPO`: The private repository where security findings will be submitted as PRs (default: `cashubtc/security-audits`).
- `OPENCODE_MODEL`: The AI model to use (default: `openrouter/google/gemini-3.1-pro-preview`).
- `SLEEP_DURATION`: Time in seconds to sleep between review cycles (default: `60`).
- `REVIEW_TIMEOUT`: Maximum execution time for a single PR review before it is forcibly killed. Accepts standard `timeout` command formats like "6h", "30m" (default: `30m`).
- `PR_MAX_AGE`: How far back to look for active PRs. Supports `date` tool formats like "4 months", "30 days", "1 year" (default: `4 months`).
- `SKIP_PRS`: A comma-separated list of PRs to explicitly ignore, formatted as `org/repo#pr` (e.g., `cashubtc/coco#139,myorg/myrepo#42`).

## Usage

1. Clone this repository.
2. Set your environment variables in a `.env` file at the root of the project:
   ```env
   GITHUB_PAT=ghp_your_token_here
   OPENROUTER_API_KEY=sk-or-v1-your_key_here
   REPOS=myorg/myrepo1,myorg/myrepo2
   REPORT_REPO=myorg/private-security-audits
   ```
3. Start the service using Docker Compose (*Note: The Docker container must run in `privileged` mode to support namespace allocation and nested `systemd-nspawn` containers*):
   ```bash
   docker compose up -d
   ```

## Logs and Output

- **Logs:** View the process using \`docker logs -f bouncer\`.
- **Local Reports:** Raw text reports and the PR state tracking file (`state.json`) are permanently saved to the local `./out/` directory, which is mapped as a volume.
