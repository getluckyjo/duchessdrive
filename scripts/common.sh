#!/usr/bin/env bash
# Shared settings and helpers. Sourced by the numbered scripts.

REMOTE="${REMOTE:-duchess}"
DEST_ROOT="${DEST_ROOT:-/Volumes/Duchess}"
BACKUP_DIR="${BACKUP_DIR:-$DEST_ROOT/theduchess-backup}"
LOG_DIR="${LOG_DIR:-$HOME/duchess-backup/logs}"
INVENTORY_DIR="${INVENTORY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/inventory}"

# Tunables
TRANSFERS="${TRANSFERS:-8}"
CHECKERS="${CHECKERS:-16}"
TPSLIMIT="${TPSLIMIT:-10}"
EXPORT_FORMATS="${EXPORT_FORMATS:-docx,xlsx,pptx,svg}"
BWLIMIT="${BWLIMIT:-}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m FAIL\033[0m %s\n' "$*" >&2; exit 1; }

need_rclone() {
  command -v rclone >/dev/null 2>&1 || die "rclone not installed. Run: brew install rclone"
}

need_remote() {
  rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:" \
    || die "rclone remote '${REMOTE}:' not configured. Run scripts/01-configure-remote.sh first."
}

need_disk() {
  [ -d "$DEST_ROOT" ] || die "$DEST_ROOT is not mounted. Plug the disk in."
  mount | grep -q " on $DEST_ROOT " || warn "$DEST_ROOT exists but is not a mount point - is the right disk attached?"
}

timestamp() { date +%Y%m%d-%H%M%S; }
