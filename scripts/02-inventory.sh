#!/usr/bin/env bash
# Works out what is actually in the account before you copy 621 GB of it.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

need_rclone
need_remote
mkdir -p "$INVENTORY_DIR"

TSV="$INVENTORY_DIR/shared-drives.tsv"

say "Quota"
rclone about "${REMOTE}:" | tee "$INVENTORY_DIR/about.txt"

echo
say "Top-level folders in My Drive"
rclone lsd "${REMOTE}:" 2>/dev/null | tee "$INVENTORY_DIR/my-drive-top-level.txt"

echo
say "Shared Drives visible to this account"
raw="$INVENTORY_DIR/shared-drives.json"
if rclone backend drives "${REMOTE}:" > "$raw" 2>"$INVENTORY_DIR/shared-drives.err"; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$raw" "$TSV" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    drives = json.load(open(src))
except Exception as e:
    print("could not parse rclone output: %s" % e, file=sys.stderr)
    sys.exit(1)
if isinstance(drives, dict):
    drives = drives.get("drives", [])
with open(dst, "w") as fh:
    fh.write("# id\tname   -- delete any line you do NOT want copied\n")
    for d in drives:
        fh.write("%s\t%s\n" % (d.get("id", ""), d.get("name", "")))
print("%d Shared Drive(s)" % len(drives))
for d in drives:
    print("  - %s" % d.get("name", "?"))
PY
    ok "written to $TSV"
  else
    warn "python3 not found - cannot build the TSV automatically."
    warn "Open $raw and create $TSV by hand, one 'id<TAB>name' per line."
  fi
else
  warn "Could not list Shared Drives. Either there are none, or the scope does not permit it."
  cat "$INVENTORY_DIR/shared-drives.err" >&2
  : > "$TSV"
fi

echo
say "Sizing My Drive (rclone size --fast-list)"
echo "     This can take 10-30 minutes on a Drive this large."
echo "     Ctrl-C is safe - everything above is already saved to $INVENTORY_DIR/"
echo
rclone size "${REMOTE}:" --fast-list | tee "$INVENTORY_DIR/my-drive-size.txt"

echo
say "Review $TSV, then run: ./scripts/03-copy.sh"
