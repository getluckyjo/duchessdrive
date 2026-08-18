#!/usr/bin/env bash
# Drive for every account in accounts.tsv, ~266 GB. Resumable: Ctrl-C, re-run.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

TSV="$INVENTORY_DIR/shared-drives.tsv"

# Keep the Mac awake. Re-exec self under caffeinate once.
if [ -z "${UNDER_CAFFEINATE:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  UNDER_CAFFEINATE=1 exec caffeinate -dims "$0" "$@"
fi

need_rclone; need_remote; need_sa; need_disk; need_accounts
mkdir -p "$LOG_DIR" "$BACKUP_DIR/drive"

RUN="$(timestamp)"
LOG="$LOG_DIR/drive-$RUN.log"
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
echo "     Eject the disk properly when done; exFAT has no journal."

copy_account() {
  email="$1"; dgb="$2"
  do_copy "Drive: $email (~${dgb} GB)" "drive/$(safe_name "$email")" --drive-impersonate "$email"
}
for_each_account copy_account

if [ -s "$TSV" ]; then
  ADMIN="$(awk -F'\t' '!/^#/ && $1 != "" {print $1; exit}' "$ACCOUNTS")"
  while IFS="$(printf '\t')" read -r id name <&3; do
    case "$id" in ''|\#*) continue ;; esac
    [ -n "$name" ] || name="$id"
    do_copy "Shared Drive: $name" "shared-drives/$(safe_name "$name")" \
      --drive-impersonate "$ADMIN" --drive-team-drive "$id"
  done 3< "$TSV"
else
  say "No Shared Drives listed - skipping (run 02-inventory.sh if that seems wrong)"
fi

echo
if [ "$failures" -eq 0 ]; then
  say "Drive done. Next: ./scripts/05-copy-gmail.sh, then ./scripts/04-verify.sh"
else
  say "$failures section(s) reported errors. Re-run to retry only what is missing,"
  say "then read $LOG for anything that keeps failing."
  exit 1
fi
