#!/bin/bash

# Tool execution and validation helpers.

run_aider() {
    local attempt=0
    local aider_log_file=""
    local aider_prompt_file=""

    export OLLAMA_API_BASE

    if is_truthy "$AIDER_TRACE"; then
        mkdir -p "$AIDER_TRACE_DIR"
        aider_log_file="$AIDER_TRACE_DIR/${RUN_ID}.aider.log"
        aider_prompt_file="$AIDER_TRACE_DIR/${RUN_ID}.aider.prompt.md"
        cp "$PLAN_FILE" "$aider_prompt_file"
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
            --message "$(cat "$PLAN_FILE")"
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
    PIPELINE_PROMPT="$(cat "$PLAN_FILE")"

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
        if npm test --if-present 2>&1 | tee "$TEST_OUTPUT_FILE"; then
            TEST_PASSED=true
            log "npm tests passed"
        else
            log "npm tests failed"
        fi
    elif [ -f pytest.ini ] || [ -d tests ] || find . -maxdepth 2 \( -name 'test_*.py' -o -name '*_test.py' \) | grep -q .; then
        TEST_STATUS="pytest"
        if pytest 2>&1 | tee "$TEST_OUTPUT_FILE"; then
            TEST_PASSED=true
            log "pytest passed"
        else
            log "pytest failed"
        fi
    elif grep -q '^test:' Makefile 2>/dev/null; then
        TEST_STATUS="make test"
        if make test 2>&1 | tee "$TEST_OUTPUT_FILE"; then
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

execute_pipeline_run() {
    local snapshot_status="tool-failed"

    SUCCESS=false
    TEST_PASSED=false
    TEST_STATUS="not-run"

    generate_plan

    if run_selected_tool; then
        SUCCESS=true
        snapshot_status="completed"
    else
        log "Selected tool failed"
    fi

    if [ "$SUCCESS" = true ]; then
        run_tests
        if [ "$TEST_PASSED" != true ]; then
            snapshot_status="$TEST_STATUS"
        fi
    fi

    if declare -F persist_issue_state_snapshot >/dev/null 2>&1; then
        persist_issue_state_snapshot "$snapshot_status"
    fi
}
