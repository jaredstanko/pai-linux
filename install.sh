#!/bin/bash
# PAI Linux — Deterministic Host Installer for Linux
# Single entry point: installs Incus, creates the container,
# provisions it, and installs CLI commands.
#
# All dependency versions are pinned in versions.env (single source of truth).
# This script is idempotent — safe to re-run if interrupted.
#
# Usage:
#   ./install.sh                        # Normal install (default "pai" instance)
#   ./install.sh --verbose              # Show full output from each step
#   ./install.sh --name=v2              # Parallel install as "pai-v2"
#   ./install.sh --name=v2 --port=8082  # Parallel install with specific portal port
#
# Requirements:
#   - Linux (Ubuntu 22.04+, Debian 12+, or Fedora 38+)
#   - x86_64 or aarch64
#   - Internet connection (for downloads)
#   - sudo access (for Incus install only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration (sets CONTAINER_NAME, WORKSPACE, PORTAL_PORT, etc.)
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/scripts/common.sh" "$@"

STEP=0
TOTAL=8
VERBOSE=false
HOST_USER="$(whoami)"
HOST_UID="$(id -u)"

# Parse additional flags (--name and --port already consumed by common.sh)
for arg in ${_PAI_REMAINING_ARGS[@]+"${_PAI_REMAINING_ARGS[@]}"}; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
    *) ;;
  esac
done

# --- Colors and helpers ---------------------------------------------------

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${CYAN}[${STEP}/${TOTAL}]${NC} ${BOLD}$1${NC}"
}

ok()   { echo -e "        ${GREEN}✓${NC} $1"; }
skip() { echo -e "        ${YELLOW}⊘${NC} $1 (already done)"; }
fail() {
  echo -e "        ${RED}✗${NC} $1"
  if [ -n "${2:-}" ]; then
    echo -e "        ${YELLOW}→${NC} $2"
  fi
  exit 1
}

# Retry helper for network operations
retry() {
  local max_attempts=3
  local delay=5
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    if "$@" >> "$LOG_FILE" 2>&1; then
      return 0
    fi
    if [ $attempt -lt $max_attempts ]; then
      echo -e "        ${YELLOW}⊘${NC} Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# --- Load version manifest ------------------------------------------------

VERSIONS_FILE="$SCRIPT_DIR/versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
  echo -e "${RED}✗${NC} versions.env not found in $SCRIPT_DIR"
  echo -e "${YELLOW}→${NC} This file is required. Re-clone the repo or restore it."
  exit 1
fi
source "$VERSIONS_FILE"

# --- Banner ---------------------------------------------------------------

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Sandbox My AI — PAI Linux Installer${NC}"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo -e "${BOLD}  Instance: ${CYAN}${INSTANCE_NAME}${NC}"
fi
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This will set up a sandboxed AI workspace on your Linux machine."
echo "  Isolation: Incus system container (unprivileged, AppArmor, seccomp)"
echo "  Estimated time: 5-10 minutes (first run)."
echo ""
echo "  Container:   $CONTAINER_NAME"
echo "  Workspace:   $WORKSPACE"
echo "  Portal port: $PORTAL_PORT"
echo ""
echo "  Pinned versions (from versions.env):"
echo "    Bun:         ${BUN_VERSION}"
echo "    Claude Code: ${CLAUDE_CODE_VERSION}"
echo "    Playwright:  ${PLAYWRIGHT_VERSION}"
echo ""
echo "  Log: $LOG_FILE"
echo ""

# Initialize log
echo "=== PAI Linux Install $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "$LOG_FILE"

# --- Step 1: System requirements ------------------------------------------

step "Checking system requirements..."

# Check Linux
if [[ "$(uname -s)" != "Linux" ]]; then
  fail "This script requires Linux." "Run this on a Linux host."
fi
ok "Linux $(uname -r)"

# Check architecture
ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
  fail "Unsupported architecture: $ARCH" "x86_64 or aarch64 required."
fi
ok "Architecture: $ARCH"

# Check systemd
if ! command -v systemctl &>/dev/null; then
  fail "systemd not found." "PAI Linux requires a systemd-based distribution."
fi
ok "systemd present"

# Check that user is not root
if [ "$HOST_UID" -eq 0 ]; then
  fail "Do not run as root." "Run as a normal user. The script will use sudo when needed."
fi
ok "Running as user: $HOST_USER (UID $HOST_UID)"

# --- Step 2: Install Incus ------------------------------------------------

step "Installing Incus..."

if command -v incus &>/dev/null; then
  INCUS_VER=$(incus version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  skip "Incus ($INCUS_VER)"
else
  echo "        Installing Incus from Zabbly stable repository..."

  # Detect distro
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
  else
    DISTRO_ID="unknown"
  fi

  case "$DISTRO_ID" in
    ubuntu|debian)
      # Zabbly repo for Debian/Ubuntu
      sudo mkdir -p /etc/apt/keyrings
      sudo curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc >> "$LOG_FILE" 2>&1

      CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo 'jammy')}"
      sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.sources > /dev/null <<REPO
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${CODENAME}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
REPO
      sudo apt-get update -qq >> "$LOG_FILE" 2>&1
      sudo apt-get install -y -qq incus >> "$LOG_FILE" 2>&1
      ;;
    fedora|rhel|centos)
      sudo dnf copr enable -y neil/incus >> "$LOG_FILE" 2>&1
      sudo dnf install -y incus >> "$LOG_FILE" 2>&1
      ;;
    *)
      fail "Unsupported distro: $DISTRO_ID" "Manually install Incus: https://linuxcontainers.org/incus/docs/main/installing/"
      ;;
  esac

  ok "Incus installed"
fi

# Add user to incus-admin group if not already
if ! groups "$HOST_USER" | grep -qw incus-admin; then
  echo "        Adding $HOST_USER to incus-admin group..."
  sudo usermod -aG incus-admin "$HOST_USER"
  ok "Added to incus-admin group"
  echo ""
  echo -e "        ${YELLOW}NOTE: Group membership requires a new login session.${NC}"
  echo -e "        ${YELLOW}Run: newgrp incus-admin${NC}"
  echo -e "        ${YELLOW}Then re-run: ./install.sh${NC}"

  # Try to proceed with sg (runs command under the new group without a new login)
  if ! incus version &>/dev/null 2>&1; then
    echo "        Attempting to continue with new group membership..."
    RERUN_ARGS=("$@")
    exec sg incus-admin -c "cd $(pwd) && ./install.sh ${RERUN_ARGS[*]}"
  fi
fi

# Initialize Incus if not already done
if ! incus storage list 2>/dev/null | grep -q "default"; then
  echo "        Initializing Incus with defaults..."
  if ! incus admin init --auto >> "$LOG_FILE" 2>&1; then
    # --auto can fail in VMs where common subnets are taken.
    # Fall back to preseed with an explicit subnet.
    echo "        Auto-init failed (likely subnet conflict). Trying manual config..."
    for OCTET in 200 201 202 203 204; do
      CANDIDATE="10.${OCTET}.0.1/24"
      if ! ip route show | grep -q "10.${OCTET}.0."; then
        cat <<PRESEED | incus admin init --preseed >> "$LOG_FILE" 2>&1 && break
config: {}
networks:
- config:
    ipv4.address: "${CANDIDATE}"
    ipv4.nat: "true"
    ipv6.address: none
  description: ""
  name: incusbr0
  type: bridge
storage_pools:
- config: {}
  description: ""
  name: default
  driver: dir
profiles:
- config: {}
  description: Default Incus profile
  devices:
    eth0:
      name: eth0
      network: incusbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
PRESEED
      fi
    done
  fi
  ok "Incus initialized (default storage pool)"
else
  skip "Incus already initialized"
fi

# --- Step 3: Create shared workspace directories -------------------------

step "Creating shared workspace directories..."

for dir in "${PAI_WORKSPACE_DIRS[@]}"; do
  mkdir -p "$WORKSPACE/$dir"
done
ok "$WORKSPACE/ with ${#PAI_WORKSPACE_DIRS[@]} subdirectories"

# --- Step 4: Create Incus profile -----------------------------------------

step "Configuring Incus profile..."

# Generate profile from template with actual user paths and instance workspace
PROFILE_TEMP=$(mktemp)
PROFILE_NAME="$INSTANCE_NAME"
sed \
  -e "s|HOME_PLACEHOLDER|${HOME}|g" \
  -e "s|HOST_UID_PLACEHOLDER|${HOST_UID}|g" \
  -e "s|pai-workspace/|${WORKSPACE##*/}/|g" \
  "$SCRIPT_DIR/profiles/pai.yaml" > "$PROFILE_TEMP"

# Update portal port if non-default
if [ "$PORTAL_PORT" != "8080" ]; then
  sed -i "s|listen: tcp:0.0.0.0:8080|listen: tcp:0.0.0.0:${PORTAL_PORT}|g" "$PROFILE_TEMP"
fi

if incus profile show "$PROFILE_NAME" &>/dev/null 2>&1; then
  echo "        Updating existing '$PROFILE_NAME' profile..."
  incus profile edit "$PROFILE_NAME" < "$PROFILE_TEMP" >> "$LOG_FILE" 2>&1
  skip "Profile '$PROFILE_NAME' updated"
else
  incus profile create "$PROFILE_NAME" >> "$LOG_FILE" 2>&1
  incus profile edit "$PROFILE_NAME" < "$PROFILE_TEMP" >> "$LOG_FILE" 2>&1
  ok "Profile '$PROFILE_NAME' created"
fi

rm -f "$PROFILE_TEMP"

# Add audio devices only if sockets exist on the host
PIPEWIRE_SOCK="/run/user/${HOST_UID}/pipewire-0"
PULSE_DIR="/run/user/${HOST_UID}/pulse"

if [ -e "$PIPEWIRE_SOCK" ]; then
  incus profile device add "$PROFILE_NAME" pipewire disk \
    source="$PIPEWIRE_SOCK" path=/tmp/pipewire-0 >> "$LOG_FILE" 2>&1 || true
  ok "PipeWire audio passthrough enabled"
fi

if [ -d "$PULSE_DIR" ]; then
  incus profile device add "$PROFILE_NAME" pulseaudio disk \
    source="$PULSE_DIR" path=/run/user/1000/pulse >> "$LOG_FILE" 2>&1 || true
  ok "PulseAudio audio passthrough enabled"
fi

if [ ! -e "$PIPEWIRE_SOCK" ] && [ ! -d "$PULSE_DIR" ]; then
  echo -e "        ${YELLOW}⊘${NC} No audio sockets found (headless server — audio passthrough skipped)"
fi

# --- Step 5: Create and start container -----------------------------------

step "Creating sandbox container..."

if incus info "$CONTAINER_NAME" &>/dev/null 2>&1; then
  skip "Container '$CONTAINER_NAME' already exists"
  CONTAINER_STATUS=$(incus info "$CONTAINER_NAME" 2>/dev/null | grep "^Status:" | awk '{print $2}')
  if [ "$CONTAINER_STATUS" != "RUNNING" ]; then
    echo "        Starting container..."
    incus start "$CONTAINER_NAME"
    ok "Container started"
  else
    skip "Container already running"
  fi
else
  echo "        Creating container from ${CONTAINER_IMAGE} (this takes 1-2 minutes)..."
  incus launch "$CONTAINER_IMAGE" "$CONTAINER_NAME" --profile default --profile "$PROFILE_NAME" >> "$LOG_FILE" 2>&1
  ok "Container '$CONTAINER_NAME' created and started"

  # Wait for container to fully boot
  echo "        Waiting for container to boot..."
  for i in $(seq 1 30); do
    if incus exec "$CONTAINER_NAME" -- systemctl is-system-running --wait &>/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  ok "Container booted"
fi

# Ensure 'claude' user exists inside container
if ! incus exec "$CONTAINER_NAME" -- id claude &>/dev/null 2>&1; then
  echo "        Creating 'claude' user in container..."
  incus exec "$CONTAINER_NAME" -- useradd -m -s /bin/bash -u 1000 claude >> "$LOG_FILE" 2>&1
  incus exec "$CONTAINER_NAME" -- usermod -aG sudo claude >> "$LOG_FILE" 2>&1
  # Allow passwordless sudo for provisioning
  incus exec "$CONTAINER_NAME" -- bash -c 'echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude' >> "$LOG_FILE" 2>&1
  ok "User 'claude' created (UID 1000)"
else
  skip "User 'claude' already exists"
fi

# --- Step 6: Provision container ------------------------------------------

step "Provisioning sandbox (installs Claude Code, PAI, tools)..."
echo "        This step takes 3-5 minutes on first run."

# Push versions.env and provision script into container
incus file push "$SCRIPT_DIR/versions.env" "${CONTAINER_NAME}/home/claude/versions.env" >> "$LOG_FILE" 2>&1
incus file push "$SCRIPT_DIR/scripts/provision.sh" "${CONTAINER_NAME}/home/claude/provision.sh" >> "$LOG_FILE" 2>&1

if [ "$VERBOSE" = true ]; then
  incus exec "$CONTAINER_NAME" --user 1000 --group 1000 --cwd /home/claude -- bash /home/claude/provision.sh
else
  incus exec "$CONTAINER_NAME" --user 1000 --group 1000 --cwd /home/claude -- bash /home/claude/provision.sh 2>&1 | tee -a "$LOG_FILE"
fi
ok "Sandbox provisioned"

# --- Step 7: Install CLI commands -----------------------------------------

step "Installing CLI commands..."

BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/pai"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# Install shared library
cp "$SCRIPT_DIR/scripts/common.sh" "$LIB_DIR/common.sh"
chmod +x "$LIB_DIR/common.sh"

for cmd in pai-start pai-stop pai-status pai-talk pai-shell; do
  cp "$SCRIPT_DIR/bin/$cmd" "$BIN_DIR/$cmd"
  chmod +x "$BIN_DIR/$cmd"
done
ok "Commands installed to $BIN_DIR/"

# Ensure ~/.local/bin is on PATH
if ! echo "$PATH" | grep -q "$BIN_DIR"; then
  SHELL_RC=""
  if [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
  elif [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
  fi

  if [ -n "$SHELL_RC" ]; then
    SENTINEL="# --- PAI Linux PATH ---"
    if ! grep -qF "$SENTINEL" "$SHELL_RC" 2>/dev/null; then
      cat >> "$SHELL_RC" <<PATHBLOCK

$SENTINEL
export PATH="\$HOME/.local/bin:\$PATH"
# --- end PAI Linux PATH ---
PATHBLOCK
      ok "Added ~/.local/bin to PATH in $(basename "$SHELL_RC")"
    fi
  fi
fi

echo ""
echo "  Available commands:"
echo "    pai-start   — Start the PAI sandbox container"
echo "    pai-stop    — Stop the PAI sandbox container"
echo "    pai-status  — Show container health and version info"
echo "    pai-talk    — Launch an interactive PAI session (Claude Code)"
echo "    pai-shell   — Open a shell inside the sandbox"

# --- Step 8: Verification ------------------------------------------------

step "Final verification..."

if [ -f "$SCRIPT_DIR/scripts/verify.sh" ]; then
  echo ""
  bash "$SCRIPT_DIR/scripts/verify.sh"
  echo ""
fi

ok "Verification complete"

# --- Done -----------------------------------------------------------------

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Setup complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  Getting started:"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo "    1. Run ${BOLD}pai-talk --name=${_PAI_NAME}${NC} to open a PAI session"
else
  echo "    1. Run ${BOLD}pai-talk${NC} to open a PAI session"
fi
echo "    2. Run 'claude' inside and authenticate with your API key"
echo "    3. Start building with AI"
echo ""
echo "  CLI commands:"
echo -e "    ${BOLD}pai-start${NC}       Start the sandbox container"
echo -e "    ${BOLD}pai-stop${NC}        Stop the sandbox container"
echo -e "    ${BOLD}pai-status${NC}      Show health and versions"
echo -e "    ${BOLD}pai-talk${NC}        Open a PAI session (Claude Code)"
echo -e "    ${BOLD}pai-shell${NC}       Open a plain shell in the sandbox"
echo ""
echo -e "  Install log: $LOG_FILE"
echo -e "  Shared files: $WORKSPACE/"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo ""
  echo "  All commands support --name=${_PAI_NAME} to target this instance:"
  echo "    pai-talk --name=${_PAI_NAME}"
  echo "    pai-status --name=${_PAI_NAME}"
  echo "    ./scripts/upgrade.sh --name=${_PAI_NAME}"
  echo "    ./scripts/uninstall.sh --name=${_PAI_NAME}"
fi
echo ""
