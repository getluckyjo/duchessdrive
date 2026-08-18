#!/usr/bin/env bash
# Points rclone at the service account, then proves it can impersonate every
# account in accounts.tsv. One credential, no per-user sign-in.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

SCOPE="${SCOPE:-drive.readonly}"

need_rclone
need_sa
need_accounts

if rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:"; then
  warn "Remote '${REMOTE}:' already exists (probably the OAuth one from the first attempt)."
  printf 'Replace it with the service account? [y/N] '
  read -r ans
  case "$ans" in
    y|Y) rclone config delete "$REMOTE" ;;
    *)   die "Leaving it alone. Impersonation needs the service account, so nothing further will work until you replace it." ;;
  esac
fi

say "Creating remote '${REMOTE}' from $SA_FILE"
rclone config create "$REMOTE" drive \
  service_account_file="$SA_FILE" \
  scope="$SCOPE" \
  || die "Could not create the remote."
ok "remote created"

echo
say "Checking domain-wide delegation for each account"
echo "     A failure here almost always means the scope is not authorised in"
echo "     Admin console -> Security -> Access and data control -> API controls."
echo

bad=0
check_one() {
  email="$1"; dgb="$2"
  printf '  %-32s ' "$email"
  if out="$(rclone about "${REMOTE}:" --drive-impersonate "$email" 2>&1)"; then
    used="$(printf '%s' "$out" | awk -F': *' '/^Used/ {print $2}')"
    printf '\033[1;32mok\033[0m  %s used (expected ~%s GB of Drive)\n' "${used:-?}" "$dgb"
  else
    printf '\033[1;31mFAILED\033[0m\n'
    printf '%s\n' "$out" | sed 's/^/       /' | head -4
    bad=$((bad+1))
  fi
}
for_each_account check_one

echo
if [ "$bad" -eq 0 ]; then
  say "All accounts reachable. Next: ./scripts/02-inventory.sh"
else
  say "$bad account(s) failed. Fix delegation before copying - see README step 3."
  exit 1
fi
