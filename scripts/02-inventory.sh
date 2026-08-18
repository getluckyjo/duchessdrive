#!/usr/bin/env bash
# Measures what is actually there, per account, before moving 375 GB.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

need_rclone; need_remote; need_accounts
# Impersonation requires a service account; a plain OAuth remote can only see
# the account that signed in.
if rclone config show "$REMOTE" 2>/dev/null | grep -q '^service_account_file'; then
  MODE=delegated
else
  MODE=self
  SELF_EMAIL="${SELF_EMAIL:-johannes@theduchess.co.za}"
fi

mkdir -p "$INVENTORY_DIR"

TSV="$INVENTORY_DIR/shared-drives.tsv"

say "Per-account quota"
report_one() {
  email="$1"
  echo
  echo "--- $email ---"
  if [ "$MODE" = delegated ]; then
    rclone about "${REMOTE}:" --drive-impersonate "$email" 2>&1 | sed 's/^/    /'
  else
    rclone about "${REMOTE}:" 2>&1 | sed 's/^/    /'
  fi
}
if [ "$MODE" = delegated ]; then
  for_each_account report_one | tee "$INVENTORY_DIR/about.txt"
else
  warn "OAuth remote - reporting only $SELF_EMAIL"
  report_one "$SELF_EMAIL" | tee "$INVENTORY_DIR/about.txt"
fi

echo
say "Shared Drives"
echo "     Shared Drive content is NOT counted in any user's storage figure, so"
echo "     anything here is data over and above the 375 GB we already know about."
raw="$INVENTORY_DIR/shared-drives.json"
ADMIN="$(awk -F'\t' '!/^#/ && $1 != "" {print $1; exit}' "$ACCOUNTS")"
[ "$MODE" = delegated ] || ADMIN=""
if { [ -n "$ADMIN" ] && rclone backend drives "${REMOTE}:" --drive-impersonate "$ADMIN" \
      || [ -z "$ADMIN" ] && rclone backend drives "${REMOTE}:"; } > "$raw" 2>"$INVENTORY_DIR/shared-drives.err"; then
  python3 - "$raw" "$TSV" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    drives = json.load(open(src))
except Exception as e:
    print("could not parse rclone output: %s" % e, file=sys.stderr); sys.exit(1)
if isinstance(drives, dict): drives = drives.get("drives", [])
with open(dst, "w") as fh:
    fh.write("# id\tname   -- delete any line you do NOT want copied\n")
    for d in drives:
        fh.write("%s\t%s\n" % (d.get("id",""), d.get("name","")))
print("  %d Shared Drive(s)" % len(drives))
for d in drives: print("    - %s" % d.get("name","?"))
PY
else
  warn "Could not list Shared Drives (there may simply be none)."
  cat "$INVENTORY_DIR/shared-drives.err" >&2
  : > "$TSV"
fi

echo
say "Measuring each Drive (rclone size --fast-list)"
echo "     inus@ is 231 GB, so this takes a while. Ctrl-C is safe - everything"
echo "     above is already written to $INVENTORY_DIR/"
echo
size_one() {
  email="$1"
  echo "--- $email ---"
  if [ "$MODE" = delegated ]; then
    rclone size "${REMOTE}:" --drive-impersonate "$email" --fast-list 2>&1 | sed 's/^/    /'
  else
    rclone size "${REMOTE}:" --fast-list 2>&1 | sed 's/^/    /'
  fi
}
if [ "$MODE" = delegated ]; then
  for_each_account size_one | tee "$INVENTORY_DIR/sizes.txt"
else
  size_one "$SELF_EMAIL" | tee "$INVENTORY_DIR/sizes.txt"
fi

echo
say "Next: ./scripts/03-copy-drive.sh"
