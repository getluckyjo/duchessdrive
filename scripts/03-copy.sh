#!/usr/bin/env bash
# The transfer. Resumable: Ctrl-C and re-run whenever you like.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

INCLUDE_SHARED_WITH_ME="${INCLUDE_SHARED_WITH_ME:-0}"
TSV="$INVENTORY_DIR/shared-drives.tsv"

# Keep the Mac awake for the duration. Re-exec self under caffeinate once.
if [ -z "${UNDER_CAFFEINATE:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  UNDER_CAFFEINATE=1 exec caffeinate -dims "$0" "$@"
fi

need_rclone
need_remote
need_disk
mkdir -p "$LOG_DIR" "$BACKUP_DIR"

RUN="$(timestamp)"
LOG="$LOG_DIR/copy-$RUN.log"
failures=0

FLAGS=(
  --create-empty-src-dirs
  --drive-export-formats "$EXPORT_FORMATS"
  --drive-acknowledge-abuse
  --fast-list
  --transfers "$TRANSFERS"
  --checkers "$CHECKERS"
  --tpslimit "$TPSLIMIT"
  --retries 10
  --low-level-retries 20
  --stats 1m
  --stats-one-line
  --log-level INFO
  --log-file "$LOG"
  --progress
)
[ -n "$BWLIMIT" ] && FLAGS+=(--bwlimit "$BWLIMIT")

do_copy() { # label, dest subdir, extra rclone args...
  label="$1"; sub="$2"; shift 2
  dest="$BACKUP_DIR/$sub"
  mkdir -p "$dest"
  echo
  say "$label  ->  $dest"
  if rclone copy "${REMOTE}:" "$dest" "${FLAGS[@]}" "$@" </dev/null; then
    ok "$label complete"
  else
    warn "$label finished with errors (rclone exit $?). Details in $LOG"
    failures=$((failures+1))
  fi
}

say "Run $RUN   log: $LOG"
echo "     Leave the lid OPEN - caffeinate cannot prevent clamshell sleep."
echo "     Safe to Ctrl-C; re-run this script to resume."

do_copy "My Drive" "my-drive"

if [ -s "$TSV" ]; then
  while IFS=$'\t' read -r id name <&3; do
    case "$id" in ''|\#*) continue ;; esac
    [ -n "$name" ] || name="$id"
    safe="$(printf '%s' "$name" | tr '/:' '__')"
    do_copy "Shared Drive: $name" "shared-drives/$safe" --drive-team-drive "$id"
  done 3< "$TSV"
else
  warn "No Shared Drives listed in $TSV - skipping. Run scripts/02-inventory.sh if that seems wrong."
fi

if [ "$INCLUDE_SHARED_WITH_ME" = "1" ]; then
  do_copy "Shared with me" "shared-with-me" --drive-shared-with-me
else
  say "Skipping 'Shared with me' (set INCLUDE_SHARED_WITH_ME=1 to include it)"
fi

echo
if [ "$failures" -eq 0 ]; then
  say "All sections copied cleanly. Next: ./scripts/04-verify.sh"
else
  say "$failures section(s) reported errors. Re-run this script to retry only what is missing,"
  say "then check $LOG for anything that keeps failing."
  exit 1
fi
