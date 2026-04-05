#!/bin/bash
# PAI-Incus — Mount a host directory into the sandbox
# Adds a permanent shared folder so the AI can access files on your machine.
#
# Usage:
#   ./scripts/mount.sh ~/Projects/my-repo                         # Mount as /home/claude/my-repo
#   ./scripts/mount.sh ~/Projects/my-repo /home/claude/code        # Mount at a specific path
#   ./scripts/mount.sh --list                                      # Show current mounts
#   ./scripts/mount.sh --remove my-repo                            # Remove a mount by name
#   ./scripts/mount.sh --name=v2 ~/Projects/my-repo                # Target a named instance
#
# Unlike pai-lima, Incus mounts are live — no container restart needed
# unless the container is stopped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh" "$@"

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }

usage() {
  echo "Usage: $(basename "$0") [--name=X] <host-path> [container-path]"
  echo ""
  echo "  host-path        Directory on your machine to share (must exist)"
  echo "  container-path   Where it appears in the sandbox (default: /home/claude/<dirname>)"
  echo ""
  echo "Options:"
  echo "  --list           Show currently mounted directories"
  echo "  --remove <name>  Remove a mount by its device name"
  echo "  --name=X         Target a named instance (default: pai)"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") ~/Projects/my-repo"
  echo "  $(basename "$0") ~/Projects/my-repo /home/claude/code"
  echo "  $(basename "$0") --list"
  echo "  $(basename "$0") --remove my-repo"
  exit 1
}

# Parse positional args from remaining (--name already consumed by common.sh)
HOST_PATH=""
CONTAINER_PATH=""
LIST_MODE=false
REMOVE_MODE=false
REMOVE_NAME=""

for arg in ${_PAI_REMAINING_ARGS[@]+"${_PAI_REMAINING_ARGS[@]}"}; do
  case "$arg" in
    --list) LIST_MODE=true ;;
    --remove) REMOVE_MODE=true ;;
    -*)  ;; # skip unknown flags
    *)
      if [ "$REMOVE_MODE" = true ] && [ -z "$REMOVE_NAME" ]; then
        REMOVE_NAME="$arg"
      elif [ -z "$HOST_PATH" ]; then
        HOST_PATH="$arg"
      elif [ -z "$CONTAINER_PATH" ]; then
        CONTAINER_PATH="$arg"
      fi
      ;;
  esac
done

pai_require_incus
pai_require_container

# --- List mode ---

if [ "$LIST_MODE" = true ]; then
  echo ""
  echo -e "${BOLD}Shared folders for ${CONTAINER_NAME}:${NC}"
  echo ""

  # Get all disk devices from the instance-specific profile
  DEVICES=$(incus config show "$CONTAINER_NAME" 2>/dev/null | awk '/^devices:/,/^[^ ]/' | grep -B1 "type: disk" | grep -v "type: disk" | grep -v "^--$" | sed 's/://;s/^ *//' || true)

  if [ -z "$DEVICES" ]; then
    # Fall back to profile devices
    DEVICES=$(incus profile show "$CONTAINER_NAME" 2>/dev/null | awk '/^devices:/,/^[^ ]/' | grep -B1 "type: disk" | grep -v "type: disk" | grep -v "^--$" | sed 's/://;s/^ *//' || true)
  fi

  # Show each disk device with source and path
  FOUND=false
  for dev in $DEVICES; do
    SOURCE=$(incus config device get "$CONTAINER_NAME" "$dev" source 2>/dev/null || \
             incus profile device get "$CONTAINER_NAME" "$dev" source 2>/dev/null || echo "")
    PATH_IN=$(incus config device get "$CONTAINER_NAME" "$dev" path 2>/dev/null || \
              incus profile device get "$CONTAINER_NAME" "$dev" path 2>/dev/null || echo "")
    if [ -n "$SOURCE" ] && [ -n "$PATH_IN" ] && [ "$PATH_IN" != "/" ]; then
      printf "  %-12s %-40s → %s\n" "[$dev]" "$SOURCE" "$PATH_IN"
      FOUND=true
    fi
  done

  if [ "$FOUND" = false ]; then
    echo "  No shared folders found."
  fi
  echo ""
  exit 0
fi

# --- Remove mode ---

if [ "$REMOVE_MODE" = true ]; then
  if [ -z "$REMOVE_NAME" ]; then
    fail "Specify a device name to remove. Use --list to see current mounts."
  fi
  echo ""
  echo -e "${BOLD}Removing mount '${REMOVE_NAME}' from ${CONTAINER_NAME}:${NC}"
  echo ""
  if incus config device remove "$CONTAINER_NAME" "$REMOVE_NAME" >> /dev/null 2>&1; then
    ok "Mount '$REMOVE_NAME' removed"
  else
    fail "Device '$REMOVE_NAME' not found. Use --list to see current mounts."
  fi
  echo ""
  exit 0
fi

# --- Add mount ---

if [ -z "$HOST_PATH" ]; then
  usage
fi

# Resolve to absolute path
HOST_PATH=$(cd "$HOST_PATH" 2>/dev/null && pwd) || fail "Directory not found: $HOST_PATH"

# Default container path: /home/claude/<dirname>
if [ -z "$CONTAINER_PATH" ]; then
  DIRNAME=$(basename "$HOST_PATH")
  CONTAINER_PATH="/home/claude/${DIRNAME}"
fi

# Generate a device name from the directory name (alphanumeric + hyphens only)
DEVICE_NAME=$(basename "$HOST_PATH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# Check if already mounted
if incus config device get "$CONTAINER_NAME" "$DEVICE_NAME" source &>/dev/null 2>&1; then
  warn "Already mounted as '${DEVICE_NAME}'"
  exit 0
fi

echo ""
echo -e "${BOLD}Mounting directory into ${CONTAINER_NAME}:${NC}"
echo ""
echo "  Host:      $HOST_PATH"
echo "  Sandbox:   $CONTAINER_PATH"
echo "  Device:    $DEVICE_NAME"
echo ""

incus config device add "$CONTAINER_NAME" "$DEVICE_NAME" disk \
  source="$HOST_PATH" path="$CONTAINER_PATH" >> /dev/null 2>&1
ok "Mount added"

echo ""
echo -e "${GREEN}Done!${NC} Your directory is now available in the sandbox at:"
echo ""
echo "  ${CONTAINER_PATH}"
echo ""
echo "  Changes on your machine are instantly visible in the sandbox,"
echo "  and vice versa. No restart needed."
echo ""
