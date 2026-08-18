#!/usr/bin/env bash
# Creates the rclone remote for the theduchess.co.za Drive and runs Google sign-in.
# Needs the OAuth client ID + secret from Step 1 of the README.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

SCOPE="${SCOPE:-drive.readonly}"

need_rclone

if rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:"; then
  warn "Remote '${REMOTE}:' already exists."
  printf 'Delete and recreate it? [y/N] '
  read -r ans
  case "$ans" in
    y|Y) rclone config delete "$REMOTE" ;;
    *)   say "Keeping it. Testing the existing remote instead."
         rclone about "${REMOTE}:" && exit 0
         die "Existing remote failed. Re-run and choose y to recreate." ;;
  esac
fi

cat <<'MSG'

You need the OAuth credentials from Step 1 of the README:
  Google Cloud Console -> your theduchess.co.za project -> Clients -> Desktop app

Do NOT leave these blank. rclone's built-in shared client ID is being retired
during 2026 and is the most likely reason your sign-in got stuck.

MSG

printf 'Client ID: '
read -r CLIENT_ID
[ -n "$CLIENT_ID" ] || die "Client ID is required."
case "$CLIENT_ID" in
  *.apps.googleusercontent.com) ;;
  *) warn "That does not look like a Google client ID (expected ...apps.googleusercontent.com)." ;;
esac

echo
echo "Client secret (starts GOCSPX-). Nothing will appear as you paste -"
echo "input is hidden on purpose. Paste it and press Return."
printf 'Client secret: '
read -rs CLIENT_SECRET
echo
[ -n "$CLIENT_SECRET" ] || die "Client secret is required - nothing was entered. Re-run this script and paste it at the prompt."
ok "got a secret, ${#CLIENT_SECRET} characters"
case "$CLIENT_SECRET" in
  GOCSPX-*) ;;
  *) warn "That does not start with 'GOCSPX-'. If the sign-in fails, check you pasted the secret and not the client ID." ;;
esac

say "Creating remote '${REMOTE}' with scope '${SCOPE}'"
echo "     A browser window will open. Sign in as johannes@theduchess.co.za."
echo "     If it does not open, see the fallback in the README (Step 3)."
echo

rclone config create "$REMOTE" drive \
  client_id="$CLIENT_ID" \
  client_secret="$CLIENT_SECRET" \
  scope="$SCOPE" \
  || die "Remote creation / authorisation failed. See README Step 1 and Step 3."

say "Verifying"
if rclone about "${REMOTE}:"; then
  ok "authorised - the quota above is the live Drive"
else
  die "Remote created but 'rclone about' failed. The token may not have been granted."
fi

echo
say "Next: ./scripts/02-inventory.sh"
