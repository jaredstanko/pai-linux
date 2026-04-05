#!/bin/bash
# PAI Provisioning Script — Deterministic Container Setup
# Run this INSIDE the Incus container as the 'claude' user.
# Called automatically by install.sh on the host.
#
# All versions are sourced from versions.env (single source of truth).
# This script is idempotent — safe to re-run if interrupted.
#
# Usage:
#   bash ~/provision.sh

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/tmp/pai-provision.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⊘${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }
step() { echo -e "\n${CYAN}[$1]${NC} ${BOLD}$2${NC}"; }

# --- Retry helper ---------------------------------------------------------
retry() {
  local max_attempts=3
  local delay=5
  local attempt=1
  local cmd="$@"

  while [ $attempt -le $max_attempts ]; do
    if eval "$cmd"; then
      return 0
    fi
    if [ $attempt -lt $max_attempts ]; then
      warn "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  err "Failed after $max_attempts attempts: $cmd"
  return 1
}

# --- Load version manifest ------------------------------------------------
VERSIONS_FILE="$HOME/versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
  err "versions.env not found at $VERSIONS_FILE"
  err "This file should be pushed by install.sh before running provision."
  exit 1
fi
source "$VERSIONS_FILE"

echo -e "${BOLD}"
echo "============================================"
echo "  PAI Provisioning (Deterministic)"
echo "============================================"
echo -e "${NC}"
echo "  Versions from manifest:"
echo "    Bun:         ${BUN_VERSION}"
echo "    Claude Code: ${CLAUDE_CODE_VERSION}"
echo "    Playwright:  ${PLAYWRIGHT_VERSION}"
echo ""

# --- Step 1: System packages ----------------------------------------------
step "1/7" "Installing system packages..."

retry "sudo apt-get update -qq"
# shellcheck disable=SC2086
retry "sudo apt-get install -y -qq $APT_PACKAGES"

# Install PulseAudio client for audio passthrough
retry "sudo apt-get install -y -qq pulseaudio-utils libpulse0 pipewire-pulse"
log "System packages installed"

# --- Step 2: Bun ----------------------------------------------------------
step "2/7" "Installing Bun ${BUN_VERSION}..."

CURRENT_BUN=""
if command -v bun &>/dev/null; then
  CURRENT_BUN=$(bun --version 2>/dev/null || echo "")
fi

if [ "$CURRENT_BUN" = "$BUN_VERSION" ]; then
  log "Bun already at pinned version ${BUN_VERSION}"
else
  if [ -n "$CURRENT_BUN" ]; then
    warn "Bun ${CURRENT_BUN} installed, upgrading to ${BUN_VERSION}..."
  fi
  retry "curl -fsSL https://bun.sh/install | bash -s 'bun-v${BUN_VERSION}'"
  source ~/.bashrc 2>/dev/null || true
  log "Bun ${BUN_VERSION} installed"
fi

# Ensure bun is on PATH for the rest of this script
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Verify
INSTALLED_BUN=$(bun --version 2>/dev/null || echo "MISSING")
if [ "$INSTALLED_BUN" != "$BUN_VERSION" ]; then
  err "Bun version mismatch: expected ${BUN_VERSION}, got ${INSTALLED_BUN}"
  exit 1
fi

# --- Step 3: Claude Code --------------------------------------------------
step "3/7" "Installing Claude Code ${CLAUDE_CODE_VERSION}..."

# Detect and remove old npm-based installs
CLAUDE_NEEDS_INSTALL=false
if command -v claude &>/dev/null; then
  CLAUDE_PATH=$(command -v claude)
  if [[ "$CLAUDE_PATH" == *"node_modules"* ]] || [[ "$CLAUDE_PATH" == *"npm"* ]] || [[ "$CLAUDE_PATH" == *"lib/node_modules"* ]]; then
    warn "Removing old npm-based Claude Code install: $CLAUDE_PATH"
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    bun remove -g @anthropic-ai/claude-code 2>/dev/null || true
    CLAUDE_NEEDS_INSTALL=true
  else
    CURRENT_CLAUDE=$(claude --version 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "")
    if [ "$CURRENT_CLAUDE" = "$CLAUDE_CODE_VERSION" ]; then
      log "Claude Code already at pinned version ${CLAUDE_CODE_VERSION}"
    else
      warn "Claude Code ${CURRENT_CLAUDE} installed, upgrading to ${CLAUDE_CODE_VERSION}..."
      CLAUDE_NEEDS_INSTALL=true
    fi
  fi
else
  CLAUDE_NEEDS_INSTALL=true
fi

if [ "$CLAUDE_NEEDS_INSTALL" = true ]; then
  retry "curl -fsSL https://claude.ai/install.sh | bash -s -- ${CLAUDE_CODE_VERSION}"
  log "Claude Code ${CLAUDE_CODE_VERSION} installed"
fi

export PATH="$HOME/.claude/bin:$PATH"

# Verify (allow drift — Claude Code may auto-update)
INSTALLED_CLAUDE=$(claude --version 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "MISSING")
if [ "$INSTALLED_CLAUDE" = "$CLAUDE_CODE_VERSION" ]; then
  log "Claude Code version verified: ${INSTALLED_CLAUDE}"
elif [ "$INSTALLED_CLAUDE" != "MISSING" ]; then
  warn "Claude Code drifted: expected ${CLAUDE_CODE_VERSION}, got ${INSTALLED_CLAUDE} (auto-update)"
else
  err "Claude Code not found after install"
  exit 1
fi

echo ""
warn "After setup completes, run 'claude' to authenticate with your API key."
echo ""

# --- Step 3b: Shell environment -------------------------------------------
step "3b" "Configuring shell environment..."

SENTINEL="# --- PAI environment (managed by provision.sh) ---"
ENV_BLOCK='
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
'

for rcfile in ~/.bashrc ~/.zshrc; do
  touch "$rcfile"
  if grep -qF "$SENTINEL" "$rcfile" 2>/dev/null; then
    sed -i "/$SENTINEL/,/# --- end PAI environment ---/d" "$rcfile"
  fi
  echo "$ENV_BLOCK" >> "$rcfile"
done
log "PAI environment block written to .bashrc and .zshrc"

# Configure npm global prefix
mkdir -p "$HOME/.npm-global"
if ! npm config get prefix 2>/dev/null | grep -q '.npm-global'; then
  npm config set prefix "$HOME/.npm-global"
  log "npm global prefix set to ~/.npm-global"
fi

export PATH="$HOME/.claude/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.npm-global/bin:$PATH"

# --- Step 4: PAI ----------------------------------------------------------
step "4/7" "Installing PAI..."

if [ -d "$HOME/.claude/PAI" ] || [ -d "$HOME/.claude/skills/PAI" ]; then
  log "PAI already installed. Skipping."
else
  log "Cloning PAI repo..."
  cd /tmp
  rm -rf PAI
  retry "git clone '${PAI_REPO}'"
  cd PAI

  # Pin to specific commit if configured
  if [ "$PAI_COMMIT" != "HEAD" ]; then
    git checkout "$PAI_COMMIT"
    log "Checked out PAI commit: ${PAI_COMMIT}"
  fi

  LATEST_RELEASE=$(ls Releases/ | sort -V | tail -1)
  log "Using PAI release: $LATEST_RELEASE"
  cp -r "Releases/$LATEST_RELEASE/.claude/" ~/
  cd ~/.claude

  # Fix installer for CLI mode (no GUI in container)
  if [ -f install.sh ]; then
    sed -i 's/--mode gui/--mode cli/' install.sh
    bash install.sh
  fi

  # Fix shell config paths
  if [ -f ~/.zshrc ]; then
    cat ~/.zshrc >> ~/.bashrc
    sed -i 's|skills/PAI/Tools/pai.ts|PAI/Tools/pai.ts|g' ~/.bashrc
  fi

  rm -rf /tmp/PAI

  # Ensure PAI skill symlink exists
  if [ -d "$HOME/.claude/PAI" ] && [ ! -d "$HOME/.claude/skills/PAI" ]; then
    mkdir -p "$HOME/.claude/skills"
    ln -sf "$HOME/.claude/PAI" "$HOME/.claude/skills/PAI"
    log "Symlinked ~/.claude/PAI -> ~/.claude/skills/PAI"
  fi

  log "PAI installed"
fi

source ~/.bashrc 2>/dev/null || true

# --- Step 5: PAI Companion ------------------------------------------------
step "5/7" "Cloning PAI Companion..."

if [ -d "$HOME/pai-companion/companion" ]; then
  log "PAI Companion already cloned"
else
  cd /tmp
  rm -rf pai-companion
  if retry "git clone '${PAI_COMPANION_REPO}'"; then
    # Pin to specific commit if configured
    if [ "$PAI_COMPANION_COMMIT" != "HEAD" ]; then
      cd pai-companion
      git checkout "$PAI_COMPANION_COMMIT"
      cd /tmp
      log "Checked out PAI Companion commit: ${PAI_COMPANION_COMMIT}"
    fi
    rm -rf "$HOME/pai-companion"
    cp -r /tmp/pai-companion "$HOME/pai-companion"
    rm -rf /tmp/pai-companion
    log "PAI Companion cloned to ~/pai-companion"
  else
    warn "Failed to clone pai-companion — you can clone it manually later."
  fi
fi

# --- Step 6: Playwright ---------------------------------------------------
step "6/7" "Installing Playwright ${PLAYWRIGHT_VERSION}..."

if command -v bun &>/dev/null; then
  cd /tmp
  mkdir -p playwright-setup && cd playwright-setup
  bun init -y 2>/dev/null || true
  bun add "playwright@${PLAYWRIGHT_VERSION}" 2>/dev/null || true
  retry "bunx playwright install --with-deps chromium" || warn "Playwright install may need manual completion."
  cd /tmp && rm -rf playwright-setup
  log "Playwright ${PLAYWRIGHT_VERSION} installed"
else
  warn "Bun not found. Skipping Playwright."
fi

# --- Step 7: Audio test ---------------------------------------------------
step "7/7" "Testing audio passthrough..."

if [ -S "/tmp/pipewire-0" ] || [ -S "/run/user/1000/pulse/native" ]; then
  log "Audio socket detected from host"
  if command -v pactl &>/dev/null; then
    if pactl info &>/dev/null 2>&1; then
      log "PulseAudio/PipeWire connection verified"
    else
      warn "Audio socket present but connection failed. May need host audio running."
    fi
  else
    warn "pactl not available — skipping audio connection test"
  fi
else
  warn "No audio socket found. Audio passthrough requires PipeWire/PulseAudio on host."
fi

# --- Sanity check ---------------------------------------------------------
echo ""
echo -e "${BOLD}  Quick sanity check...${NC}"

FAIL=0
for check_cmd in \
  "command -v bun" \
  "command -v claude" \
  "test -d $HOME/.claude/PAI" \
  "grep -qF '# --- PAI environment' ~/.bashrc"; do
  if ! eval "$check_cmd" &>/dev/null; then
    err "Sanity check failed: $check_cmd"
    FAIL=$((FAIL + 1))
  fi
done

if [ $FAIL -gt 0 ]; then
  err "Provisioning completed with $FAIL failures. Check output above."
  exit 1
fi
log "All sanity checks passed"

# --- Done -----------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}============================================${NC}"
echo -e "${BOLD}${GREEN}  Provisioning Complete${NC}"
echo -e "${BOLD}${GREEN}============================================${NC}"
echo ""
log "PAI:          ~/.claude/"
log "Companion:    ~/pai-companion/ (ready for Claude to install)"
log "Log:          $LOG_FILE"
echo ""
warn "Next steps:"
warn "  1. Run 'claude' to authenticate with your Anthropic API key"
warn "  2. Ask Claude to install PAI Companion:"
warn "     \"Install PAI Companion following ~/pai-companion/companion/INSTALL.md."
warn "      Skip Docker (use Bun directly) and skip the voice module.\""
warn "  3. Start using PAI: source ~/.bashrc && pai"
echo ""
