#!/bin/bash
# PAI Linux — End-State Verification
# Checks that the full system is installed and functional.
# Uses 2-state model: PASS (present and working), FAIL (missing or broken).
#
# Can be run standalone or called by install.sh at the end of install.
#
# Usage:
#   ./scripts/verify.sh
#   ./scripts/verify.sh --name=v2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh" "$@" 2>/dev/null || true

# --- Colors ---------------------------------------------------------------

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

# --- Helpers --------------------------------------------------------------

passed() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${GREEN}%-8s${NC} %-40s %s\n" "PASS" "$label" "$detail"
  else
    printf "  ${GREEN}%-8s${NC} %s\n" "PASS" "$label"
  fi
  PASS=$((PASS + 1))
}

failed() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${RED}%-8s${NC} %-40s %s\n" "FAIL" "$label" "$detail"
  else
    printf "  ${RED}%-8s${NC} %s\n" "FAIL" "$label"
  fi
  FAIL=$((FAIL + 1))
}

check_exists() {
  local label="$1"
  local path="$2"

  if [ -e "$path" ]; then
    passed "$label"
  else
    failed "$label" "(not found: $path)"
  fi
}

check_command() {
  local label="$1"
  local cmd="$2"

  if command -v "$cmd" &>/dev/null; then
    passed "$label"
  else
    failed "$label" "($cmd not in PATH)"
  fi
}

check_installed() {
  local label="$1"
  local actual="$2"

  if [ -n "$actual" ] && [ "$actual" != "MISSING" ]; then
    passed "$label" "($actual)"
  else
    failed "$label"
  fi
}

# --- Banner ---------------------------------------------------------------

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PAI Linux — System Verification${NC}"
if [ -n "${INSTANCE_SUFFIX:-}" ]; then
  echo -e "${BOLD}  Instance: ${CYAN}${INSTANCE_NAME}${NC}"
fi
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""

# =========================================================================
# HOST CHECKS (run on Linux host)
# =========================================================================

echo -e "${BOLD}  Host (Linux)${NC}"
echo -e "  ──────────────────────────────────────────────"

# Linux
if [[ "$(uname -s)" = "Linux" ]]; then
  passed "Linux" "($(uname -r))"
else
  failed "Linux" "(not Linux)"
fi

# Architecture
ARCH="$(uname -m)"
if [[ "$ARCH" = "x86_64" || "$ARCH" = "aarch64" ]]; then
  passed "Architecture" "($ARCH)"
else
  failed "Architecture" "($ARCH)"
fi

# systemd
check_command "systemd" "systemctl"

# Incus
if command -v incus &>/dev/null; then
  INCUS_VER=$(incus version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  passed "Incus" "($INCUS_VER)"
else
  failed "Incus" "(incus not found)"
fi

# CLI commands (check both PATH and install location)
for cmd in pai-start pai-stop pai-status pai-talk pai-shell; do
  if command -v "$cmd" &>/dev/null || [ -x "$HOME/.local/bin/$cmd" ]; then
    passed "$cmd"
  else
    failed "$cmd" "($cmd not found)"
  fi
done

# Workspace directories
WORKSPACE="${WORKSPACE:-$HOME/pai-workspace}"
WORKSPACE_OK=true
for dir in claude-home data exchange portal work upstream; do
  if [ ! -d "$WORKSPACE/$dir" ]; then
    WORKSPACE_OK=false
    failed "Workspace: $dir" "(not found: $WORKSPACE/$dir)"
  fi
done
if [ "$WORKSPACE_OK" = true ]; then
  passed "Workspace directories (6/6)"
fi

# =========================================================================
# CONTAINER CHECKS (run inside Incus container)
# =========================================================================

echo ""
echo -e "${BOLD}  Container (Incus)${NC}"
echo -e "  ──────────────────────────────────────────────"

CONTAINER="${CONTAINER_NAME:-pai}"

# Check container exists
if ! incus info "$CONTAINER" &>/dev/null 2>&1; then
  failed "Incus container '$CONTAINER'" "(does not exist)"
  echo ""
  echo -e "  ${RED}Cannot check container internals — container does not exist.${NC}"
else
  CONTAINER_STATUS=$(incus info "$CONTAINER" 2>/dev/null | grep "^Status:" | awk '{print $2}')
  if [ "$CONTAINER_STATUS" = "RUNNING" ]; then
    passed "Container '$CONTAINER'" "(running)"
  else
    failed "Container '$CONTAINER'" "(status: $CONTAINER_STATUS, expected: RUNNING)"
  fi

  # Security checks
  PRIVILEGED=$(incus config get "$CONTAINER" security.privileged 2>/dev/null || echo "unknown")
  if [ "$PRIVILEGED" = "false" ] || [ "$PRIVILEGED" = "" ]; then
    passed "Unprivileged container"
  else
    failed "Unprivileged container" "(security.privileged=$PRIVILEGED)"
  fi

  if [ "$CONTAINER_STATUS" = "RUNNING" ]; then
    # Batch all container checks into a single exec for speed
    VM_CHECK_SCRIPT='
      echo "BUN_VER=$(command -v bun >/dev/null 2>&1 && bun --version 2>/dev/null || echo MISSING)"
      echo "CLAUDE_VER=$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | grep -oE "[0-9.]+" | head -1 || echo MISSING)"
      echo "NODE_VER=$(command -v node >/dev/null 2>&1 && node --version 2>/dev/null || echo MISSING)"
      echo "PAI_DIR=$(test -d /home/claude/.claude/PAI && echo YES || echo NO)"
      echo "PAI_LINK=$(test -L /home/claude/.claude/skills/PAI && echo YES || echo NO)"
      echo "BASHRC_ENV=$(grep -cF "# --- PAI environment" /home/claude/.bashrc 2>/dev/null || echo 0)"
      echo "ZSHRC_ENV=$(grep -cF "# --- PAI environment" /home/claude/.zshrc 2>/dev/null || echo 0)"
      echo "COMPANION=$(test -d /home/claude/pai-companion/companion && echo YES || echo NO)"
      echo "PW_VER=$(command -v bunx >/dev/null 2>&1 && bunx playwright --version 2>/dev/null || echo MISSING)"
      echo "VMIP=$(test -s /home/claude/.vm-ip && echo YES || echo NO)"
      for m in .claude data exchange portal work upstream; do
        test -d "/home/claude/$m" && echo "MOUNT_${m}=YES" || echo "MOUNT_${m}=NO"
      done
    '
    VM_RESULTS=$(incus exec "$CONTAINER" --user 1000 --group 1000 --env HOME=/home/claude -- bash -lc "$VM_CHECK_SCRIPT" 2>/dev/null || echo "")

    # Parse results
    get_val() { echo "$VM_RESULTS" | grep "^$1=" | cut -d= -f2- | tr -d '[:space:]'; }

    check_installed "Bun" "$(get_val BUN_VER)"
    check_installed "Claude Code" "$(get_val CLAUDE_VER)"
    check_installed "Node.js" "$(get_val NODE_VER)"

    [ "$(get_val PAI_DIR)" = "YES" ] && passed "PAI directory" || failed "PAI directory"
    [ "$(get_val PAI_LINK)" = "YES" ] && passed "PAI skill symlink" || failed "PAI skill symlink"

    # Mount accessibility
    MOUNTS_OK=true
    for mount in .claude data exchange portal work upstream; do
      MOUNT_KEY="MOUNT_${mount}"
      if [ "$(get_val "$MOUNT_KEY")" != "YES" ]; then
        MOUNTS_OK=false
        failed "Container mount: $mount"
      fi
    done
    if [ "$MOUNTS_OK" = true ]; then
      passed "Container mounts accessible (6/6)"
    fi

    [ "$(get_val BASHRC_ENV)" != "0" ] && passed ".bashrc PAI environment block" || failed ".bashrc PAI environment block"
    [ "$(get_val ZSHRC_ENV)" != "0" ] && passed ".zshrc PAI environment block" || failed ".zshrc PAI environment block"
    [ "$(get_val COMPANION)" = "YES" ] && passed "PAI Companion repo" || failed "PAI Companion repo"

    check_installed "Playwright" "$(get_val PW_VER)"

    [ "$(get_val VMIP)" = "YES" ] && passed "VM IP file" || failed "VM IP file"
  fi
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
echo -e "  ──────────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
echo -e "  ${GREEN}${PASS} PASS${NC}  ${RED}${FAIL} FAIL${NC}  (${TOTAL} checks)"
echo ""

if [ $FAIL -gt 0 ]; then
  echo -e "  ${RED}Some checks failed.${NC} Review output above for details."
  echo -e "  Re-run ${BOLD}./install.sh${NC} to fix, or check ${BOLD}~/.pai-install.log${NC}"
  exit 1
else
  echo -e "  ${GREEN}All checks passed.${NC}"
  exit 0
fi
