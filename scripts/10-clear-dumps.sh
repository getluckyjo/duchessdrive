#!/usr/bin/env bash
# Clear the redundant half of the ex-staff Drive dumps.
#
#   ./scripts/10-clear-dumps.sh              # sample 300 pairs and report, delete nothing
#   ./scripts/10-clear-dumps.sh --execute    # verify and delete, one file at a time
#
# When people left, their whole Drive was transferred into a colleague's
# account. Those dumps are 424.9 GiB and about 95% of the content is a second
# copy of a file that also lives in a normal project folder.
#
# The rule this script enforces, and the reason it exists rather than a general
# deduplicator: a file is removed ONLY if an identical copy exists OUTSIDE every
# dump. The surviving copy is therefore always a live project file, never
# another ex-staff dump. Unique files inside a dump are left exactly where they
# are - "clear the redundant part" is not "delete the dumps".
#
# Identical means an MD5 match, checked immediately before the delete. Matching
# on filename and size alone is about 0.7% wrong (measured 2026-08-27), which
# over this many files would destroy a few hundred real documents.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

EXECUTE=0
[ "${1:-}" = "--execute" ] && EXECUTE=1

IDX="$INVENTORY_DIR/local-index.tsv"
WORK="$INVENTORY_DIR/clear-dumps-worklist.tsv"
DRIVE="$BACKUP_DIR/drive"

need_disk
[ -s "$IDX" ] || die "No index at $IDX - run ./scripts/07-overlap-report.sh first."
mkdir -p "$LOG_DIR"

say "Pairing every dump file with a twin outside the dumps"
python3 - "$IDX" <<'PY' > "$WORK"
import sys, collections, re
XFER = re.compile(r'@theduchess\.co\.za|@drinkdope\.com|@drinktheduchess\.com|^Deleted Google Account Transfers$')
def in_dump(path): return bool(XFER.search(path.split("/")[0]))

rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3: continue
    try: s = int(p[1])
    except ValueError: continue
    if s == 0: continue                       # empty files: no space to win, some risk
    rows.append((p[0], s, p[2]))

# Candidate survivors: same basename and size, living outside every dump.
outside = collections.defaultdict(list)
for acct, s, path in rows:
    if not in_dump(path):
        outside[(path.rsplit("/",1)[-1], s)].append((acct, path))

n = 0
for acct, s, path in rows:
    if not in_dump(path): continue
    twins = outside.get((path.rsplit("/",1)[-1], s))
    if not twins: continue                    # unique to the dump - leave it alone
    ta, tp = twins[0]
    print(f"{acct}\t{path}\t{ta}\t{tp}\t{s}")
    n += 1
sys.stderr.write(f"{n} deletable candidate(s)\n")
PY

cand=$(wc -l < "$WORK" | tr -d ' ')
bytes=$(awk -F'\t' '{s+=$5} END {printf "%.1f", s/1073741824}' "$WORK")
ok "$cand candidate(s), ${bytes} GiB, listed in $WORK"

if [ "$EXECUTE" -eq 0 ]; then
  echo
  say "Sampling 300 of them to show the verification working"
  same=0; diff=0; miss=0
  awk 'NR%'"$(( cand/300 + 1 ))"'==0' "$WORK" | head -300 | \
  while IFS=$'\t' read -r da dp ta tp sz; do
    h1=$(md5 -q "$DRIVE/$da/$dp" 2>/dev/null); h2=$(md5 -q "$DRIVE/$ta/$tp" 2>/dev/null)
    if [ -z "$h1" ] || [ -z "$h2" ]; then echo "MISSING"
    elif [ "$h1" = "$h2" ]; then echo "SAME"; else echo "DIFFER"; fi
  done | sort | uniq -c | sed 's/^/     /'
  echo
  say "Nothing deleted. Run:  ./scripts/10-clear-dumps.sh --execute"
  exit 0
fi

# ---------- execute ----------
# Hash and delete in a single pass. Verifying immediately before each delete
# leaves no window in which the surviving copy could change or vanish.
RUN="$(timestamp)"
LOG="$LOG_DIR/clear-dumps-$RUN.log"
say "Verifying and deleting. Full record in $LOG"
warn "exFAT has no undelete. Interrupting is safe - it stops between files."
echo

del=0; freed=0; kept=0; gone=0; i=0
while IFS=$'\t' read -r da dp ta tp sz; do
  i=$((i+1))
  dump="$DRIVE/$da/$dp"; twin="$DRIVE/$ta/$tp"
  if [ ! -f "$dump" ] || [ ! -f "$twin" ]; then
    printf 'MISSING\t%s\n' "$dump" >> "$LOG"; gone=$((gone+1)); continue
  fi
  h1=$(md5 -q "$dump" 2>/dev/null); h2=$(md5 -q "$twin" 2>/dev/null)
  if [ -z "$h1" ] || [ -z "$h2" ] || [ "$h1" != "$h2" ]; then
    printf 'DIFFERS\t%s\n' "$dump" >> "$LOG"; kept=$((kept+1)); continue
  fi
  if rm -f "$dump" 2>>"$LOG"; then
    printf 'DELETED\t%s\tkept\t%s\t%s\n' "$dump" "$twin" "$h1" >> "$LOG"
    del=$((del+1)); freed=$((freed+sz))
  else
    printf 'FAILED\t%s\n' "$dump" >> "$LOG"; kept=$((kept+1))
  fi
  if [ $((i % 250)) -eq 0 ]; then
    printf '\r     %d/%d checked, %d deleted, %.1f GiB freed' \
      "$i" "$cand" "$del" "$(echo "$freed" | awk '{print $1/1073741824}')"
  fi
done < "$WORK"

printf '\r%*s\r' 78 ''
ok "$del deleted, $(echo "$freed" | awk '{printf "%.1f GiB", $1/1073741824}') reclaimed"
[ "$kept" -gt 0 ] && warn "$kept kept - content differed despite matching name and size"
[ "$gone" -gt 0 ] && say  "$gone already absent"
echo
say "Empty directories left behind can be cleared with:"
echo "     find \"$DRIVE\" -type d -empty -delete"
say "The index is now stale. Re-run: REFRESH=1 ./scripts/07-overlap-report.sh"
