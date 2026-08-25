#!/usr/bin/env bash
# List the Google-native documents Drive refused to export (HTTP 403
# "Access Denied"). These are the only files rclone could not fetch, and no
# amount of re-running changes that - they need the owner to lift the
# download restriction, or the owning account to be un-suspended.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh
OUT="$INVENTORY_DIR/export-blocked.tsv"
mkdir -p "$INVENTORY_DIR"
{
  printf 'run_log\tfile\n'
  for f in "$LOG_DIR"/drive-*.log; do
    [ -f "$f" ] || continue
    grep -aE '^[0-9]{4}/[0-9/]+ [0-9:]+ ERROR' "$f" \
      | grep -a 'Failed to copy' \
      | sed 's/.*ERROR : //; s/: Failed to copy.*//' \
      | sort -u \
      | sed "s|^|$(basename "$f")\t|"
  done
} > "$OUT"
n=$(( $(wc -l < "$OUT") - 1 ))
ok "$n blocked file(s) listed in $OUT"
echo "     By account:"
awk -F'\t' 'NR>1{print $1}' "$OUT" | sort | uniq -c | sed 's/^/       /'
