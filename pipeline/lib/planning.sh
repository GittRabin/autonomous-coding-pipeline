#!/bin/bash

# Planning helpers.

build_plan_prompt() {
    cat <<EOF
You are a senior engineer. Decompose this task into a precise, ordered list of coding steps with acceptance criteria. Be specific about file paths and function names where possible.

Preferred execution route: $TOOL_MODE

Task title: $ISSUE_TITLE

Task details:
$ISSUE_BODY

Output only the plan in markdown, no preamble.
EOF
}

generate_plan_with_anthropic() {
    local prompt="$1"
    local prompt_body=""

    if [[ "$PLAN_MODEL_PROVIDER" != "anthropic" ]] && { [[ "$PLAN_MODEL_PROVIDER" != "auto" ]] || [[ -z "$ANTHROPIC_API_KEY" ]]; }; then
        return 0
    fi

    log "Generating PLAN.md via Anthropic..." >&2
    prompt_body=$(jq -n \
        --arg text "$prompt" \
        '{
            model: "claude-sonnet-4-5",
            max_tokens: 2048,
            messages: [{ role: "user", content: $text }]
        }')

    curl -s https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$prompt_body" | jq -r '.content[0].text // empty'
}

generate_plan_with_claude() {
    local prompt="$1"

    if [[ "$PLAN_MODEL_PROVIDER" != "claude" && "$PLAN_MODEL_PROVIDER" != "claude-cli" && "$PLAN_MODEL_PROVIDER" != "auto" ]]; then
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        return 0
    fi

    log "Generating PLAN.md via Claude terminal..." >&2
    claude -p "$prompt" 2>/dev/null || true
}

generate_plan_with_ollama() {
    local prompt="$1"

    if [[ "$PLAN_MODEL_PROVIDER" != "ollama" && "$PLAN_MODEL_PROVIDER" != "auto" ]]; then
        return 0
    fi

    if ! command -v ollama >/dev/null 2>&1; then
        return 0
    fi

    log "Generating PLAN.md via Ollama model $OLLAMA_PLANNER_MODEL..." >&2
    ollama run "$OLLAMA_PLANNER_MODEL" "$prompt" 2>/dev/null || true
}

write_fallback_plan() {
    cat <<EOF
# Plan for issue #$ISSUE_NUMBER

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
EOF
}

generate_plan() {
    local prompt=""

    prompt="$(build_plan_prompt)"
    PLAN="$(generate_plan_with_claude "$prompt")"

    if [[ -z "$PLAN" ]]; then
        PLAN="$(generate_plan_with_anthropic "$prompt")"
    fi

    if [[ -z "$PLAN" ]]; then
        PLAN="$(generate_plan_with_ollama "$prompt")"
    fi

    if [[ -z "$PLAN" ]]; then
        log "Planner model unavailable, writing fallback PLAN.md template"
        PLAN="$(write_fallback_plan)"
    fi

    echo "$PLAN" > "$PLAN_FILE"
}
