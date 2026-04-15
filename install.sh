#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
fail() { echo -e "${RED}[error]${NC} $1"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

START_TS="$(date +%s)"

if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # When piped via curl | bash, BASH_SOURCE can be unset.
    SCRIPT_DIR="$PWD"
fi
INSTALL_REPO="${INSTALL_REPO:-GittRabin/autonomous-coding-pipeline}"
INSTALL_REF="${INSTALL_REF:-main}"
SOURCE_DIR="$SCRIPT_DIR"

if [ ! -d "$SCRIPT_DIR/poller" ] || [ ! -d "$SCRIPT_DIR/pipeline" ] || [ ! -d "$SCRIPT_DIR/systemd" ] || [ ! -f "$SCRIPT_DIR/rabin" ] || [ ! -f "$SCRIPT_DIR/Makefile" ]; then
    log "Standalone installer detected, downloading ${INSTALL_REPO}@${INSTALL_REF}..."
    TMP_BOOTSTRAP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_BOOTSTRAP_DIR"' EXIT

    curl -fsSL "https://codeload.github.com/${INSTALL_REPO}/tar.gz/${INSTALL_REF}" | tar -xz -C "$TMP_BOOTSTRAP_DIR"
    SOURCE_DIR="$(find "$TMP_BOOTSTRAP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "$SOURCE_DIR" ] || fail "Failed to download installer source for ${INSTALL_REPO}@${INSTALL_REF}"
fi

OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b}"
WORK_DIR="${WORK_DIR:-$HOME/pipeline}"
REPO_DIR="${REPO_DIR:-$HOME/projects}"
VENV_DIR="${VENV_DIR:-$HOME/.venv/pipeline}"
POLL_INTERVAL_MINUTES="${POLL_INTERVAL_MINUTES:-5}"

[[ "$POLL_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || fail "POLL_INTERVAL_MINUTES must be a whole number"

recover_apt_state() {
    if sudo dpkg --audit >/dev/null 2>&1; then
        :
    fi

    sudo dpkg --configure -a || true
    sudo apt-get -f install -y -qq || true
}

log "Updating apt and installing system deps..."
recover_apt_state
sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl wget git jq tmux \
    python3 python3-pip python3-venv \
    build-essential libssl-dev

ensure_node_lts() {
    log "Installing/updating Node.js to latest LTS..."

    # Recover first in case previous installs left dpkg in a broken state.
    recover_apt_state

    # Purge distro Node packages that frequently conflict with NodeSource.
    if dpkg -s libnode-dev >/dev/null 2>&1 || dpkg -s nodejs-doc >/dev/null 2>&1; then
        warn "Removing conflicting distro Node packages (libnode-dev/nodejs-doc)..."
        sudo apt-get remove -y -qq libnode-dev nodejs-doc || true
    fi

    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -

    if ! sudo apt-get install -y -qq nodejs; then
        warn "Node.js install failed, attempting dpkg recovery..."
        recover_apt_state

        # Last-resort cleanup for stale ubuntu node headers package.
        sudo apt-get remove -y -qq libnode-dev nodejs-doc || true

        sudo apt-get install -y -qq nodejs
    fi

    local major
    major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
    [ "$major" -ge 18 ] || fail "Node.js >=18 is required, found $(node -v)"
    log "Node.js ready (LTS channel): $(node -v), npm: $(npm -v)"
}

ensure_node_lts

if ! command -v gh &>/dev/null; then
    log "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq gh
else
    log "GitHub CLI already installed: $(gh --version | head -1)"
fi

if ! gh auth status >/dev/null 2>&1; then
    warn "GitHub CLI is installed but not authenticated. Run 'gh auth login' before 'rabin configure'."
fi

if ! command -v ollama &>/dev/null; then
    log "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    log "Ollama already installed: $(ollama --version)"
fi

if ! pgrep -x ollama &>/dev/null; then
    log "Starting Ollama service..."
    nohup ollama serve > "$HOME/ollama.log" 2>&1 &
    sleep 3
fi

log "Pulling Ollama model: $OLLAMA_MODEL (this may take a while)..."
ollama pull "$OLLAMA_MODEL"

log "Setting up Python venv..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

log "Installing aider..."
pip install --upgrade pip -q
pip install aider-chat -q

aider --version || fail "aider install failed"

log "Linking aider into user bin..."
mkdir -p "$HOME/.local/bin"
ln -sf "$VENV_DIR/bin/aider" "$HOME/.local/bin/aider"

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    warn "~/.local/bin is not on PATH in this shell. Add this to ~/.bashrc:"
    warn "  export PATH=\"$HOME/.local/bin:$PATH\""
fi

log "Installing pipeline files to $WORK_DIR..."
mkdir -p "$WORK_DIR"

rm -rf "$WORK_DIR/poller" "$WORK_DIR/pipeline" "$WORK_DIR/systemd"
cp -r "$SOURCE_DIR/poller"   "$WORK_DIR/poller"
cp -r "$SOURCE_DIR/pipeline" "$WORK_DIR/pipeline"
cp -r "$SOURCE_DIR/systemd"  "$WORK_DIR/systemd"
cp    "$SOURCE_DIR/Makefile" "$WORK_DIR/Makefile"
cp    "$SOURCE_DIR/rabin"    "$WORK_DIR/rabin"

rm -rf "$WORK_DIR/poller/node_modules"
chmod +x "$WORK_DIR/pipeline/run_pipeline.sh"
chmod +x "$WORK_DIR/rabin"

log "Installing rabin CLI..."
sudo install -m 0755 "$WORK_DIR/rabin" /usr/local/bin/rabin

log "Installing poller dependencies..."
npm install --prefix "$WORK_DIR/poller" -q

log "Installing systemd poller templates..."
sudo sed \
    -e "s|@@USER@@|$USER|g" \
    -e "s|@@INSTALL_DIR@@|$WORK_DIR|g" \
    "$WORK_DIR/systemd/pipeline-poller.service.template" \
    > /tmp/pipeline-poller@.service

sudo sed \
    -e "s|@@DEFAULT_POLL_INTERVAL_MINUTES@@|$POLL_INTERVAL_MINUTES|g" \
    "$WORK_DIR/systemd/pipeline-poller.timer.template" \
    > /tmp/pipeline-poller@.timer

if systemctl list-unit-files 2>/dev/null | grep -q '^pipeline-webhook\.service'; then
    warn "Removing legacy webhook service..."
    sudo systemctl stop pipeline-webhook || true
    sudo systemctl disable pipeline-webhook || true
    sudo rm -f /etc/systemd/system/pipeline-webhook.service
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^pipeline-poller\.timer'; then
    warn "Removing legacy non-instance poller units..."
    sudo systemctl stop pipeline-poller.timer || true
    sudo systemctl disable pipeline-poller.timer || true
    sudo rm -f /etc/systemd/system/pipeline-poller.service /etc/systemd/system/pipeline-poller.timer
fi

sudo mv /tmp/pipeline-poller@.service /etc/systemd/system/pipeline-poller@.service
sudo mv /tmp/pipeline-poller@.timer /etc/systemd/system/pipeline-poller@.timer
sudo systemctl daemon-reload

auto_enable_default_profile() {
    local auto_repo="${GITHUB_REPO:-}"
    local auto_token="${GITHUB_TOKEN:-}"

    if [ -z "$auto_repo" ] && command -v gh >/dev/null 2>&1; then
        auto_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    fi

    if [ -z "$auto_repo" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
        auto_repo="$(echo "$remote_url" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
    fi

    if [ -z "$auto_token" ] && command -v gh >/dev/null 2>&1; then
        auto_token="$(gh auth token 2>/dev/null || true)"
    fi

    if [ -n "$auto_repo" ] && [ -n "$auto_token" ]; then
        log "Auto-enabling default rabin profile for $auto_repo..."
        if GITHUB_REPO="$auto_repo" GITHUB_TOKEN="$auto_token" WORK_DIR="$WORK_DIR" REPO_DIR="$REPO_DIR" VENV_DIR="$VENV_DIR" OLLAMA_MODEL="$OLLAMA_MODEL" POLL_INTERVAL_MINUTES="$POLL_INTERVAL_MINUTES" rabin enable default; then
            log "Default profile enabled"
        else
            warn "Automatic timer enable failed. You can run 'rabin enable default' later."
        fi
    else
        warn "Skipping automatic timer enable because repo or GitHub auth is unavailable. Run 'rabin enable default' later, or use 'rabin configure' for custom profiles."
    fi
}

auto_enable_default_profile

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Bootstrap complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Ollama model : $OLLAMA_MODEL"
echo "  Install dir  : $WORK_DIR"
echo "  Timer default: ${POLL_INTERVAL_MINUTES} minutes"
echo ""
echo "  Next steps:"
echo "    1) Authenticate GitHub CLI (once, if needed):"
echo "       gh auth login"
echo ""
echo "    2) Verify active profiles:"
echo "       rabin status --all"
echo ""
echo "    3) Optional: for multi-project or custom setup:"
echo "       rabin configure"
echo ""
echo "  Global CLI:"
echo "    rabin --help   — show command help"
echo "    rabin configure — auto-detect repo, create profile, enable timer"
echo "    rabin urgent <profile> — trigger immediate poll"
echo ""

END_TS="$(date +%s)"
ELAPSED_SEC=$((END_TS - START_TS))
ELAPSED_MIN=$((ELAPSED_SEC / 60))
ELAPSED_REM_SEC=$((ELAPSED_SEC % 60))
echo "  Install time : ${ELAPSED_MIN}m ${ELAPSED_REM_SEC}s"
echo ""
