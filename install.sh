#!/bin/bash
# PAI-Incus — Host Installer for Linux
# Single entry point: installs Incus, creates the container,
# provisions it, and installs CLI commands.
#
# Tools are installed at their latest versions. The container image is pinned
# in this script. This script is idempotent — safe to re-run if interrupted.
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

# Override LOG_FILE to write to the repo directory with a timestamp (matches pai-lima)
LOG_FILE="$SCRIPT_DIR/pai-install-$(date +%Y%m%dT%H%M%S).log"

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

# --- Configuration --------------------------------------------------------
# Container image is pinned here. Tools install at latest versions.
CONTAINER_IMAGE="images:ubuntu/24.04"

# --- Banner ---------------------------------------------------------------

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Sandbox My AI — PAI-Incus Installer${NC}"
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
echo "  Log: $LOG_FILE"
echo ""

# Initialize log
echo "=== PAI-Incus Install $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "$LOG_FILE"

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
  fail "systemd not found." "PAI-Incus requires a systemd-based distribution."
fi
ok "systemd present"

# Check that user is not root
if [ "$HOST_UID" -eq 0 ]; then
  fail "Do not run as root." "Run as a normal user. The script will use sudo when needed."
fi
ok "Running as user: $HOST_USER (UID $HOST_UID)"

# Install git and curl if missing (Fedora minimal and some server installs lack these)
MISSING_PKGS=""
command -v git &>/dev/null || MISSING_PKGS="git"
command -v curl &>/dev/null || MISSING_PKGS="$MISSING_PKGS curl"
command -v unzip &>/dev/null || MISSING_PKGS="$MISSING_PKGS unzip"
command -v fc-cache &>/dev/null || MISSING_PKGS="$MISSING_PKGS fontconfig"
if [ -n "$MISSING_PKGS" ]; then
  echo "        Installing missing prerequisites:$MISSING_PKGS"
  if command -v dnf &>/dev/null; then
    sudo dnf install -y $MISSING_PKGS >> "$LOG_FILE" 2>&1
  elif command -v apt-get &>/dev/null; then
    sudo apt-get update -qq >> "$LOG_FILE" 2>&1
    sudo apt-get install -y -qq $MISSING_PKGS >> "$LOG_FILE" 2>&1
  fi
  ok "Prerequisites installed"
fi

# Install Hack Nerd Font (needed for PAI prompt glyphs, powerline symbols, devicons)
FONT_DIR="$HOME/.local/share/fonts/HackNerdFont"
if [ -d "$FONT_DIR" ] && ls "$FONT_DIR"/*.ttf &>/dev/null 2>&1; then
  skip "Hack Nerd Font"
else
  echo "        Installing Hack Nerd Font..."
  FONT_TMP=$(mktemp -d)
  FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip"
  if curl -fsSL "$FONT_URL" -o "$FONT_TMP/Hack.zip" >> "$LOG_FILE" 2>&1; then
    mkdir -p "$FONT_DIR"
    unzip -qo "$FONT_TMP/Hack.zip" -d "$FONT_DIR" >> "$LOG_FILE" 2>&1 || true
    # Update font cache
    fc-cache -f "$FONT_DIR" >> "$LOG_FILE" 2>&1 || true
    ok "Hack Nerd Font installed"
  else
    echo -e "        ${YELLOW}⊘${NC} Could not download Hack Nerd Font (non-blocking)"
  fi
  rm -rf "$FONT_TMP"
fi

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
    fedora)
      # Incus is in the official Fedora repos
      sudo dnf install -y incus incus-client >> "$LOG_FILE" 2>&1
      sudo systemctl enable --now incus >> "$LOG_FILE" 2>&1
      ;;
    rhel|centos)
      sudo dnf copr enable -y neil/incus >> "$LOG_FILE" 2>&1
      sudo dnf install -y incus >> "$LOG_FILE" 2>&1
      ;;
    *)
      fail "Unsupported distro: $DISTRO_ID" "Manually install Incus: https://linuxcontainers.org/incus/docs/main/installing/"
      ;;
  esac

  ok "Incus installed"
fi

# Add user to incus-admin group if not already a member
if ! getent group incus-admin | grep -qw "$HOST_USER"; then
  echo "        Adding $HOST_USER to incus-admin group..."
  sudo usermod -aG incus-admin "$HOST_USER"
  ok "Added to incus-admin group"
fi

# Check if current shell actually has the group (may need sg even if user is a member)
if ! incus version &>/dev/null 2>&1; then
  echo "        Acquiring incus-admin group for this session..."
  RERUN_ARGS=("$@")
  INSTALL_CMD="cd $(pwd) && ./install.sh ${RERUN_ARGS[*]}"
  # Try sg (works in most interactive and SSH contexts)
  sg incus-admin -c "$INSTALL_CMD" && exit 0
  # sg may fail silently in some contexts — check if it actually ran
  sg incus-admin -c "$INSTALL_CMD" 2>/dev/null && exit 0
  echo ""
  echo -e "        ${YELLOW}Group membership requires a new login session.${NC}"
  echo -e "        ${YELLOW}Run one of these, then re-run ./install.sh:${NC}"
  echo ""
  echo -e "        ${BOLD}newgrp incus-admin${NC}    (stays in current terminal)"
  echo -e "        ${BOLD}Log out and back in${NC}   (applies to all terminals)"
  echo ""
  exit 1
fi

# Ensure root has subordinate UID/GID ranges for unprivileged containers.
# Ubuntu sets this up automatically; Fedora and others may not.
SUBUID_CHANGED=false

# Root needs a large range for container user namespaces.
# Check if root has at least 65536 subordinate UIDs (minimum for unprivileged containers).
ROOT_HAS_RANGE=false
while IFS=: read -r user start count; do
  if [ "$user" = "root" ] && [ "$count" -ge 65536 ] 2>/dev/null; then
    ROOT_HAS_RANGE=true
    break
  fi
done < /etc/subuid 2>/dev/null

if [ "$ROOT_HAS_RANGE" = false ]; then
  echo "        Adding subordinate UID/GID ranges for root..."
  sudo sh -c 'echo "root:1000000:1000000000" >> /etc/subuid'
  sudo sh -c 'echo "root:1000000:1000000000" >> /etc/subgid'
  SUBUID_CHANGED=true
fi

# Host UID must also be in root's range (for raw.idmap passthrough)
HAS_HOST_UID=false
while IFS=: read -r user start count; do
  if [ "$user" = "root" ] && [ "$HOST_UID" -ge "$start" ] && [ "$HOST_UID" -lt $((start + count)) ]; then
    HAS_HOST_UID=true
    break
  fi
done < /etc/subuid 2>/dev/null

if [ "$HAS_HOST_UID" = false ]; then
  sudo sh -c "echo 'root:${HOST_UID}:1' >> /etc/subuid"
  sudo sh -c "echo 'root:${HOST_UID}:1' >> /etc/subgid"
  SUBUID_CHANGED=true
fi

if [ "$SUBUID_CHANGED" = true ]; then
  sudo systemctl restart incus >> "$LOG_FILE" 2>&1 || true
  ok "Configured subordinate UID/GID ranges"
fi

# Initialize Incus — ensure storage pool, managed network, and default profile are set up
HAS_STORAGE=$(incus storage list --format csv 2>/dev/null | grep -c "^default," || true)
HAS_NETWORK=$(incus network list --format csv 2>/dev/null | grep "^incusbr0," | grep -c ",YES," || true)
HAS_PROFILE_ETH0=$(incus profile show default 2>/dev/null | grep -c "network: incusbr0" || true)

if [ "$HAS_STORAGE" -gt 0 ] && [ "$HAS_NETWORK" -gt 0 ] && [ "$HAS_PROFILE_ETH0" -gt 0 ]; then
  skip "Incus already initialized"
else
  echo "        Initializing Incus..."

  # Try auto-init first (works on most systems)
  if incus admin init --auto >> "$LOG_FILE" 2>&1; then
    ok "Incus initialized"
  else
    # --auto can fail when common subnets are taken (VMs).
    # It may have partially succeeded (e.g. created storage but failed on network).
    # Re-check state and create only what's still missing.

    # Storage pool — create if missing (--auto may have created one as btrfs/zfs)
    if ! incus storage list --format csv 2>/dev/null | grep -q "^default,"; then
      echo "        Creating default storage pool..."
      incus storage create default dir >> "$LOG_FILE" 2>&1
    fi

    # Managed network bridge — create if missing, find a free subnet
    # (An unmanaged bridge or stale dnsmasq may exist from a previous install)
    if ! incus network list --format csv 2>/dev/null | grep "^incusbr0," | grep -q ",YES,"; then
      # Clean up stale bridge interface and dnsmasq from previous installs
      if ip link show incusbr0 &>/dev/null 2>&1; then
        sudo ip link delete incusbr0 >> "$LOG_FILE" 2>&1 || true
      fi
      # Kill stale dnsmasq that may hold the address
      sudo pkill -f "dnsmasq.*incusbr0" >> "$LOG_FILE" 2>&1 || true
      echo "        Creating network bridge..."
      for OCTET in 200 201 202 203 204; do
        CANDIDATE="10.${OCTET}.0.1/24"
        if ! ip route show | grep -q "10.${OCTET}.0."; then
          incus network create incusbr0 \
            ipv4.address="${CANDIDATE}" ipv4.nat=true ipv6.address=none \
            >> "$LOG_FILE" 2>&1 && break
        fi
      done
    fi

    # Ensure default profile has the network and storage
    if ! incus profile show default 2>/dev/null | grep -q "network: incusbr0"; then
      incus profile device add default eth0 nic network=incusbr0 >> "$LOG_FILE" 2>&1 || true
    fi
    incus profile device add default root disk path=/ pool=default >> "$LOG_FILE" 2>&1 || true

    ok "Incus initialized (manual config)"
  fi
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
  # Try to install and start PipeWire (Fedora and modern Ubuntu/Debian)
  echo "        No audio sockets found. Installing PipeWire..."
  if command -v dnf &>/dev/null; then
    sudo dnf install -y pipewire pipewire-pulseaudio pipewire-utils >> "$LOG_FILE" 2>&1 || true
  elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y -qq pipewire pipewire-pulse >> "$LOG_FILE" 2>&1 || true
  fi
  # Start PipeWire for the current user
  systemctl --user enable --now pipewire pipewire-pulse >> "$LOG_FILE" 2>&1 || true
  # Give sockets a moment to appear
  sleep 2
  # Re-check and add devices if sockets appeared
  if [ -e "$PIPEWIRE_SOCK" ]; then
    incus profile device add "$PROFILE_NAME" pipewire disk \
      source="$PIPEWIRE_SOCK" path=/tmp/pipewire-0 >> "$LOG_FILE" 2>&1 || true
    ok "PipeWire installed and audio passthrough enabled"
  elif [ -d "$PULSE_DIR" ]; then
    incus profile device add "$PROFILE_NAME" pulseaudio disk \
      source="$PULSE_DIR" path=/run/user/1000/pulse >> "$LOG_FILE" 2>&1 || true
    ok "PulseAudio audio passthrough enabled"
  else
    echo -e "        ${YELLOW}⊘${NC} Audio sockets not available (headless server — audio passthrough skipped)"
  fi
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
  # Remove default 'ubuntu' user if it holds UID 1000
  if incus exec "$CONTAINER_NAME" -- id -u ubuntu 2>/dev/null | grep -q '^1000$'; then
    incus exec "$CONTAINER_NAME" -- userdel -r ubuntu >> "$LOG_FILE" 2>&1 || true
  fi
  incus exec "$CONTAINER_NAME" -- useradd -m -s /bin/bash -u 1000 claude >> "$LOG_FILE" 2>&1 || true
  incus exec "$CONTAINER_NAME" -- usermod -aG sudo claude >> "$LOG_FILE" 2>&1
  # Ensure home directory ownership (may be wrong if pre-existing from image)
  incus exec "$CONTAINER_NAME" -- chown claude:claude /home/claude >> "$LOG_FILE" 2>&1
  # Copy skel files if missing (useradd skips this when home already exists)
  incus exec "$CONTAINER_NAME" -- bash -c 'for f in /etc/skel/.profile /etc/skel/.bashrc; do
    target="/home/claude/$(basename "$f")"
    [ ! -f "$target" ] && cp "$f" "$target" && chown claude:claude "$target"
  done' >> "$LOG_FILE" 2>&1
  # Allow passwordless sudo for provisioning
  incus exec "$CONTAINER_NAME" -- bash -c 'echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude' >> "$LOG_FILE" 2>&1
  ok "User 'claude' created (UID 1000)"
else
  skip "User 'claude' already exists"
fi

# --- Step 6: Provision container ------------------------------------------

step "Provisioning sandbox (installs Claude Code, PAI, tools)..."
echo "        This step takes 3-5 minutes on first run."

# Push provision script into container
incus file push "$SCRIPT_DIR/scripts/provision.sh" "${CONTAINER_NAME}/home/claude/provision.sh" >> "$LOG_FILE" 2>&1

if [ "$VERBOSE" = true ]; then
  incus exec "$CONTAINER_NAME" --user 1000 --group 1000 --cwd /home/claude --env HOME=/home/claude -- bash /home/claude/provision.sh
else
  incus exec "$CONTAINER_NAME" --user 1000 --group 1000 --cwd /home/claude --env HOME=/home/claude -- bash /home/claude/provision.sh 2>&1 | tee -a "$LOG_FILE"
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

# --- Step 9: Desktop integration (optional) --------------------------------

# Only offer desktop integration on the default instance and when running interactively
if [ -z "$INSTANCE_SUFFIX" ] && [ -t 0 ]; then
  echo ""
  echo -e "${BOLD}  Desktop integration${NC}"
  echo ""
  echo "  The following terminal commands are ready to use:"
  echo ""
  echo "    pai-talk      — Talk to your AI"
  echo "    pai-talk -r   — Resume a previous conversation"
  echo "    pai-start     — Start the sandbox"
  echo "    pai-stop      — Stop the sandbox"
  echo "    pai-status    — Check sandbox health"
  echo "    pai-shell     — Open a terminal inside the sandbox"
  echo ""

  # --- GNOME Search Provider ---
  INSTALL_SEARCH=false
  IS_GNOME=false
  if [ "$XDG_CURRENT_DESKTOP" = "GNOME" ] || pgrep -x gnome-shell &>/dev/null 2>&1; then
    IS_GNOME=true
  fi

  if [ "$IS_GNOME" = true ]; then
    echo -e "  ${BOLD}GNOME detected.${NC} You can type \"pai\" in Activities to see PAI actions."
    echo -ne "  Install GNOME search provider? [Y/n]: "
    read -r SEARCH_CHOICE
    if [[ ! "$SEARCH_CHOICE" =~ ^[Nn]$ ]]; then
      INSTALL_SEARCH=true
    fi
    echo ""
  fi

  # --- System Tray Icon ---
  echo "  You can also add a system tray icon for quick access to PAI."
  echo "  It shows sandbox status and lets you start sessions, open the"
  echo "  web portal, and more — without opening a terminal."
  echo ""
  echo -ne "  Install system tray icon? [Y/n]: "
  read -r TRAY_CHOICE
  INSTALL_TRAY=false
  if [[ ! "$TRAY_CHOICE" =~ ^[Nn]$ ]]; then
    INSTALL_TRAY=true
  fi

  # --- Install what was requested ---
  if [ "$INSTALL_TRAY" = true ] || [ "$INSTALL_SEARCH" = true ]; then
    echo ""

    # Install Python GTK and AppIndicator dependencies
    if [ "$INSTALL_TRAY" = true ]; then
      echo "        Installing tray icon dependencies..."
      if command -v dnf &>/dev/null; then
        sudo dnf install -y python3-gobject gtk3 libappindicator-gtk3 >> "$LOG_FILE" 2>&1 || true
        if [ "$IS_GNOME" = true ]; then
          sudo dnf install -y gnome-shell-extension-appindicator >> "$LOG_FILE" 2>&1 || true
          gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com >> "$LOG_FILE" 2>&1 || true
        fi
      elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y -qq python3-gi gir1.2-appindicator3-0.1 >> "$LOG_FILE" 2>&1 || true
        if [ "$IS_GNOME" = true ]; then
          sudo apt-get install -y -qq gnome-shell-extension-appindicator >> "$LOG_FILE" 2>&1 || true
          gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com >> "$LOG_FILE" 2>&1 || true
        fi
      fi

      # Install the indicator script
      cp "$SCRIPT_DIR/indicator/pai-status-indicator" "$BIN_DIR/pai-status-indicator"
      chmod +x "$BIN_DIR/pai-status-indicator"

      # Install autostart entry
      mkdir -p "$HOME/.config/autostart"
      cp "$SCRIPT_DIR/indicator/pai-status.desktop" "$HOME/.config/autostart/pai-status.desktop"

      # Install .desktop file for application menu
      mkdir -p "$HOME/.local/share/applications"
      cp "$SCRIPT_DIR/indicator/pai-status.desktop" "$HOME/.local/share/applications/pai-status.desktop"

      # Start the indicator now
      nohup pai-status-indicator &>/dev/null &

      ok "System tray icon installed (starts automatically on login)"
    fi

    if [ "$INSTALL_SEARCH" = true ]; then
      # Install the search provider script
      cp "$SCRIPT_DIR/indicator/pai-search-provider" "$BIN_DIR/pai-search-provider"
      chmod +x "$BIN_DIR/pai-search-provider"

      sudo mkdir -p /usr/share/gnome-shell/search-providers
      sudo cp "$SCRIPT_DIR/indicator/pai-search-provider.ini" /usr/share/gnome-shell/search-providers/
      sudo mkdir -p /usr/share/dbus-1/services
      sudo cp "$SCRIPT_DIR/indicator/org.pai.SearchProvider.service" /usr/share/dbus-1/services/

      ok "GNOME search provider installed (type 'pai' in Activities)"
    fi
  else
    echo ""
    echo "        No desktop integration installed."
    echo "        You can always use the terminal commands listed above."
  fi
fi

# --- Done -----------------------------------------------------------------

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Setup complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}  Step 1: Open a PAI session${NC}"
echo ""
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo -e "    Run ${BOLD}pai-talk --name=${_PAI_NAME}${NC}"
else
  echo -e "    Run ${BOLD}pai-talk${NC}"
fi
echo ""
echo -e "${BOLD}  Step 2: Sign in to Claude Code${NC}"
echo ""
echo "    Claude Code will ask you to sign in. It opens a browser —"
echo "    log in with your Anthropic account (https://console.anthropic.com/)."
echo "    A free account works. When it asks \"Do you trust /home/claude/.claude?\""
echo "    say yes."
echo ""
echo -e "${BOLD}  Step 3: Set up the web portal${NC}"
echo ""
echo "    Once signed in, paste this into your PAI session:"
echo ""
echo "      Install PAI Companion following ~/pai-companion/companion/INSTALL.md."
echo "      Skip Docker (use Bun directly for the portal) and skip the voice"
echo "      module. Keep ~/.vm-ip set to localhost and VM_IP=localhost in .env."
echo "      After installation, verify the portal is running at localhost:${PORTAL_PORT}"
echo "      and verify the voice server can successfully generate and play audio"
echo "      end-to-end (not just that the process is listening). Fix any"
echo "      macOS-specific binaries (like afplay) that won't work on Linux."
echo "      Set both to start on boot."
echo ""
echo "    Claude Code will ask you some questions. Each time press 2 (Yes)"
echo "    to allow it to edit settings for this session."
echo ""
echo "    Wait for it to finish. Then open http://localhost:${PORTAL_PORT} in"
echo "    your browser to see the web portal."
echo ""
echo -e "${BOLD}  CLI commands:${NC}"
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
echo -e "${CYAN}  Tip:${NC} PAI uses special icons and symbols that require ${BOLD}Hack Nerd Font${NC}."
echo "  The font was installed automatically. To see the icons correctly,"
echo "  set your terminal's font to \"Hack Nerd Font\" or \"Hack Nerd Font Mono\"."
echo ""
echo "  How to change your terminal font:"
echo "    GNOME Terminal — Preferences → Profiles → Text → Custom font"
echo "    Konsole        — Settings → Edit Current Profile → Appearance → Font"
echo "    XFCE Terminal  — Edit → Preferences → Appearance → Font"
echo "    Kitty          — Edit ~/.config/kitty/kitty.conf → font_family Hack Nerd Font"
echo "    Alacritty      — Edit ~/.config/alacritty/alacritty.toml → [font.normal] family"
echo ""
