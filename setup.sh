#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
fail() { echo -e "${RED}[error]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b}"
WORK_DIR="${WORK_DIR:-$HOME/pipeline}"
REPO_DIR="${REPO_DIR:-$HOME/repos}"
VENV_DIR="${VENV_DIR:-$HOME/.venv/pipeline}"
POLL_INTERVAL_MINUTES="${POLL_INTERVAL_MINUTES:-5}"
TRIGGER_LABEL="${TRIGGER_LABEL:-overnight-task}"
PROCESSING_LABEL="${PROCESSING_LABEL:-processing}"
TASK_LABEL_CODE="${TASK_LABEL_CODE:-task-code}"
TASK_LABEL_E2E="${TASK_LABEL_E2E:-task-e2e}"
E2E_RUNNER_CMD="${E2E_RUNNER_CMD:-}"

[[ -z "$ANTHROPIC_API_KEY" ]] && fail "ANTHROPIC_API_KEY is not set"
[[ -z "$GITHUB_TOKEN" ]]      && fail "GITHUB_TOKEN is not set"
[[ -z "$GITHUB_REPO" ]]       && fail "GITHUB_REPO is not set (e.g. yourname/yourrepo)"
[[ "$POLL_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || fail "POLL_INTERVAL_MINUTES must be a whole number"

log "Updating apt and installing system deps..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl wget git jq tmux \
    python3 python3-pip python3-venv \
    build-essential libssl-dev nodejs npm

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

echo "$GITHUB_TOKEN" | gh auth login --with-token

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

log "Installing pipeline files to $WORK_DIR..."
mkdir -p "$WORK_DIR"

rm -rf "$WORK_DIR/poller" "$WORK_DIR/pipeline" "$WORK_DIR/systemd"
cp -r "$SCRIPT_DIR/poller"   "$WORK_DIR/poller"
cp -r "$SCRIPT_DIR/pipeline" "$WORK_DIR/pipeline"
cp -r "$SCRIPT_DIR/systemd"  "$WORK_DIR/systemd"
cp    "$SCRIPT_DIR/Makefile" "$WORK_DIR/Makefile"

rm -rf "$WORK_DIR/poller/node_modules"
chmod +x "$WORK_DIR/pipeline/run_pipeline.sh"

log "Installing poller dependencies..."
npm install --prefix "$WORK_DIR/poller" -q

log "Installing systemd poller service and timer..."
sudo sed \
    -e "s|@@USER@@|$USER|g" \
    -e "s|@@INSTALL_DIR@@|$WORK_DIR|g" \
    -e "s|@@ANTHROPIC_API_KEY@@|$ANTHROPIC_API_KEY|g" \
    -e "s|@@GITHUB_TOKEN@@|$GITHUB_TOKEN|g" \
    -e "s|@@GITHUB_REPO@@|$GITHUB_REPO|g" \
    -e "s|@@REPO_DIR@@|$REPO_DIR|g" \
    -e "s|@@OLLAMA_MODEL@@|$OLLAMA_MODEL|g" \
    -e "s|@@VENV_DIR@@|$VENV_DIR|g" \
    -e "s|@@TRIGGER_LABEL@@|$TRIGGER_LABEL|g" \
    -e "s|@@PROCESSING_LABEL@@|$PROCESSING_LABEL|g" \
    -e "s|@@TASK_LABEL_CODE@@|$TASK_LABEL_CODE|g" \
    -e "s|@@TASK_LABEL_E2E@@|$TASK_LABEL_E2E|g" \
    -e "s|@@E2E_RUNNER_CMD@@|$E2E_RUNNER_CMD|g" \
    "$WORK_DIR/systemd/pipeline-poller.service.template" \
    > /tmp/pipeline-poller.service

sudo sed \
    -e "s|@@POLL_INTERVAL_MINUTES@@|$POLL_INTERVAL_MINUTES|g" \
    "$WORK_DIR/systemd/pipeline-poller.timer.template" \
    > /tmp/pipeline-poller.timer

if systemctl list-unit-files 2>/dev/null | grep -q '^pipeline-webhook\.service'; then
    warn "Removing legacy webhook service..."
    sudo systemctl stop pipeline-webhook || true
    sudo systemctl disable pipeline-webhook || true
    sudo rm -f /etc/systemd/system/pipeline-webhook.service
fi

sudo mv /tmp/pipeline-poller.service /etc/systemd/system/pipeline-poller.service
sudo mv /tmp/pipeline-poller.timer /etc/systemd/system/pipeline-poller.timer
sudo systemctl daemon-reload
sudo systemctl enable pipeline-poller.timer
sudo systemctl restart pipeline-poller.timer

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Setup complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Repo         : $GITHUB_REPO"
echo "  Poll every   : ${POLL_INTERVAL_MINUTES} minutes"
echo "  Logs         : sudo journalctl -u pipeline-poller.service -u pipeline-poller.timer -f"
echo "  Ollama model : $OLLAMA_MODEL"
echo "  Install dir  : $WORK_DIR"
echo ""
echo "  Routing labels:"
echo "    $TASK_LABEL_CODE  — file-oriented code changes via Aider"
echo "    $TASK_LABEL_E2E   — e2e or MCP-heavy tasks via custom runner"
echo ""
echo "  State labels:"
echo "    $TRIGGER_LABEL    — waiting"
echo "    $PROCESSING_LABEL — running on the VM"
echo ""
echo "  Day-to-day ops (from $WORK_DIR):"
echo "    make logs      — tail poller and timer logs"
echo "    make status    — check timer status"
echo "    make restart   — restart the timer"
echo "    make run-now   — trigger a poll immediately"
echo ""
echo "  Next step: create an issue with labels '$TRIGGER_LABEL' and either '$TASK_LABEL_CODE' or '$TASK_LABEL_E2E'."
echo ""
