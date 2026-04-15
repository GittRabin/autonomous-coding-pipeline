#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/config" "$TMP_DIR/bin" "$TMP_DIR/system-projects" "$TMP_DIR/systemd"

cat > "$TMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "daemon-reload" ]; then
    exit 0
fi
if [ "$1" = "enable" ] || [ "$1" = "restart" ]; then
    printf '%s %s\n' "$1" "$2"
    exit 0
fi
printf '%s\n' "$*"
exit 0
EOF

cat > "$TMP_DIR/bin/install" <<'EOF'
#!/usr/bin/env bash
mode=""
while getopts "m:" opt; do
    case "$opt" in
        m) mode="$OPTARG" ;;
    esac
done
shift $((OPTIND - 1))
if [ -n "$mode" ]; then
    chmod "$mode" "$1"
fi
cp "$1" "$2"
EOF

chmod +x "$TMP_DIR/bin/sudo" "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/install"

touch "$TMP_DIR/systemd/pipeline-poller@.service" "$TMP_DIR/systemd/pipeline-poller@.timer"

output="$(PATH="$TMP_DIR/bin:$PATH" \
    HOME="$TMP_DIR/home" \
    RABIN_CONFIG_DIR="$TMP_DIR/config" \
    RABIN_SYSTEM_PROJECT_DIR="$TMP_DIR/system-projects" \
    RABIN_SYSTEMD_DIR="$TMP_DIR/systemd" \
    GITHUB_REPO="owner/repo" \
    GITHUB_TOKEN="test-token" \
    bash "$ROOT_DIR/rabin" enable 2>&1 || true)"

echo "$output"

grep -q 'enabled pipeline-poller@default.timer for owner/repo' <<< "$output" || {
    echo "Expected rabin enable to bootstrap and enable the default profile from environment variables." >&2
    exit 1
}

[ -f "$TMP_DIR/config/default.env" ] || {
    echo "Expected default profile env file to be created automatically." >&2
    exit 1
}

grep -q '^GITHUB_REPO=owner/repo$' "$TMP_DIR/config/default.env" || {
    echo "Expected auto-created default profile to include the repo." >&2
    exit 1
}

grep -q "^REPO_DIR=$TMP_DIR/home/projects$" "$TMP_DIR/config/default.env" || {
    echo "Expected the default repo directory to use the home projects folder." >&2
    exit 1
}

grep -q '^OLLAMA_MODEL=qwen2.5-coder:7b$' "$TMP_DIR/config/default.env" || {
    echo "Expected the default Ollama model to use Qwen 2.5 Coder 7B." >&2
    exit 1
}

echo "PASS"
