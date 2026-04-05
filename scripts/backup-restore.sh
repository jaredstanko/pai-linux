#!/bin/bash
# PAI-Incus — Backup and Restore
# Uses Incus snapshots for the container and file copy for the workspace.
#
# Usage:
#   ./scripts/backup-restore.sh backup              # Back up default instance
#   ./scripts/backup-restore.sh backup --name=v2    # Back up named instance
#   ./scripts/backup-restore.sh restore             # Restore from a backup
#   ./scripts/backup-restore.sh restore --name=v2   # Restore named instance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh" "$@"

BACKUP_DIR="$SCRIPT_DIR/../backups"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <subcommand> [--name=X]"
  echo ""
  echo "Subcommands:"
  echo "  backup     Back up the Incus container (snapshot) and workspace (file copy)"
  echo "  restore    Restore from a previous backup"
  echo ""
  echo "Options:"
  echo "  --name=X   Target a named instance (default: pai)"
  echo ""
  echo "Backups:"
  echo "  Container: Incus snapshots (stored by Incus)"
  echo "  Workspace: Copied to $BACKUP_DIR/"
  exit 1
}

list_snapshots() {
  incus info "$CONTAINER_NAME" 2>/dev/null | awk '/^Snapshots:$/,/^$/' | grep -E '^\s+\S' | awk '{print $1}' || true
}

pick_snapshot() {
  local snapshots
  snapshots=$(list_snapshots)

  if [ -z "$snapshots" ]; then
    echo "No snapshots found for container '$CONTAINER_NAME'." >&2
    exit 1
  fi

  echo "Available snapshots for '$CONTAINER_NAME':" >&2
  local i=1
  local snap_array=()
  while IFS= read -r snap; do
    echo "  $i) $snap" >&2
    snap_array+=("$snap")
    ((i++))
  done <<< "$snapshots"

  printf "Select snapshot number: " >&2
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#snap_array[@]} )); then
    echo "Invalid selection." >&2
    exit 1
  fi

  echo "${snap_array[$((choice - 1))]}"
}

# ── Backup ────────────────────────────────────────────────────────────────────

do_backup() {
  # Check container exists
  if ! incus info "$CONTAINER_NAME" &>/dev/null 2>&1; then
    echo -e "${RED}✗${NC} Container '$CONTAINER_NAME' does not exist."
    exit 1
  fi

  local date_stamp
  date_stamp=$(date +%Y%m%d-%H%M%S)
  local snap_name="backup-${date_stamp}"

  local was_running=false
  local status
  status=$(pai_container_status)

  # Stop container for a consistent snapshot
  if [ "$status" = "RUNNING" ]; then
    echo "  Stopping container for consistent snapshot..."
    incus stop "$CONTAINER_NAME" --timeout 30
    was_running=true
  fi

  # Create Incus snapshot
  echo "  Creating Incus snapshot: $snap_name..."
  incus snapshot create "$CONTAINER_NAME" "$snap_name"
  ok "Snapshot '$snap_name' created"

  # Back up workspace (host-side files)
  if [ -d "$WORKSPACE" ]; then
    mkdir -p "$BACKUP_DIR"
    local workspace_dest="$BACKUP_DIR/workspace-${date_stamp}-${CONTAINER_NAME}"
    echo "  Backing up workspace: $WORKSPACE → $(basename "$workspace_dest")"
    cp -r "$WORKSPACE" "$workspace_dest"
    ok "Workspace backed up to $workspace_dest"
  else
    warn "No workspace found at $WORKSPACE — skipping workspace backup"
  fi

  # Restart container if it was running
  if $was_running; then
    echo "  Restarting container..."
    incus start "$CONTAINER_NAME"
    ok "Container restarted"
  fi

  echo ""
  echo -e "${GREEN}✓${NC} Backup complete."
  echo "  Snapshot: $snap_name (inside Incus)"
  echo "  Workspace: ${workspace_dest:-skipped}"
  echo ""
  echo "  To list snapshots: incus info $CONTAINER_NAME"
  echo "  To restore: ./scripts/backup-restore.sh restore${INSTANCE_SUFFIX:+ --name=${_PAI_NAME}}"
}

# ── Restore ───────────────────────────────────────────────────────────────────

do_restore() {
  # Check container exists
  if ! incus info "$CONTAINER_NAME" &>/dev/null 2>&1; then
    echo -e "${RED}✗${NC} Container '$CONTAINER_NAME' does not exist. Cannot restore without a container."
    echo "  Run ./install.sh first to create the container, then restore."
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Restore container from snapshot${NC}"
  echo ""

  local snap_name
  snap_name=$(pick_snapshot)

  echo ""
  echo -e "  ${YELLOW}This will revert the container to snapshot '$snap_name'.${NC}"
  echo -e "  ${YELLOW}All container changes since that snapshot will be lost.${NC}"
  echo -ne "  Continue? [y/N]: "
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "  Restore cancelled."
    exit 0
  fi

  # Stop container if running
  local status
  status=$(pai_container_status)
  if [ "$status" = "RUNNING" ]; then
    echo "  Stopping container..."
    incus stop "$CONTAINER_NAME" --timeout 30
  fi

  # Restore snapshot
  echo "  Restoring snapshot '$snap_name'..."
  incus snapshot restore "$CONTAINER_NAME" "$snap_name"
  ok "Container restored to '$snap_name'"

  # Offer workspace restore
  if [ -d "$BACKUP_DIR" ]; then
    local workspace_backups
    workspace_backups=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "workspace-*-${CONTAINER_NAME}" 2>/dev/null | sort)

    if [ -n "$workspace_backups" ]; then
      echo ""
      echo -e "${BOLD}Restore workspace?${NC}"
      echo ""

      local i=1
      local backup_array=()
      while IFS= read -r bdir; do
        local size
        size=$(du -sh "$bdir" 2>/dev/null | cut -f1)
        echo "  $i) $(basename "$bdir")  [$size]"
        backup_array+=("$bdir")
        ((i++))
      done <<< "$workspace_backups"

      echo "  0) Skip workspace restore"
      echo ""
      printf "  Select backup number: "
      read -r wchoice

      if [[ "$wchoice" =~ ^[0-9]+$ ]] && (( wchoice >= 1 && wchoice <= ${#backup_array[@]} )); then
        local selected="${backup_array[$((wchoice - 1))]}"

        if [ -d "$WORKSPACE" ]; then
          echo -ne "  ${YELLOW}Overwrite existing ${WORKSPACE}/? [y/N]:${NC} "
          read -r wconfirm
          if [[ ! "$wconfirm" =~ ^[Yy]$ ]]; then
            echo "  Skipping workspace restore."
          else
            rm -rf "$WORKSPACE"
            cp -r "$selected" "$WORKSPACE"
            ok "Workspace restored from $(basename "$selected")"
          fi
        else
          cp -r "$selected" "$WORKSPACE"
          ok "Workspace restored from $(basename "$selected")"
        fi
      else
        echo "  Skipping workspace restore."
      fi
    fi
  fi

  # Restart container
  echo "  Starting container..."
  incus start "$CONTAINER_NAME"
  ok "Container started"

  echo ""
  echo -e "${GREEN}✓${NC} Restore complete."
}

# ── Entry point ───────────────────────────────────────────────────────────────

SUBCOMMAND=""
for arg in "${_PAI_REMAINING_ARGS[@]+"${_PAI_REMAINING_ARGS[@]}"}"; do
  case "$arg" in
    backup|restore) SUBCOMMAND="$arg" ;;
    -*) ;; # skip flags
    *) ;;
  esac
done

if [ -z "$SUBCOMMAND" ]; then
  usage
fi

case "$SUBCOMMAND" in
  backup)  do_backup ;;
  restore) do_restore ;;
  *)       usage ;;
esac
