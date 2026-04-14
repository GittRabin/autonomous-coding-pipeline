# Autonomous Coding Pipeline

A private, outbound-only workflow that polls GitHub issues on a timer and launches an automated implementation pipeline using Claude planning, Aider, and optionally a dedicated e2e runner.

## How it works

1. Create a GitHub issue and add the label `overnight-task`.
2. Add either `task-code` or `task-e2e` to choose the tool route.
3. A Node poller runs every few minutes via systemd and checks the GitHub API.
4. The poller claims the oldest waiting issue by swapping `overnight-task` for `processing`.
5. The pipeline creates a branch, writes a plan, runs the selected tool, pushes changes, and opens a pull request.
6. The pull request is labeled `ready-for-review` or `needs-human-review`.

## Label model

### Routing labels

- `task-code` → Aider for faster file-change tasks
- `task-e2e` → custom e2e runner via `E2E_RUNNER_CMD` for browser, Stripe, or MCP-heavy work

### State labels

- `overnight-task` → waiting
- `processing` → running on the VM
- `ready-for-review` or `needs-human-review` → final PR status

## Repository layout

- [setup.sh](setup.sh) — installs the poller, timer, and local toolchain
- [poller/poller.js](poller/poller.js) — outbound GitHub issue poller
- [pipeline/run_pipeline.sh](pipeline/run_pipeline.sh) — repo automation and PR flow
- [systemd/pipeline-poller.service.template](systemd/pipeline-poller.service.template) — oneshot poller service
- [systemd/pipeline-poller.timer.template](systemd/pipeline-poller.timer.template) — recurring timer
- [Makefile](Makefile) — daily operational commands

## Prerequisites

- Ubuntu or another Linux host with systemd
- A GitHub token with repo access
- An Anthropic API key
- Network access for GitHub, Anthropic, and Ollama model pulls

## Environment variables

Set these before running setup:

- `ANTHROPIC_API_KEY`
- `GITHUB_TOKEN`
- `GITHUB_REPO`
- `OLLAMA_MODEL`, optional, default `qwen2.5-coder:7b`
- `WORK_DIR`, optional
- `REPO_DIR`, optional
- `VENV_DIR`, optional
- `POLL_INTERVAL_MINUTES`, optional, default `5`
- `TRIGGER_LABEL`, optional, default `overnight-task`
- `PROCESSING_LABEL`, optional, default `processing`
- `TASK_LABEL_CODE`, optional, default `task-code`
- `TASK_LABEL_E2E`, optional, default `task-e2e`
- `E2E_RUNNER_CMD`, optional, used only for `task-e2e`

## Installation

1. Export the required environment variables.
2. Run `bash setup.sh`.
3. Confirm the timer is active with `make status`.
4. Create issues from mobile or desktop with the correct labels.

## Operations

From the install directory:

- `make logs`
- `make status`
- `make restart`
- `make run-now`
- `make uninstall`

## Notes

- The design is fully outbound-only and does not expose any HTTP ports.
- The pipeline checks common JavaScript, Python, and Make-based test setups.
- If no supported automated tests are detected, the PR is still opened and marked for review.
