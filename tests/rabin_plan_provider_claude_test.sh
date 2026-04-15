#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/config"

output="$(HOME="$TMP_DIR/home" \
    RABIN_CONFIG_DIR="$TMP_DIR/config" \
    GITHUB_REPO="owner/repo" \
    GITHUB_TOKEN="test-token" \
    bash "$ROOT_DIR/rabin" configure demo --plan-model-provider claude --no-enable 2>&1 || true)"

echo "$output"

grep -q 'profile saved: demo' <<< "$output" || {
    echo "Expected rabin configure to accept the claude provider name." >&2
    exit 1
}

grep -q '^PLAN_MODEL_PROVIDER=claude$' "$TMP_DIR/config/demo.env" || {
    echo "Expected saved profile to record PLAN_MODEL_PROVIDER=claude." >&2
    exit 1
}

echo "PASS"
