#!/bin/bash
# PAI-Incus — Shared instance configuration
# Source this file at the top of every script to get instance-aware variables.
#
# Parses --name=X from arguments and sets:
#   INSTANCE_NAME   "pai" (default) or "pai-X"
#   INSTANCE_SUFFIX "" (default) or "-X"
#   CONTAINER_NAME  Same as INSTANCE_NAME (Incus container name)
#   WORKSPACE       ~/pai-workspace (default) or ~/pai-workspace-X
#   PORTAL_PORT     8080 (default) or specified port
#   LOG_FILE        ~/.pai-install.log (default) or ~/.pai-install-X.log
#                   (install.sh overrides this to write to the repo directory)
#
# Usage in scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/common.sh" "$@"

# Parse --name and --port from all arguments
_PAI_NAME=""
_PAI_PORT=""
_PAI_REMAINING_ARGS=()

for _arg in "$@"; do
  case "$_arg" in
    --name=*) _PAI_NAME="${_arg#--name=}" ;;
    --port=*) _PAI_PORT="${_arg#--port=}" ;;
    *) _PAI_REMAINING_ARGS+=("$_arg") ;;
  esac
done

# Derive all instance variables
if [ -n "$_PAI_NAME" ]; then
  INSTANCE_NAME="pai-${_PAI_NAME}"
  INSTANCE_SUFFIX="-${_PAI_NAME}"
  WORKSPACE="$HOME/pai-workspace-${_PAI_NAME}"
  LOG_FILE="$HOME/.pai-install-${_PAI_NAME}.log"
  PORTAL_PORT="${_PAI_PORT:-8081}"
else
  INSTANCE_NAME="pai"
  INSTANCE_SUFFIX=""
  WORKSPACE="$HOME/pai-workspace"
  LOG_FILE="$HOME/.pai-install.log"
  PORTAL_PORT="${_PAI_PORT:-8080}"
fi

CONTAINER_NAME="$INSTANCE_NAME"

# Export for subshells
export INSTANCE_NAME INSTANCE_SUFFIX CONTAINER_NAME WORKSPACE PORTAL_PORT LOG_FILE

# ─── Shared workspace directories ────────────────────────────
PAI_WORKSPACE_DIRS=(claude-home data exchange portal work upstream)

# ─── Colors ──────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Shared helpers ─────────────────────────────────────────

# Get the status of the instance's container ("RUNNING", "STOPPED", or "")
pai_container_status() {
  local status
  status=$(incus info "$CONTAINER_NAME" 2>/dev/null | grep "^Status:" | awk '{print $2}')
  echo "${status:-}"
}

# Ensure container is running, start it if not
pai_ensure_running() {
  local status
  status=$(pai_container_status)

  if [ -z "$status" ]; then
    echo -e "${RED}✗${NC} Container '$CONTAINER_NAME' does not exist. Run install.sh first."
    return 1
  fi

  if [ "$status" != "RUNNING" ]; then
    echo "  Starting $CONTAINER_NAME..."
    incus start "$CONTAINER_NAME"
    # Wait for systemd to be ready
    for _i in $(seq 1 30); do
      if incus exec "$CONTAINER_NAME" -- systemctl is-system-running --wait &>/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi
  return 0
}

# Check that Incus is available, exit if not
pai_require_incus() {
  if ! command -v incus &>/dev/null; then
    echo -e "${RED}✗${NC} Incus not found. Run install.sh first."
    exit 1
  fi
}

# Check that the container exists, exit if not
pai_require_container() {
  pai_require_incus
  if ! incus info "$CONTAINER_NAME" &>/dev/null 2>&1; then
    echo -e "${RED}✗${NC} Container '$CONTAINER_NAME' does not exist. Run install.sh first."
    exit 1
  fi
}

# Execute a command inside the container as the claude user
pai_exec() {
  incus exec "$CONTAINER_NAME" --user 1000 --group 1000 --cwd /home/claude --env HOME=/home/claude -- "$@"
}
