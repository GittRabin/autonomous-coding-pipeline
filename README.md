# Autonomous Coding Pipeline

A private, outbound-only GitHub issue automation system for a personal VM. It polls GitHub on a systemd timer, routes tasks by label, runs the appropriate coding toolchain, and opens a pull request with the results.

## Why this design

This repository is built around a simple rule: **no inbound traffic**.

That means:
- no public webhook endpoint
- no tunnel to manage
- no exposed port on the VM
- no extra infrastructure beyond GitHub, systemd, and the tools you already use

The VM only makes outbound requests to GitHub and model providers.

## Workflow overview

1. Create a GitHub issue.
2. Add the waiting label `overnight-task`.
3. Add one routing label:
   - `task-code`
   - `task-e2e`
4. The poller wakes up on the timer and looks for the oldest waiting issue.
5. It replaces the waiting state with `processing` and launches the pipeline.
6. The pipeline creates a branch, generates a plan, runs the selected tool, pushes changes, and opens a PR.
7. The PR is marked `ready-for-review` or `needs-human-review`.

## Label model

### Routing labels

- `task-code` — use Aider for normal code-change tasks
- `task-e2e` — use a custom end-to-end or MCP-capable runner via `E2E_RUNNER_CMD`

### State labels

- `overnight-task` — queued and waiting
- `processing` — currently running on the VM
- `ready-for-review` — PR is ready for human review
- `needs-human-review` — pipeline finished but needs follow-up

## Repository layout

- [setup.sh](setup.sh) — installs dependencies, the poller, and the systemd timer
- [poller/poller.js](poller/poller.js) — outbound GitHub poller that claims work by label
- [pipeline/run_pipeline.sh](pipeline/run_pipeline.sh) — branch, planning, tool execution, testing, and PR creation
- [systemd/pipeline-poller.service.template](systemd/pipeline-poller.service.template) — oneshot service run by the timer
- [systemd/pipeline-poller.timer.template](systemd/pipeline-poller.timer.template) — recurring scheduler
- [Makefile](Makefile) — daily operational commands
- [.env.example](.env.example) — sample configuration values

## Requirements

- Ubuntu or another Linux machine with systemd
- Node.js 18+
- Python 3 with venv support
- GitHub CLI access to the target repository
- An Anthropic API key
- Ollama installed locally or installable by the setup script

## Configuration

Copy values from [.env.example](.env.example) and export them in your shell before running setup.

### Required

- `ANTHROPIC_API_KEY`
- `GITHUB_TOKEN`
- `GITHUB_REPO`

### Common optional values

- `OLLAMA_MODEL` — defaults to `qwen2.5-coder:7b`
- `WORK_DIR` — install location on the VM
- `REPO_DIR` — where target repositories are cloned
- `VENV_DIR` — Python virtual environment path
- `POLL_INTERVAL_MINUTES` — timer frequency, default `5`

### Label customization

- `TRIGGER_LABEL` — default `overnight-task`
- `PROCESSING_LABEL` — default `processing`
- `TASK_LABEL_CODE` — default `task-code`
- `TASK_LABEL_E2E` — default `task-e2e`

### Optional e2e runner

If you want `task-e2e` issues to use a dedicated command, set:

- `E2E_RUNNER_CMD`

Example uses include Claude Code, browser automation, Playwright flows, or MCP-backed tasks.

## Installation

1. Export the required environment variables.
2. Run:

   bash setup.sh

3. Confirm the timer is active:

   make status

4. View logs if needed:

   make logs

## Daily use

### Queue a coding task

Create a GitHub issue and apply:
- `overnight-task`
- either `task-code` or `task-e2e`

### Trigger a run immediately

Use:

- `make run-now`

### Check the current state

Use:

- `make status`
- `make logs`

## Operational commands

- `make logs` — follow poller and timer logs
- `make status` — inspect timer and service status
- `make restart` — restart the timer
- `make run-now` — force an immediate poll
- `make uninstall` — remove the installed timer and service

## Notes and limitations

- This design is optimized for low-volume personal automation, not high-throughput job scheduling.
- Start latency depends on the polling interval.
- Issues should keep routing labels separate from state labels for clarity.
- If no supported test runner is detected, the PR is still created and flagged for review.

