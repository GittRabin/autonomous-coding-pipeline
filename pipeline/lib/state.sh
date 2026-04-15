#!/bin/bash

# Local per-project issue history store.
# Keeps plan and test-output snapshots outside the repository and indexes them in SQLite.

sanitize_state_key() {
    local value="${1:-}"

    value="$(printf '%s' "$value" | sed -E 's#[^A-Za-z0-9._-]+#-#g; s#^-+##; s#-+$##')"
    [ -n "$value" ] || value="default"

    printf '%s\n' "$value"
}

resolve_project_name() {
    if [ -n "${PROJECT_NAME:-}" ]; then
        sanitize_state_key "$PROJECT_NAME"
        return 0
    fi

    if [ -n "${GITHUB_REPO:-}" ]; then
        sanitize_state_key "${GITHUB_REPO//\//-}"
        return 0
    fi

    printf 'default\n'
}

initialize_project_state_defaults() {
    local state_home=""
    local project_key=""

    state_home="${RABIN_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/rabin}"
    project_key="$(resolve_project_name)"

    PROJECT_NAME="$project_key"
    PIPELINE_STATE_ROOT="${PIPELINE_STATE_ROOT:-$state_home/$project_key}"

    if [ -z "${PIPELINE_STATE_DIR:-}" ]; then
        PIPELINE_STATE_DIR="$PIPELINE_STATE_ROOT/history"
    fi

    if [ -z "${PIPELINE_DB_PATH:-}" ]; then
        PIPELINE_DB_PATH="$PIPELINE_STATE_ROOT/issues.db"
    fi
}

persist_issue_state_snapshot() {
    local run_status="${1:-updated}"

    command -v python3 >/dev/null 2>&1 || return 0

    initialize_project_state_defaults
    mkdir -p "$PIPELINE_STATE_DIR" "$(dirname "$PIPELINE_DB_PATH")"

    PROJECT_NAME="$PROJECT_NAME" \
    GITHUB_REPO="${GITHUB_REPO:-}" \
    ISSUE_NUMBER="${ISSUE_NUMBER:-0}" \
    RUN_ID="${RUN_ID:-manual}" \
    TOOL_MODE="${TOOL_MODE:-unknown}" \
    PLAN_FILE="${PLAN_FILE:-}" \
    TEST_OUTPUT_FILE="${TEST_OUTPUT_FILE:-}" \
    PIPELINE_STATE_DIR="${PIPELINE_STATE_DIR:-}" \
    RUN_STATUS="$run_status" \
    python3 - "$PIPELINE_DB_PATH" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path
from datetime import datetime, timezone


def read_text(path_str: str) -> str:
    if not path_str:
        return ""
    path = Path(path_str)
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


db_path = sys.argv[1]
con = sqlite3.connect(db_path)
con.execute(
    """
    CREATE TABLE IF NOT EXISTS issue_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_name TEXT NOT NULL,
        repo TEXT,
        issue_number INTEGER NOT NULL,
        run_id TEXT NOT NULL,
        tool_mode TEXT,
        status TEXT,
        state_dir TEXT,
        plan_file TEXT,
        test_output_file TEXT,
        plan_text TEXT,
        test_output_text TEXT,
        updated_at TEXT NOT NULL,
        UNIQUE(project_name, run_id)
    )
    """
)

params = {
    "project_name": os.environ.get("PROJECT_NAME", "default"),
    "repo": os.environ.get("GITHUB_REPO", ""),
    "issue_number": int(os.environ.get("ISSUE_NUMBER", "0") or 0),
    "run_id": os.environ.get("RUN_ID", "manual"),
    "tool_mode": os.environ.get("TOOL_MODE", "unknown"),
    "status": os.environ.get("RUN_STATUS", "updated"),
    "state_dir": os.environ.get("PIPELINE_STATE_DIR", ""),
    "plan_file": os.environ.get("PLAN_FILE", ""),
    "test_output_file": os.environ.get("TEST_OUTPUT_FILE", ""),
    "plan_text": read_text(os.environ.get("PLAN_FILE", "")),
    "test_output_text": read_text(os.environ.get("TEST_OUTPUT_FILE", "")),
    "updated_at": datetime.now(timezone.utc).isoformat(),
}

con.execute(
    """
    INSERT INTO issue_runs (
        project_name, repo, issue_number, run_id, tool_mode, status,
        state_dir, plan_file, test_output_file, plan_text, test_output_text, updated_at
    ) VALUES (
        :project_name, :repo, :issue_number, :run_id, :tool_mode, :status,
        :state_dir, :plan_file, :test_output_file, :plan_text, :test_output_text, :updated_at
    )
    ON CONFLICT(project_name, run_id) DO UPDATE SET
        repo = excluded.repo,
        issue_number = excluded.issue_number,
        tool_mode = excluded.tool_mode,
        status = excluded.status,
        state_dir = excluded.state_dir,
        plan_file = excluded.plan_file,
        test_output_file = excluded.test_output_file,
        plan_text = excluded.plan_text,
        test_output_text = excluded.test_output_text,
        updated_at = excluded.updated_at
    """,
    params,
)
con.commit()
con.close()
PY
}
