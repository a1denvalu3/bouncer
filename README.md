# Bouncer

Bouncer is an automated, continuous security review tool that monitors GitHub Pull Requests for vulnerabilities. It runs inside a Docker container, periodically polling configured repositories. Using AI (`opencode-ai` + OpenRouter), it strictly analyzes new PR diffs to discover critical security vulnerabilities and attempts to verify them. 

If a serious vulnerability is confirmed with a working Proof of Concept (PoC), Bouncer automatically drafts a formatted security report and opens a pull request directly to your designated private security repository.

## Features
- **Continuous Monitoring:** Runs in a continuous loop to check for new or updated PRs.
- **State Tracking:** Remembers previously scanned commits to avoid redundant work.
- **AI-Powered Analysis:** Leverages LLMs to perform hypothesis-driven code review and exploit construction.
- **Automated Reporting:** Submits actionable, formatted vulnerability reports directly to a private GitHub repo.

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
3. Start the service using Docker Compose:
   ```bash
   docker compose up -d
   ```

## Logs and Output

- **Logs:** View the process using \`docker logs -f bouncer\`.
- **Local Reports:** Raw text reports and the PR state tracking file (`state.json`) are permanently saved to the local `./out/` directory, which is mapped as a volume.
