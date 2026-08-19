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

if ! GYB="$(find_gyb)"; then
  warn "GYB is not installed."
  cat <<'MSG'

     GYB (Got Your Back) is the standard tool for pulling a Gmail mailbox to
     local disk. It is maintained by the GAM team and uses the Gmail API, so it
     works with the same service account you already set up.

     Install it with:

       ./scripts/05a-install-gyb.sh

     That resolves the right release for your Mac, downloads it and puts the
     binary in ~/.local/bin - no sudo, nothing piped into a shell.

     Or do it by hand from https://github.com/GAM-team/got-your-back/releases

MSG
  die "Install gyb, then re-run this script."
fi
ok "using $GYB"

mkdir -p "$GYB_CONFIG" "$LOG_DIR" "$BACKUP_DIR/gmail"
if [ ! -f "$GYB_CONFIG/oauth2service.json" ]; then
  cp "$SA_FILE" "$GYB_CONFIG/oauth2service.json"
  chmod 600 "$GYB_CONFIG/oauth2service.json"
  ok "placed the service account key where GYB expects it"
fi

# Prove delegation works on one mailbox before committing to ~110 GB. A
# one-day search keeps it to seconds while still exercising auth end to end.
FIRST="$(awk -F'\t' '!/^#/ && $1 != "" {print $1; exit}' "$ACCOUNTS")"
say "Checking Gmail delegation against $FIRST"
if out="$("$GYB" --email "$FIRST" --action estimate --service-account \
           --config-folder "$GYB_CONFIG" --search "newer_than:1d" 2>&1)"; then
  ok "delegation works"
  printf '%s\n' "$out" | tail -3 | sed 's/^/     /'
else
  printf '%s\n' "$out" | sed 's/^/     /' | tail -12
  echo
  if printf '%s' "$out" | grep -qiE "unauthorized|insufficient|scope|delegation|invalid_grant"; then
    die "Gmail delegation is not authorised. Add this scope to the service account
     in Admin console -> Security -> Access and data control -> API controls
     -> Manage Domain Wide Delegation:

       https://www.googleapis.com/auth/gmail.readonly

     The Gmail API also has to be enabled in the Cloud project."
  fi
  die "Could not read $FIRST. Send me the error above."
fi
echo

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
  if "$GYB" --email "$email" --action backup --service-account \
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
