#!/usr/bin/env bash
# Find files held under more than one account and, optionally, delete the extra
# copies. Reports by default - it deletes nothing unless you pass --execute.
#
#   ./scripts/09-dedupe.sh              # hash, verify, write a plan, delete nothing
#   ./scripts/09-dedupe.sh --execute    # carry out the plan written by the run above
#
# Why the hashing: 07-overlap-report.sh matches on filename plus byte size,
# which is fine for an estimate but wrong for deleting. A 150-pair sample on
# 2026-08-27 found 1 pair that matched on name and size while differing in
# content - about 0.7%, or roughly 370 files across the whole disk. So every
# copy is hashed and only hash-identical files are ever removed.
#
# exFAT has no hardlinks, so there is no free way to keep two paths pointing at
# one blob: a copy is either kept or genuinely deleted.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

EXECUTE=0
[ "${1:-}" = "--execute" ] && EXECUTE=1

IDX="$INVENTORY_DIR/local-index.tsv"
HASHES="$INVENTORY_DIR/hashes.tsv"
PLAN="$INVENTORY_DIR/dedupe-plan.tsv"
DRIVE="$BACKUP_DIR/drive"

# Which copy survives. The first account listed that holds a given file keeps
# it; every other copy is a deletion candidate. Override with KEEP_ORDER.
KEEP_ORDER="${KEEP_ORDER:-inus@theduchess.co.za,johannes@theduchess.co.za,tania@theduchess.co.za}"

need_disk
[ -s "$IDX" ] || die "No index at $IDX - run ./scripts/07-overlap-report.sh first."

mkdir -p "$LOG_DIR"

# ---------- 1. hash every file that has a same-name same-size twin ----------
# Only those files are candidates, so this hashes a fraction of the disk. The
# results are cached: interrupt it and re-run, and it picks up where it left off.
say "Working out which files need hashing"
python3 - "$IDX" "$HASHES" <<'PY' > "$INVENTORY_DIR/to-hash.tsv"
import sys, collections, os
idx, hashes = sys.argv[1], sys.argv[2]
by_key = collections.defaultdict(list)
for line in open(idx, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3: continue
    try: s = int(p[1])
    except ValueError: continue
    if s == 0: continue                      # empty files are not worth the risk
    by_key[(p[2].rsplit("/",1)[-1], s)].append((p[0], p[2]))

done = set()
if os.path.exists(hashes):
    for line in open(hashes, encoding="utf-8", errors="replace"):
        q = line.rstrip("\n").split("\t")
        if len(q) >= 3: done.add((q[0], q[1]))

n = 0
for k, v in by_key.items():
    if len({a for a, _ in v}) < 2:           # only spans of 2+ accounts matter
        continue
    for acct, path in v:
        if (acct, path) not in done:
            print(f"{acct}\t{path}")
            n += 1
sys.stderr.write(f"{n} file(s) still to hash\n")
PY
todo=$(wc -l < "$INVENTORY_DIR/to-hash.tsv" | tr -d ' ')
ok "$todo file(s) to hash"

if [ "$todo" -gt 0 ]; then
  say "Hashing (safe to interrupt - progress is cached in $HASHES)"
  i=0
  while IFS=$'\t' read -r acct path; do
    h=$(md5 -q "$DRIVE/$acct/$path" 2>/dev/null)
    [ -n "$h" ] && printf '%s\t%s\t%s\n' "$acct" "$path" "$h" >> "$HASHES"
    i=$((i+1))
    [ $((i % 500)) -eq 0 ] && printf '\r     %d/%d' "$i" "$todo"
  done < "$INVENTORY_DIR/to-hash.tsv"
  printf '\r     %d/%d\n' "$i" "$todo"
fi
ok "hashes in $HASHES"

# ---------- 2. build the plan ----------
echo
say "Building the plan"
python3 - "$IDX" "$HASHES" "$PLAN" "$KEEP_ORDER" <<'PY'
import sys, collections
idx, hashes, plan, order = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(",")
def human(b):
    for u,d in (("TiB",1024**4),("GiB",1024**3),("MiB",1024**2),("KiB",1024)):
        if b >= d: return "%.1f %s" % (b/d,u)
    return "%d B" % b

size = {}
for line in open(idx, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 3:
        try: size[(p[0], p[2])] = int(p[1])
        except ValueError: pass

by_hash = collections.defaultdict(list)
for line in open(hashes, encoding="utf-8", errors="replace"):
    q = line.rstrip("\n").split("\t")
    if len(q) >= 3: by_hash[q[2]].append((q[0], q[1]))

rank = {a: i for i, a in enumerate(order)}
def key(e): return (rank.get(e[0], len(order)), e[0], e[1])

kept = freed = 0
rows = []
for h, entries in by_hash.items():
    if len({a for a, _ in entries}) < 2:      # same file twice inside one account
        continue                              # is not what this is for - leave it
    entries.sort(key=key)
    keep = entries[0]
    for e in entries[1:]:
        s = size.get(e, 0)
        rows.append((keep[0], keep[1], e[0], e[1], s, h))
        freed += s
    kept += 1

with open(plan, "w", encoding="utf-8") as f:
    f.write("keep_account\tkeep_path\tdrop_account\tdrop_path\tbytes\tmd5\n")
    for r in rows:
        f.write("\t".join(str(x) for x in r) + "\n")

print(f"     {len(rows):,} copies can go, across {kept:,} distinct files")
print(f"     space reclaimed: {human(freed)}")
print()
per = collections.Counter()
perb = collections.Counter()
for r in rows:
    per[r[2]] += 1; perb[r[2]] += r[4]
print(f"     {'deletions would fall on':<34}{'files':>10}{'size':>12}")
print("     " + "-"*56)
for a, n in per.most_common():
    print(f"     {a:<34}{n:>10,}{human(perb[a]):>12}")
PY

echo
if [ "$EXECUTE" -eq 0 ]; then
  say "Nothing was deleted. The plan is in $PLAN"
  say "Read it, then run:  ./scripts/09-dedupe.sh --execute"
  exit 0
fi

# ---------- 3. execute ----------
RUN="$(timestamp)"
LOG="$LOG_DIR/dedupe-$RUN.log"
say "Deleting. Every removal is logged to $LOG"
warn "This cannot be undone - exFAT has no journal and no undelete."
echo

deleted=0; freed=0; skipped=0
while IFS=$'\t' read -r ka kp da dp bytes md5; do
  [ "$ka" = "keep_account" ] && continue
  keep="$DRIVE/$ka/$kp"; drop="$DRIVE/$da/$dp"
  # Re-check both files at the moment of deletion. The plan may be hours old,
  # and nothing is removed unless its twin is still there and still identical.
  if [ ! -f "$keep" ] || [ ! -f "$drop" ]; then
    echo "SKIP missing: $drop" >> "$LOG"; skipped=$((skipped+1)); continue
  fi
  hk=$(md5 -q "$keep" 2>/dev/null); hd=$(md5 -q "$drop" 2>/dev/null)
  if [ -z "$hk" ] || [ "$hk" != "$md5" ] || [ "$hd" != "$md5" ]; then
    echo "SKIP changed: $drop" >> "$LOG"; skipped=$((skipped+1)); continue
  fi
  if rm -f "$drop" 2>>"$LOG"; then
    echo "DELETED $drop (kept $keep)" >> "$LOG"
    deleted=$((deleted+1)); freed=$((freed+bytes))
  else
    skipped=$((skipped+1))
  fi
  [ $((deleted % 500)) -eq 0 ] && [ "$deleted" -gt 0 ] && printf '\r     %d deleted' "$deleted"
done < "$PLAN"

printf '\r'
ok "$deleted file(s) deleted, $(echo "$freed" | awk '{printf "%.1f GiB", $1/1073741824}') reclaimed"
[ "$skipped" -gt 0 ] && warn "$skipped skipped (missing or changed since the plan) - see $LOG"
say "The on-disk index is now stale. Re-run 07-overlap-report.sh with REFRESH=1."
