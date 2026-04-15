#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/config" "$TMP_DIR/bin"

cat > "$TMP_DIR/config/repo-one.env" <<'EOF'
GITHUB_REPO=owner/repo-one
GITHUB_TOKEN=test-token
EOF

cat > "$TMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--no-pager" ]; then
    shift
fi
printf '%s\n' "$*"
exit 0
EOF

chmod +x "$TMP_DIR/bin/sudo" "$TMP_DIR/bin/systemctl"

if command -v sudo >/dev/null 2>&1; then
    sudo touch /etc/systemd/system/pipeline-poller@.service /etc/systemd/system/pipeline-poller@.timer
fi

output="$(PATH="$TMP_DIR/bin:$PATH" RABIN_CONFIG_DIR="$TMP_DIR/config" bash "$ROOT_DIR/rabin" status 2>&1 || true)"

echo "$output"

grep -q 'pipeline-poller@repo-one.timer' <<< "$output" || {
    echo "Expected rabin status to target the only saved profile when no profile is provided." >&2
    exit 1
}

if grep -q 'pipeline-poller@default.timer' <<< "$output"; then
    echo "Did not expect rabin status to fall back to the empty default profile when exactly one saved profile exists." >&2
    exit 1
fi

echo "PASS"
