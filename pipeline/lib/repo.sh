#!/bin/bash

# Repository preparation and local run-state setup.

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

ensure_local_git_exclude() {
    local relative_path="$1"
    local exclude_file

    [ -n "$relative_path" ] || return 0

    exclude_file="$(git rev-parse --git-path info/exclude)"
    touch "$exclude_file"

    if ! grep -Fxq "$relative_path" "$exclude_file"; then
        echo "$relative_path" >> "$exclude_file"
        log "Added local git exclude: $relative_path"
    fi
}

repo_relative_path_if_inside() {
    local target_path="$1"

    [ -n "$target_path" ] || return 0

    case "$target_path" in
        "$REPO_PATH"/*)
            printf '%s\n' "${target_path#"$REPO_PATH"/}"
            ;;
    esac
}

protect_pipeline_artifacts_from_git() {
    local tracked_paths=()
    local relative_path=""
    local legacy_artifacts=(
        "PLAN.md"
        "plan.md"
        "TEST_OUTPUT.txt"
        "test_output.txt"
    )

    relative_path="$(repo_relative_path_if_inside "$PIPELINE_STATE_DIR")"
    if [ -n "$relative_path" ]; then
        ensure_local_git_exclude "$relative_path/"
        tracked_paths+=("$relative_path")
    fi

    relative_path="$(repo_relative_path_if_inside "${AIDER_TRACE_DIR:-}")"
    if [ -n "$relative_path" ]; then
        ensure_local_git_exclude "$relative_path/"
        tracked_paths+=("$relative_path")
    fi

    for relative_path in "${legacy_artifacts[@]}"; do
        ensure_local_git_exclude "$relative_path"
        tracked_paths+=("$relative_path")
    done

    if [ "${#tracked_paths[@]}" -gt 0 ]; then
        git rm -r --cached --ignore-unmatch -- "${tracked_paths[@]}" >/dev/null 2>&1 || true
    fi
}

setup_run_state() {
    if declare -F initialize_project_state_defaults >/dev/null 2>&1; then
        initialize_project_state_defaults
    fi

    if [ -z "$PIPELINE_STATE_DIR" ]; then
        PIPELINE_STATE_DIR="$REPO_PATH/$PIPELINE_REPO_STATE_SUBDIR"
    fi

    if [ -z "$AIDER_TRACE_DIR" ] && is_truthy "${AIDER_TRACE:-false}"; then
        AIDER_TRACE_DIR="${PIPELINE_STATE_ROOT:-$PIPELINE_STATE_DIR}/traces"
    fi

    mkdir -p "$PIPELINE_STATE_DIR"
    RUN_ID="issue-${ISSUE_NUMBER}-$(date '+%Y%m%d-%H%M%S')"
    ISSUE_STATE_DIR="$PIPELINE_STATE_DIR/issue-${ISSUE_NUMBER}"
    mkdir -p "$ISSUE_STATE_DIR"
    PLAN_FILE="$ISSUE_STATE_DIR/${RUN_ID}.plan.md"
    TEST_OUTPUT_FILE="$ISSUE_STATE_DIR/${RUN_ID}.test_output.txt"

    protect_pipeline_artifacts_from_git

    log "Run state dir: $PIPELINE_STATE_DIR"
    log "Issue state dir: $ISSUE_STATE_DIR"
    log "Plan file: $PLAN_FILE"
    log "Test output file: $TEST_OUTPUT_FILE"
}

activate_runtime() {
    if [ -d "$VENV_DIR" ]; then
        # shellcheck disable=SC1090
        source "$VENV_DIR/bin/activate"
    fi

    if [[ "$PLAN_MODEL_PROVIDER" == "ollama" || "$PLAN_MODEL_PROVIDER" == "auto" || "$AIDER_MODEL" == ollama/* ]]; then
        prepare_ollama_models
    fi
}
