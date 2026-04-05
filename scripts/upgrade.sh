#!/bin/bash
# PAI-Incus — Upgrade existing installation
# Safe to run on an existing container without losing data.
#
# What this upgrades:
#   - Container system packages
#   - Shell environment (.bashrc/.zshrc PAI blocks)
#   - Claude Code (migrates npm→native if needed, runs claude update)
#
# What this does NOT touch:
#   - Your data in ~/pai-workspace/
#   - Your Claude Code authentication and sessions
#   - Your PAI configuration (~/.claude/ inside the container)
#   - Your work/ directory
#
# Usage:
#   ./scripts/upgrade.sh                  # Upgrade default instance
#   ./scripts/upgrade.sh --name=v2        # Upgrade named instance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh" "$@"

STEP=0
TOTAL=5

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${CYAN}[${STEP}/${TOTAL}]${NC} ${BOLD}$1${NC}"
}

ok()   { echo -e "        ${GREEN}✓${NC} $1"; }
skip() { echo -e "        ${YELLOW}⊘${NC} $1 (already up to date)"; }

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Sandbox My AI — PAI-Incus Upgrade${NC}"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo -e "${BOLD}  Instance: ${CYAN}${INSTANCE_NAME}${NC}"
fi
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This upgrades your existing installation without losing data."
echo "  Your workspace, config, and sessions are preserved."
echo ""

# ─── Step 1: Ensure shared directories exist ──────────────────

step "Checking shared directories..."

CREATED=0

for dir in "${PAI_WORKSPACE_DIRS[@]}"; do
  if [ ! -d "$WORKSPACE/$dir" ]; then
    mkdir -p "$WORKSPACE/$dir"
    CREATED=$((CREATED + 1))
  fi
done

if [ $CREATED -gt 0 ]; then
  ok "Created $CREATED missing directories in $WORKSPACE/"
else
  skip "All directories exist"
fi

# ─── Step 2: Ensure container is running ──────────────────────

step "Checking container..."

if ! pai_ensure_running; then
  echo -e "        ${RED}✗${NC} No container named '${CONTAINER_NAME}' found. Run ./install.sh for a fresh install."
  exit 1
fi
ok "Container running"

# ─── Step 3: Update container tools and environment ───────────

step "Updating container tools and environment..."

# Re-run the environment block (idempotent), then update system packages
pai_exec bash -c '
  SENTINEL="# --- PAI environment (managed by provision.sh) ---"
  ENV_BLOCK='\''
# --- PAI environment (managed by provision.sh) ---

# Bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Claude Code
export PATH="$HOME/.claude/bin:$PATH"

# Local binaries (pip --user, etc.)
export PATH="$HOME/.local/bin:$PATH"

# Go
export PATH="$HOME/go/bin:$PATH"

# Node global (npm install -g)
export PATH="$HOME/.npm-global/bin:$PATH"

# Default editor
export EDITOR=nano

# Audio — PipeWire socket from host
export PIPEWIRE_REMOTE=/tmp/pipewire-0
export PULSE_SERVER=unix:/run/user/1000/pulse/native

# PAI launcher
alias pai='\''bun $HOME/.claude/PAI/Tools/pai.ts'\''

# --- end PAI environment ---
'\''

  for rcfile in ~/.bashrc ~/.zshrc; do
    touch "$rcfile"
    if grep -qF "$SENTINEL" "$rcfile" 2>/dev/null; then
      sed -i "/$SENTINEL/,/# --- end PAI environment ---/d" "$rcfile"
    fi
    echo "$ENV_BLOCK" >> "$rcfile"
  done

  echo "[+] PAI environment block updated"

  # Update system packages
  sudo apt-get update -qq 2>/dev/null
  sudo apt-get upgrade -y -qq 2>/dev/null
  echo "[+] System packages updated"
'
ok "Container environment and packages updated"

# ─── Step 4: Upgrade Claude Code ─────────────────────────────

step "Upgrading Claude Code..."

pai_exec bash -lc '
  CLAUDE_PATH=$(command -v claude 2>/dev/null || echo "")

  if [ -z "$CLAUDE_PATH" ]; then
    echo "[!] Claude Code not found — installing native..."
    curl -fsSL https://claude.ai/install.sh | bash
  elif echo "$CLAUDE_PATH" | grep -qE "node_modules|npm|lib/node_modules"; then
    echo "[!] Claude Code installed via npm (old method): $CLAUDE_PATH"
    echo "[!] Removing npm version and installing native..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    bun remove -g @anthropic-ai/claude-code 2>/dev/null || true
    curl -fsSL https://claude.ai/install.sh | bash
  else
    echo "[=] Claude Code already native: $CLAUDE_PATH"
    echo "[+] Running claude update..."
    claude update 2>/dev/null || echo "[!] claude update not available — already latest or manual update needed"
  fi
'
ok "Claude Code up to date"

# ─── Step 5: Reinstall CLI commands ──────────────────────────

step "Updating CLI commands..."

BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/pai"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# Install common.sh to lib
cp "$SCRIPT_DIR/common.sh" "$LIB_DIR/common.sh"
chmod +x "$LIB_DIR/common.sh"

for cmd in pai-start pai-stop pai-status pai-talk pai-shell; do
  cp "$SCRIPT_DIR/../bin/$cmd" "$BIN_DIR/$cmd"
  chmod +x "$BIN_DIR/$cmd"
done
ok "CLI commands updated in $BIN_DIR/"

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Upgrade complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  What was preserved:"
echo "    - All files in $WORKSPACE/"
echo "    - Claude Code authentication"
echo "    - PAI configuration (~/.claude/)"
echo "    - Claude Code sessions"
echo ""
echo "  What was updated:"
echo "    - Container system packages"
echo "    - Shell environment (.bashrc/.zshrc)"
echo "    - Claude Code"
echo "    - CLI commands"
echo ""
