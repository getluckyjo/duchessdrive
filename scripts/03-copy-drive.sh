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

need_rclone; need_remote; need_disk; need_accounts

# Impersonation requires a service account. With a plain OAuth remote we can
# only reach the one account that signed in - still worth running, since that
# is bytes on the disk tonight rather than waiting for delegation.
MODE=""
for attempt in 1 2 3; do
  cfg="$(rclone config show "$REMOTE" 2>/dev/null)"
  if printf '%s' "$cfg" | grep -q '^service_account_file'; then MODE=delegated; break; fi
  if printf '%s' "$cfg" | grep -q '^\[\?'"$REMOTE"; then MODE=self; break; fi
  sleep 1
done
[ -n "$MODE" ] || die "Could not read the config for remote '$REMOTE' after 3 tries."

n_accounts="$(awk -F'\t' '!/^#/ && $1 != "" {n++} END {print n+0}' "$ACCOUNTS")"
say "remote=$REMOTE  mode=$MODE  accounts=$n_accounts"

# A silent fall back to self mode once copied one account when four were asked
# for, and reported success. If the two disagree now, stop and say so.
if [ "$MODE" = self ] && [ "$n_accounts" -gt 1 ]; then
  warn "Remote '$REMOTE' has no service account, but $ACCOUNTS lists $n_accounts accounts."
  warn "Impersonation needs a service account, so this would quietly copy only one"
  warn "of them and report success. Refusing."
  die "Point REMOTE at the service-account remote, or set SELF_MODE=1 to copy just one account deliberately."
fi
if [ "$MODE" = self ]; then
  SELF_EMAIL="${SELF_EMAIL:-$(awk -F'\t' '!/^#/ && $1 != "" {print $1; exit}' "$ACCOUNTS")}"
  SELF_EMAIL="${SELF_EMAIL:-johannes@theduchess.co.za}"
fi
mkdir -p "$LOG_DIR" "$BACKUP_DIR/drive"

RUN="$(timestamp)"
LOG="$LOG_DIR/drive-$RUN.log"
failures=0
interrupted=0

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
)
# Only draw the live progress bar when attached to a terminal - detached runs
# get their progress from --stats in the log instead of megabytes of escape codes.
[ -t 1 ] && FLAGS+=(--progress)
[ -n "$BWLIMIT" ] && FLAGS+=(--bwlimit "$BWLIMIT")

# rclone writes to "<name>.<8 hex>.partial" then renames. Workers killed
# mid-write leave theirs behind, with a fresh random suffix every run, so they
# accumulate forever across interruptions. Clear them before starting.
clean_partials() {
  d="$1"
  # Walking a large tree on exFAT costs minutes. SKIP_PARTIAL_CLEAN=1 skips
  # it when a sweep has already proven this destination clean.
  [ -n "${SKIP_PARTIAL_CLEAN:-}" ] && return 0
  [ -d "$d" ] || return 0
  list="$(find "$d" -type f -name '*.partial' 2>/dev/null | grep -E '\.[0-9a-f]{8}\.partial$')"
  [ -n "$list" ] || return 0
  n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  say "Clearing $n orphaned .partial file(s) left by an interrupted run"
  printf '%s\n' "$list" | while IFS= read -r f; do [ -n "$f" ] && rm -f "$f"; done
}

do_copy() { # label, dest subdir, extra rclone args...
  label="$1"; sub="$2"; shift 2
  dest="$BACKUP_DIR/$sub"
  mkdir -p "$dest"
  clean_partials "$dest"
  echo
  say "$label  ->  $dest"
  if rclone copy "${REMOTE}:" "$dest" "${FLAGS[@]}" "$@" </dev/null; then
    ok "$label complete"
  else
    code=$?
    case "$code" in
      130|143)
        warn "$label interrupted by you (exit $code) - not an error."
        warn "Everything transferred so far is on the disk. Re-run to resume."
        interrupted=1 ;;
      *)
        warn "$label finished with errors (rclone exit $code). Details in $LOG"
        failures=$((failures+1)) ;;
    esac
  fi
}

say "Run $RUN   log: $LOG"
echo "     Leave the lid OPEN - caffeinate cannot prevent clamshell sleep."
echo "     Eject the disk properly when done; exFAT has no journal."

if [ "$MODE" = delegated ]; then
  copy_account() {
    email="$1"; dgb="$2"
    do_copy "Drive: $email (~${dgb} GB)" "drive/$(safe_name "$email")" --drive-impersonate "$email"
  }
  for_each_account copy_account
else
  warn "OAuth remote, not a service account - copying only $SELF_EMAIL."
  warn "The other accounts need delegation (README step 3); re-run this after."
  do_copy "Drive: $SELF_EMAIL" "drive/$(safe_name "$SELF_EMAIL")"
fi

if [ -s "$TSV" ]; then
  ADMIN="$(awk -F'\t' '!/^#/ && $1 != "" {print $1; exit}' "$ACCOUNTS")"
  while IFS="$(printf '\t')" read -r id name <&3; do
    case "$id" in ''|\#*) continue ;; esac
    [ -n "$name" ] || name="$id"
    if [ "$MODE" = delegated ]; then
      do_copy "Shared Drive: $name" "shared-drives/$(safe_name "$name")" \
        --drive-impersonate "$ADMIN" --drive-team-drive "$id"
    else
      do_copy "Shared Drive: $name" "shared-drives/$(safe_name "$name")" --drive-team-drive "$id"
    fi
  done 3< "$TSV"
else
  say "No Shared Drives listed - skipping (run 02-inventory.sh if that seems wrong)"
fi

echo
if [ "$interrupted" -eq 1 ] && [ "$failures" -eq 0 ]; then
  say "Interrupted, nothing lost. Re-run this script to pick up where it stopped;"
  say "it re-checks what is already on the disk and only fetches what is missing."
  exit 130
elif [ "$failures" -eq 0 ]; then
  say "Drive done. Next: ./scripts/05-copy-gmail.sh, then ./scripts/04-verify.sh"
else
  say "$failures section(s) reported errors. Re-run to retry only what is missing,"
  say "then read $LOG for anything that keeps failing."
  exit 1
fi
