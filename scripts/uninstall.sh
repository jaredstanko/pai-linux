#!/bin/bash
# PAI-Incus — Cleanup
# Removes everything installed by install.sh.
# Asks before removing workspace data.
#
# Usage:
#   ./scripts/uninstall.sh                 # Uninstall default instance
#   ./scripts/uninstall.sh --name=v2       # Uninstall named instance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh" "$@"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
skip() { echo -e "  ${YELLOW}⊘${NC} $1 (not found)"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

echo ""
echo -e "${BOLD}${RED}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PAI-Incus — Cleanup${NC}"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo -e "${BOLD}  Instance: ${RED}${INSTANCE_NAME}${NC}"
fi
echo -e "${BOLD}${RED}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This will remove PAI-Incus components."
echo "  It will NOT uninstall Incus itself."
echo ""
echo "  Target: Container '${CONTAINER_NAME}', workspace '${WORKSPACE}/'"
echo ""

# ─── 1. Stop and remove Incus container ──────────────────────

echo -e "${CYAN}[1/6]${NC} ${BOLD}Incus container${NC}"

if command -v incus &>/dev/null; then
  STATUS=$(pai_container_status)
  if [ -n "$STATUS" ]; then
    if [ "$STATUS" = "RUNNING" ]; then
      echo "  Stopping container..."
      incus stop "$CONTAINER_NAME" --timeout 30 2>/dev/null || true
    fi
    echo "  Deleting container '${CONTAINER_NAME}'..."
    incus delete "$CONTAINER_NAME" --force 2>/dev/null || true
    ok "Container '${CONTAINER_NAME}' deleted"
  else
    skip "Container '${CONTAINER_NAME}'"
  fi
else
  skip "Incus not installed"
fi

# ─── 2. Remove Incus profile ────────────────────────────────

echo -e "${CYAN}[2/6]${NC} ${BOLD}Incus profile${NC}"

PROFILE_NAME="${INSTANCE_NAME}"
if incus profile show "$PROFILE_NAME" &>/dev/null 2>&1; then
  incus profile delete "$PROFILE_NAME" 2>/dev/null || true
  ok "Profile '${PROFILE_NAME}' deleted"
else
  skip "Profile '${PROFILE_NAME}'"
fi

# ─── 3. Remove Incus infrastructure (if no other containers remain) ───

echo -e "${CYAN}[3/6]${NC} ${BOLD}Incus infrastructure${NC}"

if command -v incus &>/dev/null; then
  # Only clean up shared Incus resources if no containers are left
  REMAINING=$(incus list --format csv 2>/dev/null | wc -l || true)
  if [ "$REMAINING" -eq 0 ]; then
    # Remove default profile devices we added
    incus profile device remove default eth0 >> /dev/null 2>&1 || true
    incus profile device remove default root >> /dev/null 2>&1 || true

    # Remove managed network bridge
    if incus network list --format csv 2>/dev/null | grep "^incusbr0," | grep -q ",YES,"; then
      incus network delete incusbr0 2>/dev/null || true
      ok "Network bridge 'incusbr0' deleted"
    else
      skip "Network bridge 'incusbr0'"
    fi

    # Remove storage pool
    if incus storage list --format csv 2>/dev/null | grep -q "^default,"; then
      incus storage delete default 2>/dev/null || true
      ok "Storage pool 'default' deleted"
    else
      skip "Storage pool 'default'"
    fi
  else
    warn "Other containers still exist ($REMAINING) — keeping Incus infrastructure"
  fi
else
  skip "Incus not installed"
fi

# ─── 4. Remove CLI commands ────────────────────────────────

echo -e "${CYAN}[4/6]${NC} ${BOLD}CLI commands${NC}"

BIN_DIR="$HOME/.local/bin"
REMOVED_CMD=false

for cmd in pai-start pai-stop pai-status pai-talk pai-shell pai-status-indicator pai-search-provider; do
  if [ -f "$BIN_DIR/$cmd" ]; then
    rm -f "$BIN_DIR/$cmd"
    ok "Removed $cmd"
    REMOVED_CMD=true
  fi
done

# Remove common.sh lib
LIB_DIR="$HOME/.local/lib/pai"
if [ -d "$LIB_DIR" ]; then
  rm -rf "$LIB_DIR"
  ok "Removed $LIB_DIR/"
fi

if [ "$REMOVED_CMD" = false ]; then
  skip "CLI commands"
fi

# Clean PATH addition from shell rc
for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rcfile" ] && grep -qF "# --- PAI Linux PATH ---" "$rcfile" 2>/dev/null; then
    sed -i '/# --- PAI Linux PATH ---/,/# --- end PAI Linux PATH ---/d' "$rcfile"
    ok "Removed PATH block from $(basename "$rcfile")"
  fi
done

# Remove desktop integration (indicator, autostart, search provider)
pkill -f pai-status-indicator 2>/dev/null || true
rm -f "$HOME/.config/autostart/pai-status.desktop" 2>/dev/null
rm -f "$HOME/.local/share/applications/pai-status.desktop" 2>/dev/null
sudo rm -f /usr/share/gnome-shell/search-providers/pai-search-provider.ini 2>/dev/null || true
sudo rm -f /usr/share/dbus-1/services/org.pai.SearchProvider.service 2>/dev/null || true
if [ -f "$HOME/.config/autostart/pai-status.desktop" ] || [ -f "$HOME/.local/share/applications/pai-status.desktop" ]; then
  ok "Removed desktop integration"
else
  ok "Desktop integration cleaned up"
fi

# ─── 4. Workspace data (ASKS FIRST) ──────────────────────────

# ─── 5. Clean up subuid/subgid entries ────────────────────────

echo -e "${CYAN}[5/6]${NC} ${BOLD}Subordinate UID/GID entries${NC}"

if command -v incus &>/dev/null; then
  REMAINING=$(incus list --format csv 2>/dev/null | wc -l || true)
  if [ "$REMAINING" -eq 0 ]; then
    # Remove the root subuid/subgid entries we added
    if grep -q "^root:.*:1000000000$" /etc/subuid 2>/dev/null; then
      sudo sed -i '/^root:.*:1000000000$/d' /etc/subuid 2>/dev/null || true
      sudo sed -i '/^root:.*:1000000000$/d' /etc/subgid 2>/dev/null || true
      ok "Removed root subordinate UID/GID ranges"
    else
      skip "Root subordinate UID ranges"
    fi
    HOST_UID="$(id -u)"
    if grep -q "^root:${HOST_UID}:1$" /etc/subuid 2>/dev/null; then
      sudo sed -i "/^root:${HOST_UID}:1$/d" /etc/subuid 2>/dev/null || true
      sudo sed -i "/^root:${HOST_UID}:1$/d" /etc/subgid 2>/dev/null || true
      ok "Removed host UID mapping from subuid/subgid"
    else
      skip "Host UID mapping"
    fi
  else
    warn "Other containers still exist — keeping subuid/subgid entries"
  fi
else
  skip "Incus not installed"
fi

# ─── 6. Workspace data (ASKS FIRST) ──────────────────────────

echo -e "${CYAN}[6/6]${NC} ${BOLD}Workspace data${NC}"

if [ -d "$WORKSPACE" ]; then
  echo ""
  echo -e "  ${RED}${BOLD}WARNING: ${WORKSPACE}/ contains your data!${NC}"
  echo ""
  echo "  This includes:"
  echo "    - claude-home/ — PAI config, settings, memory"
  echo "    - work/        — Projects and work-in-progress"
  echo "    - data/        — Persistent data"
  echo "    - exchange/    — File exchange"
  echo "    - portal/      — Web portal content"
  echo "    - upstream/    — Reference repos"
  echo ""

  # Show sizes
  echo "  Directory sizes:"
  du -sh "$WORKSPACE/"* 2>/dev/null | while read -r size dir; do
    echo "    $size  $(basename "$dir")"
  done
  echo ""

  echo -ne "  ${RED}Delete ${WORKSPACE}/ and ALL its contents? [y/N]:${NC} "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    rm -rf "$WORKSPACE"
    ok "Removed ${WORKSPACE}/"
  else
    warn "Kept ${WORKSPACE}/ — you can remove it manually later"
  fi
else
  skip "${WORKSPACE}/"
fi

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Cleanup complete${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  What was removed:"
echo "    - Incus container '${CONTAINER_NAME}'"
echo "    - Incus profile '${INSTANCE_NAME}'"
echo "    - Incus storage pool and network bridge (if no other containers)"
echo "    - Subordinate UID/GID entries (if no other containers)"
echo "    - CLI commands (pai-start, pai-stop, pai-status, pai-talk, pai-shell)"
echo "    - PATH block from .bashrc/.zshrc"
echo ""
echo "  What was NOT removed:"
echo "    - Incus package itself (uninstall with your package manager)"
echo "    - PipeWire (system audio service, may be used by other apps)"
echo "    - This repo (pai-incus/)"
if [ -d "$WORKSPACE" ]; then
  echo "    - ${WORKSPACE}/ (you chose to keep it)"
fi
echo ""
echo "  To do a fresh install: ./install.sh${INSTANCE_SUFFIX:+ --name=${_PAI_NAME}}"
echo ""
