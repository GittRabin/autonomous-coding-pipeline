#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'CLAUDE_PLAN\n'
EOF

cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"content":[{"text":"API_PLAN"}]}'
EOF

cat > "$TMP_DIR/bin/ollama" <<'EOF'
#!/usr/bin/env bash
printf 'OLLAMA_PLAN\n'
EOF

chmod +x "$TMP_DIR/bin/claude" "$TMP_DIR/bin/curl" "$TMP_DIR/bin/ollama"

PLAN_FILE="$TMP_DIR/plan.md"

output="$({
    PATH="$TMP_DIR/bin:$PATH"
    ISSUE_NUMBER=42
    ISSUE_TITLE="Test planning"
    ISSUE_BODY="Make the planner choose the best route"
    TOOL_MODE="task-code"
    PLAN_MODEL_PROVIDER="auto"
    ANTHROPIC_API_KEY="test-key"
    OLLAMA_PLANNER_MODEL="dummy"

    source "$ROOT_DIR/pipeline/lib/common.sh"
    source "$ROOT_DIR/pipeline/lib/planning.sh"
    generate_plan
    cat "$PLAN_FILE"
} 2>&1)"

echo "$output"

grep -q 'CLAUDE_PLAN' <<< "$output" || {
    echo "Expected planning to try the terminal claude command first in auto mode." >&2
    exit 1
}

if grep -q 'API_PLAN' <<< "$output" || grep -q 'OLLAMA_PLAN' <<< "$output"; then
    echo "Did not expect fallback planners to run when Claude succeeded." >&2
    exit 1
fi

echo "PASS"
