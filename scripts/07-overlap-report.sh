#!/usr/bin/env bash
# What is already on the disk, and how much of a pending account would be new.
#
#   ./scripts/07-overlap-report.sh                        # what is on disk now
#   ./scripts/07-overlap-report.sh design@theduchess.co.za  # + how much is new
#
# Accounts share folders in Drive, so the same file lands under several people.
# This says how much of an account you would actually be adding before you
# spend hours fetching it.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

CANDIDATE="${1:-}"
IDX="$INVENTORY_DIR/local-index.tsv"
mkdir -p "$INVENTORY_DIR"

need_rclone
[ -d "$BACKUP_DIR/drive" ] || die "No $BACKUP_DIR/drive yet - plug the disk in."

# ---------- index what is already on the disk ----------
if [ "${REFRESH:-0}" = "1" ] || [ ! -s "$IDX" ]; then
  say "Indexing what is already on the disk (walks every file - slow the first time)"
  : > "$IDX"
  for d in "$BACKUP_DIR"/drive/*/; do
    [ -d "$d" ] || continue
    acct="$(basename "$d")"
    printf '     %s ... ' "$acct"
    n=$(rclone lsf "$d" -R --files-only --format "sp" --separator '|' 2>/dev/null \
        | awk -F'|' -v a="$acct" 'NF>=2 {print a"\t"$1"\t"$2}' \
        | tee -a "$IDX" | wc -l | tr -d ' ')
    echo "$n files"
  done
  ok "index written to $IDX"
else
  say "Using cached index ($IDX). REFRESH=1 to rebuild."
fi

echo
say "What is on the disk"
python3 - "$IDX" <<'PY'
import sys, collections
def human(b):
    for u,d in (("TiB",1024**4),("GiB",1024**3),("MiB",1024**2),("KiB",1024)):
        if b >= d: return "%.1f %s" % (b/d, u)
    return "%d B" % b
idx = sys.argv[1]
per = collections.defaultdict(lambda: [0,0])          # acct -> [files, bytes]
seen = collections.defaultdict(set)                    # (name,size) -> accounts
for line in open(idx, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3: continue
    acct, size, path = p[0], p[1], p[2]
    try: size = int(size)
    except ValueError: continue
    per[acct][0] += 1; per[acct][1] += size
    seen[(path.rsplit("/",1)[-1], size)].add(acct)

print(f"     {'account':<34}{'files':>10}{'size':>12}")
print("     " + "-"*56)
tf = tb = 0
for a,(f,b) in sorted(per.items(), key=lambda x:-x[1][1]):
    print(f"     {a:<34}{f:>10,}{human(b):>12}"); tf += f; tb += b
print("     " + "-"*56)
print(f"     {'TOTAL':<34}{tf:>10,}{human(tb):>12}")

dup_files = dup_bytes = 0
for (name,size), accts in seen.items():
    if len(accts) > 1:
        dup_files += len(accts)-1
        dup_bytes += size*(len(accts)-1)
print()
print(f"     Held more than once: {dup_files:,} files, {human(dup_bytes)}")
print(f"     Distinct content:    {human(tb-dup_bytes)} of the {human(tb)} on disk")
PY

# ---------- how much of a candidate account is new? ----------
[ -n "$CANDIDATE" ] || { echo; say "Pass an email to see how much of that account is not already here."; exit 0; }

echo
say "Listing $CANDIDATE in Drive (not downloading anything)"
REM="$INVENTORY_DIR/remote-$(safe_name "$CANDIDATE").tsv"
rclone lsf "${REMOTE}:" -R --files-only --format "sp" --separator '|' \
  --drive-impersonate "$CANDIDATE" --fast-list 2>/dev/null \
  | awk -F'|' 'NF>=2 {print $1"\t"$2}' > "$REM" || die "Could not list $CANDIDATE"
ok "$(wc -l < "$REM" | tr -d ' ') files listed"

echo
say "How much of $CANDIDATE is already on the disk"
python3 - "$IDX" "$REM" "$CANDIDATE" <<'PY'
import sys
def human(b):
    for u,d in (("TiB",1024**4),("GiB",1024**3),("MiB",1024**2),("KiB",1024)):
        if b >= d: return "%.1f %s" % (b/d, u)
    return "%d B" % b
idx, rem, who = sys.argv[1], sys.argv[2], sys.argv[3]
have = set()
for line in open(idx, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 3:
        try: have.add((p[2].rsplit("/",1)[-1], int(p[1])))
        except ValueError: pass

tot = new = 0; totn = newn = 0; gdocs = 0
for line in open(rem, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 2: continue
    try: size = int(p[0])
    except ValueError: continue
    path = p[1]
    if size < 0:                      # Google-native docs report no size
        gdocs += 1; continue
    tot += size; totn += 1
    if (path.rsplit("/",1)[-1], size) not in have:
        new += size; newn += 1

print(f"     {who}")
print(f"       total in Drive : {totn:>8,} files  {human(tot):>12}")
print(f"       already here   : {totn-newn:>8,} files  {human(tot-new):>12}")
print(f"       genuinely new  : {newn:>8,} files  {human(new):>12}")
if gdocs:
    print(f"       plus {gdocs:,} Google-native docs, which report no size and always re-export")
print()
pct = (tot-new)/tot*100 if tot else 0
print(f"     {pct:.0f}% of it is already on the disk under another account.")
print()
print("     Matching is by filename and exact byte size, not content. Two different")
print("     files could collide; treat this as a good estimate, not proof.")
PY
