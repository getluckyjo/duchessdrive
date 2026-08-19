#!/usr/bin/env bash
# Copy one folder from the Duchess backup onto another drive, to hand over.
#
#   ./scripts/06-handoff-copy.sh /Volumes/InusDrive
#   ./scripts/06-handoff-copy.sh /Volumes/InusDrive "1 Suncamino Rum "
#
# Disk to disk, no Google API involved. Resumable, logged, and verified by
# MD5 on both sides when it finishes.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

SRC_ROOT="${SRC_ROOT:-$BACKUP_DIR/drive/inus@theduchess.co.za}"
FOLDER="${2:-1 Suncamino Rum }"          # note: this name really does end in a space
DEST_VOL="${1:-}"

[ -n "$DEST_VOL" ] || die "Usage: $0 /Volumes/<destination> [\"folder name\"]"

SRC="$SRC_ROOT/$FOLDER"
DEST="$DEST_VOL/$FOLDER"

# ---------- preflight ----------
say "Checking both ends before moving anything"

[ -d "$DEST_VOL" ] || die "$DEST_VOL is not mounted. Plug the destination drive in."
mount | grep -q " on $DEST_VOL " || warn "$DEST_VOL is not a mount point - is that really the other drive?"
[ -d "$SRC" ] || die "Source not found: $SRC
     Plug the Duchess drive in, or pass the folder name as the second argument."

case "$(cd "$SRC" && pwd -P)" in
  "$(cd "$DEST_VOL" && pwd -P)"*) die "Source and destination are the same drive. Pick a different one." ;;
esac
ok "source:      $SRC"
ok "destination: $DEST"

fs="$(diskutil info "$DEST_VOL" 2>/dev/null | awk -F: '/File System Personality/ {sub(/^[ \t]+/,"",$2); print $2}')"
echo "     destination filesystem: ${fs:-unknown}"
case "$fs" in
  *FAT32*|*MS-DOS*) die "Destination is FAT32 - no file over 4 GB can be written. Reformat as exFAT (readable on Mac and Windows) or APFS (Mac only)." ;;
  *ExFAT*|*exFAT*)  ok "exFAT - readable on both Mac and Windows" ;;
  *APFS*|*HFS*)     warn "Apple format - Inus will not be able to read this on a Windows machine." ;;
esac

say "Measuring the source"
size_out="$(rclone size "$SRC" 2>&1)"
printf '%s\n' "$size_out" | sed 's/^/     /'
need_bytes="$(printf '%s' "$size_out" | sed -n 's/.*(\([0-9]*\) Byte).*/\1/p')"
avail_bytes=$(( $(df -k "$DEST_VOL" | tail -1 | awk '{print $4}') * 1024 ))
if [ -n "$need_bytes" ] && [ "$avail_bytes" -lt "$need_bytes" ]; then
  die "Not enough room: need $((need_bytes/1000000000)) GB, have $((avail_bytes/1000000000)) GB free on $DEST_VOL"
fi
ok "$((avail_bytes/1000000000)) GB free on the destination"

# ---------- copy ----------
if [ -z "${UNDER_CAFFEINATE:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  UNDER_CAFFEINATE=1 exec caffeinate -dims "$0" "$@"
fi

mkdir -p "$LOG_DIR" "$DEST"
RUN="$(timestamp)"
LOG="$LOG_DIR/handoff-$RUN.log"

# REPAIR=1 compares by checksum instead of size+modtime. Slower, but it is the
# only thing that re-copies a file whose contents drifted while its size and
# timestamp stayed the same - exactly what the verify step catches.
FLAGS=(
  --create-empty-src-dirs
  --transfers 4              # two drives on one bus; more heads just cause seeking
  --checkers 8
  --modify-window 2s         # FAT/exFAT timestamps are only accurate to 2s
  --retries 5
  --low-level-retries 10
  --stats 30s --stats-one-line
  --log-level INFO --log-file "$LOG"
)
[ -t 1 ] && FLAGS+=(--progress)
if [ "${REPAIR:-0}" = "1" ]; then
  FLAGS+=(--checksum)
  say "REPAIR mode: comparing by checksum, not size and timestamp"
fi

echo
say "Copying   (log: $LOG)"
echo "     Safe to Ctrl-C - re-run this exact command to resume."
if ! rclone copy "$SRC" "$DEST" "${FLAGS[@]}" </dev/null; then
  code=$?
  case "$code" in
    130|143) die "Interrupted. Nothing lost - re-run to resume." ;;
    *) warn "Copy reported errors (exit $code). Details in $LOG"
       warn "Re-run to retry only what is missing, then verify." ;;
  esac
fi
ok "copy finished"

# ---------- verify ----------
echo
say "Verifying by MD5, both sides"
echo "     This reads every byte on both drives, so it is slower than the copy."
if rclone check "$SRC" "$DEST" --checksum --modify-window 2s \
     --checkers 8 --log-level NOTICE --log-file "$LOG" </dev/null; then
  echo
  ok "VERIFIED - every file matches by checksum"
  echo
  say "Eject before unplugging:  diskutil eject $DEST_VOL"
else
  echo
  warn "Differences found - see $LOG"
  echo
  warn "If files are simply MISSING, re-running this script fills them in."
  warn "But if a file's contents drifted while its size and timestamp did not,"
  warn "a plain re-run skips it forever. Force a checksum comparison instead:"
  echo
  echo "    REPAIR=1 $0 $(printf '%q ' "$@")"
  echo
  exit 1
fi
