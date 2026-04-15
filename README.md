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

- [install.sh](install.sh) — installs dependencies, the poller, and the systemd timer
- [setup.sh](setup.sh) — compatibility wrapper that delegates to install.sh
- [poller/poller.js](poller/poller.js) — outbound GitHub poller that claims work by label
- [pipeline/run_pipeline.sh](pipeline/run_pipeline.sh) — branch, planning, tool execution, testing, and PR creation
- [systemd/pipeline-poller.service.template](systemd/pipeline-poller.service.template) — oneshot service run by the timer
- [systemd/pipeline-poller.timer.template](systemd/pipeline-poller.timer.template) — recurring scheduler
- [Makefile](Makefile) — daily operational commands
- [.env.example](.env.example) — sample configuration values

## Requirements

- Ubuntu or another Linux machine with systemd
- Node.js latest LTS (installer configures this automatically)
- Python 3 with venv support
- GitHub CLI installed and authenticated (`gh auth login`)
- Ollama installed locally or installable by the install script
- Optional: Anthropic API key (only if you want Anthropic planner mode)

## Configuration

Use [.env.example](.env.example) only if you want to pre-seed defaults. In normal usage, install first, then run `rabin configure` inside each target repository.

### Required

- None required for `install.sh` bootstrap
- `rabin configure` auto-detects `GITHUB_REPO` from the current git repository
- `rabin configure` auto-uses `GITHUB_TOKEN` from `gh auth token`

### Common optional values

- `OLLAMA_MODEL` — defaults to `deepseek-coder-v2:16b-lite-instruct-q4_K_M`
- `OLLAMA_AUTO_PULL` — `true` by default, auto-download missing configured Ollama models
- `OLLAMA_FALLBACK_MODEL` — model used automatically if configured model cannot be prepared (default `deepseek-coder-v2:16b-lite-instruct-q4_K_M`)
- `WORK_DIR` — install location on the VM
- `REPO_DIR` — where target repositories are cloned, default `$HOME/projects`
- `REPO_PATH_OVERRIDE` — optional explicit local checkout path for a repo profile
- `VENV_DIR` — Python virtual environment path
- `POLL_INTERVAL_MINUTES` — timer frequency, default `5`
- `OLLAMA_PLANNER_MODEL` — planner model for local plan generation
- `PLAN_MODEL_PROVIDER` — `auto`, `ollama`, `anthropic`, or `claude-cli`
- `AIDER_MODEL` — default `ollama/<OLLAMA_MODEL>`
- `AIDER_EDITOR_MODEL` — optional separate editor model for Aider
- `AIDER_ARCHITECT` — set `1` to enable Aider architect mode
- `AIDER_TRACE` — `true` by default; stores per-run prompt and streamed output logs
- `AIDER_TRACE_DIR` — leave empty to store trace files in the repo history folder; set explicit path to override
- `OLLAMA_API_BASE` — defaults to `http://127.0.0.1:11434` for local Ollama access
- `GIT_COMMIT_NAME` — git author name used by pipeline when repo identity is unset
- `GIT_COMMIT_EMAIL` — git author email used by pipeline when repo identity is unset
- `PIPELINE_STATE_DIR` — leave empty to keep run artifacts under each repo (`<repo>/.rabin/history`)
- `PIPELINE_REPO_STATE_SUBDIR` — repo-local subdirectory used when `PIPELINE_STATE_DIR` is empty
- Installer links `aider` to `~/.local/bin/aider` for direct shell use
- `TARGET_BRANCH` — optional base branch to work against
- `PIPELINE_BRANCH_MODE` — `issue-branch` (default) or `direct-target`
- `SKIP_PR_CREATE` — `auto` (default), `true`, or `false`

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
2. Run bootstrap installer:

   bash install.sh

   Or run directly via curl (like Claude Code style):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/GittRabin/autonomous-coding-pipeline/main/install.sh | bash
   ```

   If you are using a fork or branch, set these before curl:

   ```bash
   export INSTALL_REPO="yourname/autonomous-coding-pipeline"
   export INSTALL_REF="main"
   curl -fsSL "https://raw.githubusercontent.com/${INSTALL_REPO}/${INSTALL_REF}/install.sh" | bash
   ```

3. Authenticate GitHub CLI (if not already authenticated):

   gh auth login

4. For the normal single-repo path, the installer now auto-enables the default profile when it can detect your repo and GitHub auth.

   For multi-project or custom setup, run:

   rabin configure

5. Confirm timers are active:

   rabin status --all

6. View logs if needed:

   rabin logs <profile>

## Daily use

After setup, you can run operations from anywhere using the global `rabin` command.

### CLI help

```bash
rabin --help
```

Available commands:

- `rabin configure`
- `rabin profiles`
- `rabin show`
- `rabin enable`
- `rabin disable`
- `rabin status`
- `rabin logs`
- `rabin restart`
- `rabin run-now`
- `rabin urgent`
- `rabin uninstall`

### Multi-project setup with profiles

If you manage multiple target repositories on one VM, use profile files and enable multiple timer instances.

Create profiles:

```bash
cd /home/ubuntu/projects/repo-a && rabin configure
cd /home/ubuntu/projects/repo-b && rabin configure
```

`rabin configure` reuses your existing `gh` login by default (`gh auth token`) when `--github-token` is not provided.
It also initializes required pipeline labels by default (`overnight-task`, `processing`, `task-code`, `task-e2e`, `ready-for-review`, `needs-human-review`).
When run inside a git repo, `rabin configure` captures that checkout path and the pipeline reuses it (instead of cloning another copy).

Shortcut for current checked-out branch (direct commits, no PR by default):

```bash
rabin configure --current
```

For branch targeting, you can configure direct commits to a specific branch (no extra task branch):

```bash
rabin configure --target-branch dev --branch-mode direct-target --skip-pr-create true
```

Default behavior remains `issue-branch`, which creates `task/issue-<number>` and opens a PR.

List and inspect profiles:

```bash
rabin profiles
rabin show project-a
```

Enable all project instances (parallel polling):

```bash
rabin enable project-a
rabin enable project-b
rabin status --all
```

If you want to disable one project:

```bash
rabin disable project-b
```

### Queue a coding task

Create a GitHub issue and apply:
- `overnight-task`
- either `task-code` or `task-e2e`

### Trigger a run immediately

Use:

- `rabin run-now project-a`

### Check the current state

Use:

- `rabin status project-a`
- `rabin logs project-a`

If you only configured one project, omitting the profile now targets that saved profile automatically. When using `systemctl` directly, replace `default` with the profile name shown by `rabin profiles`.

## Operational commands

- `rabin status --all` — list all active pipeline timers
- `rabin update` — update rabin CLI and rerun bootstrap installer
- `rabin status <profile>` — inspect one profile service and timer
- `rabin logs <profile>` — follow one profile logs
- `rabin run-now <profile>` — force immediate poll for one profile
- `rabin urgent <profile>` — urgent immediate poll for one profile
- `rabin urgent --all` — urgent immediate poll for all profiles
- `rabin disable <profile>` — disable one project timer
- `rabin uninstall <profile>` — remove one profile runtime files
- `rabin uninstall --all` — stop all timers and clear all runtime env files

## Notes and limitations

- This design is optimized for low-volume personal automation, not high-throughput job scheduling.
- Start latency depends on the polling interval.
- Issues should keep routing labels separate from state labels for clarity.
- If no supported test runner is detected, the PR is still created and flagged for review.

