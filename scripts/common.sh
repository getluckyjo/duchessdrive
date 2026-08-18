#!/usr/bin/env bash
# Shared settings and helpers. Sourced by the numbered scripts.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REMOTE="${REMOTE:-duchess}"
DEST_ROOT="${DEST_ROOT:-/Volumes/Duchess}"
BACKUP_DIR="${BACKUP_DIR:-$DEST_ROOT/theduchess-backup}"
LOG_DIR="${LOG_DIR:-$HOME/duchess-backup/logs}"
INVENTORY_DIR="${INVENTORY_DIR:-$REPO_ROOT/inventory}"
ACCOUNTS="${ACCOUNTS:-$REPO_ROOT/accounts.tsv}"

# Service account with domain-wide delegation - one credential, every mailbox
# and Drive in the org. Kept outside the repo and off the backup disk.
SA_DIR="${SA_DIR:-$HOME/.config/duchess-backup}"
SA_FILE="${SA_FILE:-$SA_DIR/service-account.json}"
GYB_CONFIG="${GYB_CONFIG:-$SA_DIR/gyb}"

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

need_sa() {
  [ -f "$SA_FILE" ] || die "No service account key at $SA_FILE. See README step 3."
}

need_disk() {
  [ -d "$DEST_ROOT" ] || die "$DEST_ROOT is not mounted. Plug the disk in."
  mount | grep -q " on $DEST_ROOT " || warn "$DEST_ROOT exists but is not a mount point - is the right disk attached?"
}

need_accounts() {
  [ -s "$ACCOUNTS" ] || die "No account list at $ACCOUNTS."
}

# Feed "email drive_gb gmail_gb" for each account to a function named $1.
# Reads on fd 3 so the callee can use stdin freely.
for_each_account() {
  fn="$1"
  while IFS="$(printf '\t')" read -r email dgb mgb <&3; do
    case "$email" in ''|\#*) continue ;; esac
    "$fn" "$email" "${dgb:-0}" "${mgb:-0}"
  done 3< "$ACCOUNTS"
}

# Filesystem-safe directory name for an email address.
safe_name() { printf '%s' "$1" | tr '/:' '__'; }

timestamp() { date +%Y%m%d-%H%M%S; }
