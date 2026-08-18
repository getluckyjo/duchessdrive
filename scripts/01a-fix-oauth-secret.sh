#!/usr/bin/env bash
# Repairs the client secret on an existing OAuth remote and re-runs sign-in.
# For the interim setup, before the service account exists. Prompts rather than
# taking an argument so the secret never lands in your shell history.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

need_rclone
rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:" \
  || die "No remote '${REMOTE}:' to repair."

cat <<'MSG'

Get the secret from the Google Cloud console:

  APIs & Services -> Clients -> your Desktop app client

Click into the client itself; the secret is on that page and can be viewed
again at any time (unlike a service account key, which downloads once).

MSG

id="$(rclone config show "$REMOTE" 2>/dev/null | awk -F' = ' '/^client_id/ {print $2}')"
[ -n "$id" ] && echo "Remote's current client ID: $id" && echo

echo "Client secret (starts GOCSPX-). Nothing appears as you paste - input is"
echo "hidden on purpose. Paste it and press Return."
printf 'Client secret: '
read -rs SECRET
echo
[ -n "$SECRET" ] || die "Nothing entered. Re-run and paste at the prompt."
ok "got ${#SECRET} characters"

case "$SECRET" in
  GOCSPX-*) ;;
  *) warn "That does not start with 'GOCSPX-'. If this fails again, check you"
     warn "copied the secret and not the client ID." ;;
esac
case "$SECRET" in
  *' '*|*$'\t'*) warn "There is whitespace in that value - a partial or wrapped paste is likely." ;;
esac

say "Updating the remote"
rclone config update "$REMOTE" client_secret="$SECRET" --non-interactive >/dev/null \
  || die "Could not update the remote."
ok "secret stored"

echo
say "Re-running sign-in"
echo "     A browser opens. Sign in as johannes@theduchess.co.za and click Allow."
echo "     Do not touch this terminal until it prints a result."
echo
rclone config reconnect "${REMOTE}:" || die "Sign-in failed. Send me the exact error."

echo
say "Verifying"
if rclone about "${REMOTE}:"; then
  ok "working - that quota is the live Drive"
  echo
  say "Next: ./scripts/03-copy-drive.sh"
else
  die "Token obtained but the Drive API still refuses. Send me this error - it is a different problem from the credential."
fi
