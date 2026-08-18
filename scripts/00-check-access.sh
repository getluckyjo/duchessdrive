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
ERRS="$(mktemp)"

say "1. Can we read the account's quota?"
if out="$(rc about "${REMOTE}:" 2>&1)"; then
  printf '%s\n' "$out"
  ok "quota readable - the Drive API is answering"
else
  printf '%s\n' "$out"; printf '%s\n' "$out" >> "$ERRS"
  warn "rclone about failed"
  fail=1
fi

echo
say "2. Can we list the top level of My Drive?"
if out="$(rc lsd "${REMOTE}:" --max-depth 1 2>&1)"; then
  printf '%s\n' "$out" | head -20
  ok "listing works"
else
  printf '%s\n' "$out"; printf '%s\n' "$out" >> "$ERRS"
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
  if out="$(rc copy "${REMOTE}:$first" "$probe" --retries 1 --low-level-retries 2 2>&1)"; then
    printf '%s\n' "$out"
    got="$(find "$probe" -type f | head -1)"
    if [ -n "$got" ]; then
      ok "downloaded $(wc -c < "$got" | tr -d ' ') bytes - reads are permitted over quota"
    else
      warn "copy reported success but produced no file"
      fail=1
    fi
  else
    printf '%s\n' "$out"; printf '%s\n' "$out" >> "$ERRS"
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
  say "RED. Something is refusing us. Which something matters a lot:"
  echo
  if grep -qiE "empty token|oauth|token expired|invalid_grant|refresh token|config reconnect|couldn.t fetch token" "$ERRS"; then
    say "NOT the licensing question - this is a broken credential."
    say "The remote exists but has no working token, usually a sign-in that was"
    say "interrupted before the browser handed the code back. Fix it with:"
    echo
    echo "    rclone config reconnect ${REMOTE}:"
    echo
    say "Let the browser finish before touching the terminal, then re-run this."
    say "Setting up the service account (README step 3) also replaces this remote"
    say "entirely, so repairing it is optional if you are going there next anyway."
  elif grep -qiE "storage quota|exceeded their .*quota|insufficient.*storage|subscription|not have a valid license|accountDisabled|domain policy" "$ERRS"; then
    say "This IS the licensing question. Drive service is refusing the account,"
    say "not the credential. rclone cannot get around it - the data has to come"
    say "out by re-subscribing or through Vault. Send me the error above."
  else
    say "Unrecognised failure. Send me the error above before changing anything -"
    say "it is not obviously either a credential or a licensing problem."
  fi
  rm -f "$ERRS"
  exit 1
fi
rm -f "$ERRS"
