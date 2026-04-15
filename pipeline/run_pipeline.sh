#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <issue-number> <title> [body] [tool-mode]" >&2
    exit 1
fi

ISSUE_NUMBER="$1"
ISSUE_TITLE="$2"
ISSUE_BODY="${3:-}"
TOOL_MODE="${4:-${TOOL_MODE:-task-code}}"

REPO_DIR="${REPO_DIR:-$HOME/projects}"
REPO_PATH_OVERRIDE="${REPO_PATH_OVERRIDE:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
DEFAULT_OLLAMA_MODEL="deepseek-coder-v2:16b-lite-instruct-q4_K_M"
OLLAMA_MODEL="${OLLAMA_MODEL:-$DEFAULT_OLLAMA_MODEL}"
OLLAMA_PLANNER_MODEL="${OLLAMA_PLANNER_MODEL:-$OLLAMA_MODEL}"
OLLAMA_AUTO_PULL="${OLLAMA_AUTO_PULL:-true}"
OLLAMA_FALLBACK_MODEL="${OLLAMA_FALLBACK_MODEL:-$DEFAULT_OLLAMA_MODEL}"
PLAN_MODEL_PROVIDER="${PLAN_MODEL_PROVIDER:-auto}"
AIDER_MODEL="${AIDER_MODEL:-ollama/$OLLAMA_MODEL}"
AIDER_EDITOR_MODEL="${AIDER_EDITOR_MODEL:-}"
AIDER_ARCHITECT="${AIDER_ARCHITECT:-0}"
AIDER_TRACE="${AIDER_TRACE:-false}"
AIDER_TRACE_DIR="${AIDER_TRACE_DIR:-}"
OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
GIT_COMMIT_NAME="${GIT_COMMIT_NAME:-Rabin Pipeline Bot}"
GIT_COMMIT_EMAIL="${GIT_COMMIT_EMAIL:-rabin-pipeline-bot@users.noreply.github.com}"
TARGET_BRANCH="${TARGET_BRANCH:-}"
PIPELINE_BRANCH_MODE="${PIPELINE_BRANCH_MODE:-issue-branch}"
SKIP_PR_CREATE="${SKIP_PR_CREATE:-auto}"
VENV_DIR="${VENV_DIR:-$HOME/.venv/pipeline}"
E2E_RUNNER_CMD="${E2E_RUNNER_CMD:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
PIPELINE_STATE_ROOT="${PIPELINE_STATE_ROOT:-}"
PIPELINE_STATE_DIR="${PIPELINE_STATE_DIR:-}"
PIPELINE_DB_PATH="${PIPELINE_DB_PATH:-}"
PIPELINE_REPO_STATE_SUBDIR="${PIPELINE_REPO_STATE_SUBDIR:-.rabin/history}"
MAX_RETRIES=3
DEFAULT_BRANCH="main"
BASE_BRANCH=""
PLAN_FILE=""
TEST_OUTPUT_FILE=""
ISSUE_STATE_DIR=""
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_LIB_DIR="$PIPELINE_DIR/lib"

# Load modular helpers.
# shellcheck disable=SC1091
source "$PIPELINE_LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$PIPELINE_LIB_DIR/state.sh"
# shellcheck disable=SC1091
source "$PIPELINE_LIB_DIR/repo.sh"
# shellcheck disable=SC1091
source "$PIPELINE_LIB_DIR/planning.sh"
# shellcheck disable=SC1091
source "$PIPELINE_LIB_DIR/execution.sh"
# shellcheck disable=SC1091
source "$PIPELINE_LIB_DIR/publish.sh"

[[ -z "$GITHUB_REPO" ]] && fail "GITHUB_REPO is not set"

BRANCH="task/issue-${ISSUE_NUMBER}"
REPO_SLUG="${GITHUB_REPO//\//_}"
REPO_PATH="${REPO_PATH_OVERRIDE:-$REPO_DIR/$REPO_SLUG}"

[[ "$PIPELINE_BRANCH_MODE" =~ ^(issue-branch|direct-target)$ ]] || fail "PIPELINE_BRANCH_MODE must be issue-branch or direct-target"
[[ "$SKIP_PR_CREATE" =~ ^(auto|true|false)$ ]] || fail "SKIP_PR_CREATE must be auto, true, or false"


main() {
    prepare_repo
    log "Tool mode: $TOOL_MODE"

    setup_run_state
    activate_runtime
    execute_pipeline_run
    commit_and_push_changes
    determine_pr_mode
    build_pr_metadata
    publish_results
}

main
