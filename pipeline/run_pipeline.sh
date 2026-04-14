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

REPO_DIR="${REPO_DIR:-$HOME/repos}"
REPO_PATH_OVERRIDE="${REPO_PATH_OVERRIDE:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:1.5b}"
OLLAMA_PLANNER_MODEL="${OLLAMA_PLANNER_MODEL:-$OLLAMA_MODEL}"
OLLAMA_AUTO_PULL="${OLLAMA_AUTO_PULL:-true}"
OLLAMA_FALLBACK_MODEL="${OLLAMA_FALLBACK_MODEL:-qwen2.5-coder:1.5b}"
PLAN_MODEL_PROVIDER="${PLAN_MODEL_PROVIDER:-auto}"
AIDER_MODEL="${AIDER_MODEL:-ollama/$OLLAMA_MODEL}"
AIDER_EDITOR_MODEL="${AIDER_EDITOR_MODEL:-}"
AIDER_ARCHITECT="${AIDER_ARCHITECT:-0}"
AIDER_TRACE="${AIDER_TRACE:-true}"
AIDER_TRACE_DIR="${AIDER_TRACE_DIR:-$HOME/.local/state/rabin}"
OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://127.0.0.1:11434}"
GIT_COMMIT_NAME="${GIT_COMMIT_NAME:-Rabin Pipeline Bot}"
GIT_COMMIT_EMAIL="${GIT_COMMIT_EMAIL:-rabin-pipeline-bot@users.noreply.github.com}"
TARGET_BRANCH="${TARGET_BRANCH:-}"
PIPELINE_BRANCH_MODE="${PIPELINE_BRANCH_MODE:-issue-branch}"
SKIP_PR_CREATE="${SKIP_PR_CREATE:-auto}"
VENV_DIR="${VENV_DIR:-$HOME/.venv/pipeline}"
E2E_RUNNER_CMD="${E2E_RUNNER_CMD:-}"
MAX_RETRIES=3
DEFAULT_BRANCH="main"
BASE_BRANCH=""

log()  { echo "[pipeline #$ISSUE_NUMBER] $(date '+%H:%M:%S') $1"; }
fail() { echo "[pipeline #$ISSUE_NUMBER] $(date '+%H:%M:%S') FAILED: $1"; exit 1; }

[[ -z "$GITHUB_REPO" ]] && fail "GITHUB_REPO is not set"

BRANCH="task/issue-${ISSUE_NUMBER}"
REPO_SLUG="${GITHUB_REPO//\//_}"
REPO_PATH="${REPO_PATH_OVERRIDE:-$REPO_DIR/$REPO_SLUG}"

[[ "$PIPELINE_BRANCH_MODE" =~ ^(issue-branch|direct-target)$ ]] || fail "PIPELINE_BRANCH_MODE must be issue-branch or direct-target"
[[ "$SKIP_PR_CREATE" =~ ^(auto|true|false)$ ]] || fail "SKIP_PR_CREATE must be auto, true, or false"

is_truthy() {
    local v
    v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" ]]
}

ensure_ollama_model() {
    local model="$1"

    [ -n "$model" ] || return 1

    if ollama show "$model" >/dev/null 2>&1; then
        return 0
    fi

    if is_truthy "$OLLAMA_AUTO_PULL"; then
        log "Ollama model '$model' not found locally, pulling..."
        if ollama pull "$model" >/dev/null 2>&1; then
            log "Pulled model '$model'"
            return 0
        fi
    fi

    return 1
}

prepare_ollama_models() {
    local required_model="$OLLAMA_MODEL"
    local planner_model="$OLLAMA_PLANNER_MODEL"
    local aider_model_name=""

    if [[ "$AIDER_MODEL" == ollama/* ]]; then
        aider_model_name="${AIDER_MODEL#ollama/}"
    fi

    if ! command -v ollama >/dev/null 2>&1; then
        fail "Ollama is required for configured models, but 'ollama' is not installed"
    fi

    local required_ok=1
    local planner_ok=1
    local aider_ok=1

    if ! ensure_ollama_model "$required_model"; then
        required_ok=0
    fi

    if [ "$planner_model" != "$required_model" ] && ! ensure_ollama_model "$planner_model"; then
        planner_ok=0
    fi

    if [ -n "$aider_model_name" ] && [ "$aider_model_name" != "$required_model" ] && [ "$aider_model_name" != "$planner_model" ] && ! ensure_ollama_model "$aider_model_name"; then
        aider_ok=0
    fi

    if [ "$required_ok" -eq 1 ] && [ "$planner_ok" -eq 1 ] && [ "$aider_ok" -eq 1 ]; then
        return 0
    fi

    log "One or more configured Ollama models are unavailable; trying fallback '$OLLAMA_FALLBACK_MODEL'"
    ensure_ollama_model "$OLLAMA_FALLBACK_MODEL" || fail "Configured Ollama model(s) unavailable and fallback model '$OLLAMA_FALLBACK_MODEL' could not be prepared"

    if [ "$required_ok" -eq 0 ]; then
        OLLAMA_MODEL="$OLLAMA_FALLBACK_MODEL"
        log "Using fallback for OLLAMA_MODEL: $OLLAMA_MODEL"
    fi

    if [ "$planner_ok" -eq 0 ]; then
        OLLAMA_PLANNER_MODEL="$OLLAMA_FALLBACK_MODEL"
        log "Using fallback for OLLAMA_PLANNER_MODEL: $OLLAMA_PLANNER_MODEL"
    fi

    if [ "$aider_ok" -eq 0 ]; then
        AIDER_MODEL="ollama/$OLLAMA_FALLBACK_MODEL"
        log "Using fallback for AIDER_MODEL: $AIDER_MODEL"
    fi
}

prepare_repo() {
    if [ ! -d "$REPO_PATH" ]; then
        if [ -n "$REPO_PATH_OVERRIDE" ]; then
            fail "Configured REPO_PATH_OVERRIDE does not exist: $REPO_PATH_OVERRIDE"
        fi

        log "Cloning repo..."
        mkdir -p "$REPO_DIR"
        gh repo clone "$GITHUB_REPO" "$REPO_PATH"
    fi

    [ -d "$REPO_PATH/.git" ] || fail "Repository path is not a git repo: $REPO_PATH"

    cd "$REPO_PATH"
    git fetch origin
    DEFAULT_BRANCH="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

    BASE_BRANCH="${TARGET_BRANCH:-$DEFAULT_BRANCH}"

    # Always sync base branch first.
    git checkout "$BASE_BRANCH" 2>/dev/null || git checkout -b "$BASE_BRANCH" "origin/$BASE_BRANCH"
    git pull origin "$BASE_BRANCH"

    if [ "$PIPELINE_BRANCH_MODE" = "direct-target" ]; then
        BRANCH="$BASE_BRANCH"
        log "Branch mode: direct-target (committing on $BRANCH)"
    else
        git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
        log "Branch mode: issue-branch (working branch $BRANCH from $BASE_BRANCH)"
    fi

    if [ -z "$(git config user.name || true)" ]; then
        git config user.name "$GIT_COMMIT_NAME"
        log "Configured git user.name for this repo: $GIT_COMMIT_NAME"
    fi

    if [ -z "$(git config user.email || true)" ]; then
        git config user.email "$GIT_COMMIT_EMAIL"
        log "Configured git user.email for this repo: $GIT_COMMIT_EMAIL"
    fi
}

generate_plan() {
    local prompt
    prompt="You are a senior engineer. Decompose this task into a precise, ordered list of coding steps with acceptance criteria. Be specific about file paths and function names where possible.

Preferred execution route: $TOOL_MODE

Task title: $ISSUE_TITLE

Task details:
$ISSUE_BODY

Output only the plan in markdown, no preamble."

    PLAN=""

    if [[ "$PLAN_MODEL_PROVIDER" == "anthropic" ]] || { [[ "$PLAN_MODEL_PROVIDER" == "auto" ]] && [[ -n "$ANTHROPIC_API_KEY" ]]; }; then
        log "Generating PLAN.md via Anthropic..."
        PROMPT_BODY=$(jq -n \
            --arg text "$prompt" \
            '{
                model: "claude-sonnet-4-5",
                max_tokens: 2048,
                messages: [{ role: "user", content: $text }]
            }')

        PLAN=$(curl -s https://api.anthropic.com/v1/messages \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "$PROMPT_BODY" | jq -r '.content[0].text // empty')
    fi

    if [[ -z "$PLAN" ]] && { [[ "$PLAN_MODEL_PROVIDER" == "claude-cli" ]] || [[ "$PLAN_MODEL_PROVIDER" == "auto" ]]; }; then
        if command -v claude >/dev/null 2>&1; then
            log "Generating PLAN.md via Claude Code CLI..."
            PLAN=$(claude -p "$prompt" 2>/dev/null || true)
        fi
    fi

    if [[ -z "$PLAN" ]] && { [[ "$PLAN_MODEL_PROVIDER" == "ollama" ]] || [[ "$PLAN_MODEL_PROVIDER" == "auto" ]]; }; then
        if command -v ollama >/dev/null 2>&1; then
            log "Generating PLAN.md via Ollama model $OLLAMA_PLANNER_MODEL..."
            PLAN=$(ollama run "$OLLAMA_PLANNER_MODEL" "$prompt" 2>/dev/null || true)
        fi
    fi

    if [[ -z "$PLAN" ]]; then
        log "Planner model unavailable, writing fallback PLAN.md template"
        PLAN="# Plan for issue #$ISSUE_NUMBER

## Context
- Route: $TOOL_MODE
- Title: $ISSUE_TITLE

## Steps
1. Reproduce and understand the requested change.
2. Identify impacted files and implement the code updates.
3. Run available tests or checks and capture output.
4. Prepare commit and PR with summary and validation notes.

## Acceptance Criteria
- Requested behavior is implemented.
- Existing tests pass, or failures are documented.
- PR includes clear change summary and test status.
"
    fi

    echo "$PLAN" > PLAN.md
    git add PLAN.md
    git commit -m "chore: add PLAN.md for issue #$ISSUE_NUMBER" || true
}

run_aider() {
    local attempt=0
    local aider_log_file=""
    local aider_prompt_file=""

    # Ensure LiteLLM/aider calls the local Ollama daemon by default.
    export OLLAMA_API_BASE

    if is_truthy "$AIDER_TRACE"; then
        mkdir -p "$AIDER_TRACE_DIR"
        local trace_stamp
        trace_stamp="issue-${ISSUE_NUMBER}-$(date '+%Y%m%d-%H%M%S')"
        aider_log_file="$AIDER_TRACE_DIR/aider-${trace_stamp}.log"
        aider_prompt_file="$AIDER_TRACE_DIR/aider-${trace_stamp}.prompt.md"
        cp PLAN.md "$aider_prompt_file"
        log "Aider trace enabled"
        log "Aider prompt: $aider_prompt_file"
        log "Aider output: $aider_log_file"
    fi

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        log "Aider attempt $attempt of $MAX_RETRIES..."
        log "Aider model: $AIDER_MODEL"
        log "Ollama API base: $OLLAMA_API_BASE"

        AIDER_ARGS=(
            --yes
            --no-pretty
            --model "$AIDER_MODEL"
            --message "$(cat PLAN.md)"
        )

        if [[ "$AIDER_ARCHITECT" == "1" || "$AIDER_ARCHITECT" == "true" ]]; then
            AIDER_ARGS=(--architect "${AIDER_ARGS[@]}")
        fi

        if [ -n "$AIDER_EDITOR_MODEL" ]; then
            AIDER_ARGS+=(--editor-model "$AIDER_EDITOR_MODEL")
        fi

        if [ -n "$aider_log_file" ]; then
            if aider "${AIDER_ARGS[@]}" 2>&1 | tee -a "$aider_log_file"; then
                return 0
            fi
        elif aider "${AIDER_ARGS[@]}"; then
            return 0
        fi

        log "Aider failed on attempt $attempt, retrying..."
        sleep 5
    done

    return 1
}

run_task_e2e() {
    export PIPELINE_PROMPT
    PIPELINE_PROMPT="$(cat PLAN.md)"

    if [ -n "$E2E_RUNNER_CMD" ]; then
        log "Running task-e2e via custom E2E_RUNNER_CMD..."
        bash -lc "$E2E_RUNNER_CMD"
        return $?
    fi

    if command -v claude >/dev/null 2>&1; then
        log "Running task-e2e via Claude Code..."
        claude -p "$PIPELINE_PROMPT"
        return $?
    fi

    fail "task-e2e requested but no e2e runner is configured"
}

run_selected_tool() {
    case "$TOOL_MODE" in
        task-code)
            run_aider
            ;;
        task-e2e)
            run_task_e2e
            ;;
        *)
            fail "Unknown tool mode: $TOOL_MODE"
            ;;
    esac
}

run_tests() {
    TEST_PASSED=false
    TEST_STATUS="not-run"

    log "Running tests..."
    if [ -f package.json ]; then
        TEST_STATUS="npm"
        if npm test --if-present 2>&1 | tee test_output.txt; then
            TEST_PASSED=true
            log "npm tests passed"
        else
            log "npm tests failed"
        fi
    elif [ -f pytest.ini ] || [ -d tests ] || find . -maxdepth 2 \( -name 'test_*.py' -o -name '*_test.py' \) | grep -q .; then
        TEST_STATUS="pytest"
        if pytest 2>&1 | tee test_output.txt; then
            TEST_PASSED=true
            log "pytest passed"
        else
            log "pytest failed"
        fi
    elif grep -q '^test:' Makefile 2>/dev/null; then
        TEST_STATUS="make test"
        if make test 2>&1 | tee test_output.txt; then
            TEST_PASSED=true
            log "make test passed"
        else
            log "make test failed"
        fi
    else
        TEST_STATUS="no-tests-detected"
        log "No supported automated test command detected"
    fi
}

prepare_repo
log "Tool mode: $TOOL_MODE"

if [ -d "$VENV_DIR" ]; then
    source "$VENV_DIR/bin/activate"
fi

if [[ "$PLAN_MODEL_PROVIDER" == "ollama" || "$PLAN_MODEL_PROVIDER" == "auto" || "$AIDER_MODEL" == ollama/* ]]; then
    prepare_ollama_models
fi

generate_plan

SUCCESS=false
if run_selected_tool; then
    SUCCESS=true
else
    log "Selected tool failed"
fi

TEST_PASSED=false
TEST_STATUS="not-run"
if [ "$SUCCESS" = true ]; then
    run_tests
fi

git add -A
git commit -m "feat: implement issue #$ISSUE_NUMBER - $ISSUE_TITLE" || true
git push origin "$BRANCH"

CREATE_PR=true
if [ "$PIPELINE_BRANCH_MODE" = "direct-target" ]; then
    CREATE_PR=false
fi

if [ "$SKIP_PR_CREATE" = "true" ]; then
    CREATE_PR=false
elif [ "$SKIP_PR_CREATE" = "false" ]; then
    CREATE_PR=true
fi

# A PR cannot be created when branch and base are the same.
if [ "$BRANCH" = "$BASE_BRANCH" ]; then
    CREATE_PR=false
fi

if [ "$TEST_PASSED" = true ]; then
    PR_TITLE="feat: $ISSUE_TITLE"
    PR_LABEL="ready-for-review"
    PR_BODY="Closes #$ISSUE_NUMBER

## Route

$TOOL_MODE

## What was done

$(cat PLAN.md)

## Tests

Automated checks passed via $TEST_STATUS."
else
    PR_TITLE="wip: $ISSUE_TITLE [needs review]"
    PR_LABEL="needs-human-review"
    PR_BODY="Closes #$ISSUE_NUMBER

## Route

$TOOL_MODE

## Status

Pipeline completed but validation status is: $TEST_STATUS.

## Plan

$(cat PLAN.md)

## Test output

\`\`\`
$(cat test_output.txt 2>/dev/null || echo 'no output')
\`\`\`"
fi

if [ "$CREATE_PR" = true ]; then
    gh pr create \
        --title "$PR_TITLE" \
        --body "$PR_BODY" \
        --base "$BASE_BRANCH" \
        --head "$BRANCH" || log "PR already exists or creation failed"

    gh pr edit "$BRANCH" --add-label "$PR_LABEL" >/dev/null 2>&1 || log "Label '$PR_LABEL' could not be added"
    log "Done - PR opened for issue #$ISSUE_NUMBER"
else
    gh issue edit "$ISSUE_NUMBER" --repo "$GITHUB_REPO" --add-label "$PR_LABEL" >/dev/null 2>&1 || log "Issue label '$PR_LABEL' could not be added"
    log "Done - committed directly to $BRANCH for issue #$ISSUE_NUMBER (PR skipped)"
fi
