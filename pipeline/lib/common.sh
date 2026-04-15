#!/bin/bash

# Shared helpers used by the pipeline entrypoint.

log()  { echo "[pipeline #$ISSUE_NUMBER] $(date '+%H:%M:%S') $1"; }
fail() { echo "[pipeline #$ISSUE_NUMBER] $(date '+%H:%M:%S') FAILED: $1"; exit 1; }

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
