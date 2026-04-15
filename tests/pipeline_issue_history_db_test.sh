#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/repo" "$TMP_DIR/home"

export HOME="$TMP_DIR/home"
export ISSUE_NUMBER=55
export ISSUE_TITLE="Store issue history"
export ISSUE_BODY="Keep plan and test output in a per-project local history store"
export TOOL_MODE="task-code"
export GITHUB_REPO="owner/repo"
export PROJECT_NAME="project-alpha"
export REPO_PATH="$TMP_DIR/repo"
export PIPELINE_STATE_DIR=""
export AIDER_TRACE_DIR=""
export PIPELINE_REPO_STATE_SUBDIR=".rabin/history"
export TEST_STATUS="pytest"
export TEST_PASSED=true

source "$ROOT_DIR/pipeline/lib/common.sh"
source "$ROOT_DIR/pipeline/lib/repo.sh"
if [ -f "$ROOT_DIR/pipeline/lib/state.sh" ]; then
    source "$ROOT_DIR/pipeline/lib/state.sh"
fi

setup_run_state

echo "Plan text" > "$PLAN_FILE"
echo "Test output text" > "$TEST_OUTPUT_FILE"

persist_issue_state_snapshot "completed"

EXPECTED_STATE_DIR="$HOME/.local/state/rabin/project-alpha/history"
EXPECTED_DB_PATH="$HOME/.local/state/rabin/project-alpha/issues.db"

[ "$PIPELINE_STATE_DIR" = "$EXPECTED_STATE_DIR" ] || {
    echo "Expected PIPELINE_STATE_DIR to default to the per-project state folder." >&2
    exit 1
}

[ -f "$EXPECTED_DB_PATH" ] || {
    echo "Expected a sqlite issue history database to be created." >&2
    exit 1
}

python3 - "$EXPECTED_DB_PATH" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
row = con.execute(
    "select issue_number, status, plan_text, test_output_text from issue_runs where project_name = ? order by rowid desc limit 1",
    ("project-alpha",),
).fetchone()
assert row is not None, "missing issue history row"
assert row[0] == 55, row
assert row[1] == "completed", row
assert row[2].strip() == "Plan text", row
assert row[3].strip() == "Test output text", row
print("PASS")
PY
