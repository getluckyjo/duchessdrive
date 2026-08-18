#!/usr/bin/env bash
# MD5-compares every copied Drive file against the live account, and counts
# the Gmail messages on disk against what the mailbox reports.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

TSV="$INVENTORY_DIR/shared-drives.tsv"

need_rclone; need_remote; need_disk; need_accounts
# Impersonation requires a service account; a plain OAuth remote can only see
# the account that signed in.
if rclone config show "$REMOTE" 2>/dev/null | grep -q '^service_account_file'; then
  MODE=delegated
else
  MODE=self
  SELF_EMAIL="${SELF_EMAIL:-johannes@theduchess.co.za}"
fi

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
    warn "$label: not copied yet, skipping"
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
echo "     Drive files are compared by MD5. Google-native docs are excluded:"
echo "     an exported .docx legitimately differs from the Google Doc."

if [ "$MODE" = delegated ]; then
  check_account() {
    email="$1"
    do_check "Drive: $email" "drive/$(safe_name "$email")" --drive-impersonate "$email"
  }
  for_each_account check_account
else
  warn "OAuth remote - checking only $SELF_EMAIL"
  do_check "Drive: $SELF_EMAIL" "drive/$(safe_name "$SELF_EMAIL")"
fi

if [ -s "$TSV" ]; then
  ADMIN="$(awk -F'\t' '!/^#/ && $1 != "" {print $1; exit}' "$ACCOUNTS")"
  while IFS="$(printf '\t')" read -r id name <&3; do
    case "$id" in ''|\#*) continue ;; esac
    [ -n "$name" ] || name="$id"
    if [ "$MODE" = delegated ]; then
      do_check "Shared Drive: $name" "shared-drives/$(safe_name "$name")" \
        --drive-impersonate "$ADMIN" --drive-team-drive "$id"
    else
      do_check "Shared Drive: $name" "shared-drives/$(safe_name "$name")" --drive-team-drive "$id"
    fi
  done 3< "$TSV"
fi

echo
say "Gmail message counts"
gmail_count() {
  email="$1"
  dest="$BACKUP_DIR/gmail/$(safe_name "$email")"
  if [ ! -d "$dest" ]; then
    warn "$email: no Gmail backup yet"
    return
  fi
  n="$(find "$dest" -name '*.eml' -type f 2>/dev/null | wc -l | tr -d ' ')"
  printf '  %-32s %s messages on disk\n' "$email" "$n"
}
for_each_account gmail_count
echo "     Compare against 'gyb --action estimate --email <address> --service-account"
echo "     --config-folder $GYB_CONFIG' if you want the server-side count."

echo
if [ "$diffs" -eq 0 ]; then
  say "Drive verified. Every non-Google-native file matches by MD5."
else
  say "$diffs section(s) reported differences."
  say "Re-run 03-copy-drive.sh to fill gaps, then verify again. Differences that"
  say "survive a re-copy are worth reading in $LOG - case-collisions land here."
  exit 1
fi
