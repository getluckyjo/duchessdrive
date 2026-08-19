#!/usr/bin/env bash
# Gmail for every account in accounts.tsv, ~110 GB, via GYB (Got Your Back).
# rclone's drive backend cannot see mail at all - this is a separate tool using
# the same service account and the same domain-wide delegation.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

if [ -z "${UNDER_CAFFEINATE:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  UNDER_CAFFEINATE=1 exec caffeinate -dims "$0" "$@"
fi

need_sa; need_disk; need_accounts

if ! command -v gyb >/dev/null 2>&1; then
  warn "GYB is not installed."
  cat <<'MSG'

     GYB (Got Your Back) is the standard tool for pulling a Gmail mailbox to
     local disk. It is maintained by the GAM team and uses the Gmail API, so it
     works with the same service account you already set up.

     Download the macOS release from:
       https://github.com/GAM-team/got-your-back/releases

     Unpack it and put the `gyb` binary somewhere on your PATH, for example:
       sudo mv ~/Downloads/gyb/gyb /usr/local/bin/gyb

     The project also publishes a one-line curl-pipe-bash installer. It works,
     but it runs a downloaded script as your user - your call whether that is
     acceptable for a machine holding company data. The release download does
     the same job with one more step.

MSG
  die "Install gyb, then re-run this script."
fi

mkdir -p "$GYB_CONFIG" "$LOG_DIR" "$BACKUP_DIR/gmail"
if [ ! -f "$GYB_CONFIG/oauth2service.json" ]; then
  cp "$SA_FILE" "$GYB_CONFIG/oauth2service.json"
  chmod 600 "$GYB_CONFIG/oauth2service.json"
  ok "placed the service account key where GYB expects it"
fi

RUN="$(timestamp)"
LOG="$LOG_DIR/gmail-$RUN.log"
failures=0

say "Run $RUN   log: $LOG"
echo "     GYB writes one .eml per message plus a local index, and skips"
echo "     anything already downloaded - so re-running resumes."
echo

gmail_one() {
  email="$1"; mgb="$3"
  dest="$BACKUP_DIR/gmail/$(safe_name "$email")"
  mkdir -p "$dest"
  echo
  say "Gmail: $email (~${mgb} GB)  ->  $dest"
  if gyb --email "$email" --action backup --service-account \
         --config-folder "$GYB_CONFIG" --local-folder "$dest" 2>&1 | tee -a "$LOG"; then
    ok "$email complete"
  else
    code=$?
    case "$code" in
      130|143) warn "$email interrupted by you (exit $code) - re-run to resume." ;;
      *) warn "$email finished with errors - see $LOG"; failures=$((failures+1)) ;;
    esac
  fi
}
for_each_account gmail_one

echo
if [ "$failures" -eq 0 ]; then
  say "Gmail done. Next: ./scripts/04-verify.sh"
else
  say "$failures mailbox(es) reported errors. Re-run to resume."
  say "If it complains about scopes, gmail.readonly is probably not authorised"
  say "for the service account in Admin console - see README step 3."
  exit 1
fi
