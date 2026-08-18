#!/usr/bin/env bash
# THE GATE. Answers one question before any other work happens:
# do these unlicensed accounts still serve the Drive API?
#
# The Workspace subscription is cancelled and all four active accounts are far
# over the 15 GB free-tier limit. Google blocks uploads when you are over quota
# but normally still serves reads - if that holds here, the whole backup works.
# If it does not, no amount of credential wrangling will help and the data has
# to come out via re-subscribing or Vault instead.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

need_rclone

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:" \
    || die "No remote '${REMOTE}:' yet. Run scripts/01-configure-remote.sh, or pass an email to test with the service account."
  say "Testing existing remote '${REMOTE}:' (whichever account it is authorised as)"
else
  need_sa
  say "Testing '${REMOTE}:' impersonating $TARGET"
fi

# rclone, with impersonation only when an account was named. Deliberately not an
# array: macOS ships bash 3.2, where expanding an empty array under `set -u` is
# an error rather than the empty list every later bash gives you.
rc() {
  if [ -n "$TARGET" ]; then
    rclone "$@" --drive-impersonate "$TARGET"
  else
    rclone "$@"
  fi
}

fail=0

say "1. Can we read the account's quota?"
if rc about "${REMOTE}:" 2>&1; then
  ok "quota readable - the Drive API is answering"
else
  warn "rclone about failed"
  fail=1
fi

echo
say "2. Can we list the top level of My Drive?"
if rc lsd "${REMOTE}:" --max-depth 1 2>&1 | head -20; then
  ok "listing works"
else
  warn "listing failed"
  fail=1
fi

echo
say "3. Can we actually download a file? (the one that really matters)"
probe="$(mktemp -d)"
first="$(rc lsf "${REMOTE}:" --files-only --max-depth 2 2>/dev/null | head -1)"
if [ -z "$first" ]; then
  warn "No file found in the first two levels to test with - inconclusive, not a failure."
else
  echo "     trying: $first"
  if rc copy "${REMOTE}:$first" "$probe" --retries 1 --low-level-retries 2 2>&1; then
    got="$(find "$probe" -type f | head -1)"
    if [ -n "$got" ]; then
      ok "downloaded $(wc -c < "$got" | tr -d ' ') bytes - reads are permitted over quota"
    else
      warn "copy reported success but produced no file"
      fail=1
    fi
  else
    warn "download failed - this is the answer that matters"
    fail=1
  fi
fi
rm -rf "$probe"

echo
if [ "$fail" -eq 0 ]; then
  say "GREEN. Reads work on this account despite the cancelled subscription."
  say "Next: ./scripts/01-configure-remote.sh (service account), then 02-inventory.sh"
else
  say "RED. Something is refusing us."
  say "If the errors mention quota, storage or a cancelled subscription, then the"
  say "accounts have lost Drive service and rclone cannot help - the data has to"
  say "come out by re-subscribing or through Vault. Send me the exact error."
  exit 1
fi
