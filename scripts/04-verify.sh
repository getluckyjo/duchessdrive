#!/usr/bin/env bash
# MD5-compares every copied file against the live Drive.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

TSV="$INVENTORY_DIR/shared-drives.tsv"

need_rclone
need_remote
need_disk
mkdir -p "$LOG_DIR"

RUN="$(timestamp)"
LOG="$LOG_DIR/verify-$RUN.log"
diffs=0

FLAGS=(
  --one-way
  --drive-skip-gdocs
  --fast-list
  --checkers "$CHECKERS"
  --tpslimit "$TPSLIMIT"
  --log-level NOTICE
  --log-file "$LOG"
)

do_check() { # label, dest subdir, extra rclone args...
  label="$1"; sub="$2"; shift 2
  dest="$BACKUP_DIR/$sub"
  if [ ! -d "$dest" ]; then
    warn "$label: $dest does not exist - not copied yet, skipping"
    return
  fi
  echo
  say "Checking $label"
  if rclone check "${REMOTE}:" "$dest" "${FLAGS[@]}" "$@" </dev/null; then
    ok "$label matches"
  else
    warn "$label has differences - see $LOG"
    diffs=$((diffs+1))
  fi
}

say "Run $RUN   log: $LOG"
echo "     Compares MD5 hashes both sides. Google-native docs are excluded:"
echo "     their exported .docx/.xlsx legitimately differs from the source."

do_check "My Drive" "my-drive"

if [ -s "$TSV" ]; then
  while IFS=$'\t' read -r id name <&3; do
    case "$id" in ''|\#*) continue ;; esac
    [ -n "$name" ] || name="$id"
    safe="$(printf '%s' "$name" | tr '/:' '__')"
    do_check "Shared Drive: $name" "shared-drives/$safe" --drive-team-drive "$id"
  done 3< "$TSV"
fi

if [ -d "$BACKUP_DIR/shared-with-me" ]; then
  do_check "Shared with me" "shared-with-me" --drive-shared-with-me
fi

echo
if [ "$diffs" -eq 0 ]; then
  say "Verified. Every non-Google-native file matches by MD5."
else
  say "$diffs section(s) reported differences."
  say "Re-run ./scripts/03-copy.sh to fill gaps, then verify again."
  say "Differences that survive a re-copy are worth reading in $LOG -"
  say "case-insensitive-filesystem collisions show up here."
  exit 1
fi
