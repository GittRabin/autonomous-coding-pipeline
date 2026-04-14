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
GITHUB_REPO="${GITHUB_REPO:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b}"
VENV_DIR="${VENV_DIR:-$HOME/.venv/pipeline}"
E2E_RUNNER_CMD="${E2E_RUNNER_CMD:-}"
MAX_RETRIES=3
DEFAULT_BRANCH="main"

log()  { echo "[pipeline #$ISSUE_NUMBER] $(date '+%H:%M:%S') $1"; }
fail() { echo "[pipeline #$ISSUE_NUMBER] $(date '+%H:%M:%S') FAILED: $1"; exit 1; }

[[ -z "$GITHUB_REPO" ]] && fail "GITHUB_REPO is not set"
[[ -z "$ANTHROPIC_API_KEY" ]] && fail "ANTHROPIC_API_KEY is not set"

BRANCH="task/issue-${ISSUE_NUMBER}"
REPO_PATH="$REPO_DIR/$(basename "$GITHUB_REPO")"

prepare_repo() {
    if [ ! -d "$REPO_PATH" ]; then
        log "Cloning repo..."
        mkdir -p "$REPO_DIR"
        gh repo clone "$GITHUB_REPO" "$REPO_PATH"
    fi

    cd "$REPO_PATH"
    git fetch origin
    DEFAULT_BRANCH="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
    git checkout "$DEFAULT_BRANCH"
    git pull origin "$DEFAULT_BRANCH"
    git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
}

generate_plan() {
    log "Generating PLAN.md via Claude..."

    PROMPT_BODY=$(jq -n \
        --arg title "$ISSUE_TITLE" \
        --arg body "$ISSUE_BODY" \
        --arg mode "$TOOL_MODE" \
        '{
            model: "claude-sonnet-4-5",
            max_tokens: 2048,
            messages: [{
                role: "user",
                content: ("You are a senior engineer. Decompose this task into a precise, ordered list of coding steps with acceptance criteria. Be specific about file paths and function names where possible.\n\nPreferred execution route: " + $mode + "\n\nTask title: " + $title + "\n\nTask details:\n" + $body + "\n\nOutput only the plan in markdown, no preamble.")
            }]
        }')

    PLAN=$(curl -s https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$PROMPT_BODY" | jq -r '.content[0].text')

    if [[ -z "$PLAN" || "$PLAN" == "null" ]]; then
        fail "Claude API returned empty plan"
    fi

    echo "$PLAN" > PLAN.md
    git add PLAN.md
    git commit -m "chore: add PLAN.md for issue #$ISSUE_NUMBER" || true
}

run_aider() {
    local attempt=0

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        log "Aider attempt $attempt of $MAX_RETRIES..."

        if aider \
            --architect \
            --model claude-sonnet-4-5 \
            --editor-model "ollama/$OLLAMA_MODEL" \
            --yes \
            --no-pretty \
            --message "$(cat PLAN.md)"; then
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

gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH" || log "PR already exists or creation failed"

gh pr edit "$BRANCH" --add-label "$PR_LABEL" >/dev/null 2>&1 || log "Label '$PR_LABEL' could not be added"

log "Done - PR opened for issue #$ISSUE_NUMBER"
