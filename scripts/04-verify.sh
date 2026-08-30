#!/usr/bin/env bash
# Integrity check for the archive on the disk, against a manifest that lives on
# the disk beside it. No Google account is involved.
#
#   ./scripts/04-verify.sh --build    # record what is here now
#   ./scripts/04-verify.sh            # re-hash everything and compare
#   ./scripts/04-verify.sh --quick    # size and mtime only; minutes, not hours
#
# Why this replaced the old comparison against the live accounts:
#
# This disk used to be a mirror. `rclone check --one-way` from each account was
# the right test, because every file upstream was supposed to be here. After
# 10-clear-dumps.sh and 09-dedupe.sh that stopped being true - a file shared by
# three accounts upstream exists once here, on purpose - so the old check
# reported tens of thousands of deliberate reclamations as missing files, and
# the obvious cure (re-running 03-copy-drive.sh) would have undone the cleanup.
#
# It also assumed a Workspace org that will not be there much longer. The
# subscription is cancelled. A check that needs Google to answer is a check
# that expires; this one does not. What it can no longer tell you is whether
# the archive matches the accounts - that question is retired along with them.
#
# What it catches instead is the thing that actually threatens an archive on an
# external disk: bit rot, a bad cable, a truncated file, an interrupted write,
# a deletion nobody meant.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

MODE=check
QUICK=0
for a in "$@"; do
  case "$a" in
    --build) MODE=build ;;
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "Unknown argument: $a  (expected --build or --quick)" ;;
  esac
done

need_disk
MANIFEST="$BACKUP_DIR/MANIFEST.tsv"
mkdir -p "$LOG_DIR"
RUN="$(timestamp)"
LOG="$LOG_DIR/verify-$RUN.log"

[ "$MODE" = check ] && [ ! -s "$MANIFEST" ] && \
  die "No manifest at $MANIFEST - run ./scripts/04-verify.sh --build first."

say "Run $RUN   log: $LOG"
say "Archive: $BACKUP_DIR"
say "Manifest: $MANIFEST"
[ "$MODE" = build ] && say "Mode: build (recording what is on the disk now)"
[ "$MODE" = check ] && [ "$QUICK" = 1 ] && say "Mode: quick check (size and mtime only)"
[ "$MODE" = check ] && [ "$QUICK" = 0 ] && say "Mode: full check (re-hashing every file)"
echo

python3 - "$BACKUP_DIR" "$MANIFEST" "$MODE" "$QUICK" "$LOG" <<'PY'
import sys, os, hashlib, time, tempfile

root, manifest, mode, quick, logpath = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5]
PARTIAL = manifest + ".partial"
SIDECAR = manifest + ".md5"
# The manifest and its own sidecar are not part of the archive they describe.
_mb = os.path.basename(manifest)
SKIP_SELF = {_mb, _mb + ".partial", _mb + ".md5"}

# macOS and Spotlight write these constantly. Including them means a clean disk
# reports as changed, which trains you to ignore the output - the one thing an
# integrity check must never do.
SKIP_NAMES = {".DS_Store", ".localized"}
SKIP_DIRS  = {".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", "System Volume Information"}

def human(b):
    for u, d in (("TiB", 1024**4), ("GiB", 1024**3), ("MiB", 1024**2), ("KiB", 1024)):
        if b >= d: return "%.1f %s" % (b / d, u)
    return "%d B" % b

def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(1024 * 1024)
            if not b: break
            h.update(b)
    return h.hexdigest()

def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn in SKIP_NAMES or fn.startswith("._"): continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if rel in SKIP_SELF: continue
            # A tab or newline in a name would corrupt the manifest. None have
            # been seen here, but say so rather than write a broken line.
            if "\t" in rel or "\n" in rel:
                sys.stderr.write("  !! skipping unrepresentable path: %r\n" % rel)
                continue
            yield rel, full

def load(path):
    out = {}
    if not os.path.exists(path): return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("#"): continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 4: continue
            try: out[p[3]] = (p[0], int(p[1]), int(p[2]))
            except ValueError: pass
    return out

log = open(logpath, "a", encoding="utf-8")
t0 = time.time()

print("     walking the archive")
files = sorted(walk(root))
total_bytes = 0
stats = {}
for rel, full in files:
    try:
        st = os.stat(full)
        stats[rel] = (st.st_size, int(st.st_mtime))
        total_bytes += st.st_size
    except OSError as e:
        sys.stderr.write("  !! cannot stat %s: %s\n" % (rel, e))
print("     %s files, %s" % (format(len(files), ","), human(total_bytes)))
print()

# ---------------------------------------------------------------- build
if mode == "build":
    # Resumable: a previous interrupted build keeps its hashes, and any file
    # whose size and mtime still match is not hashed twice.
    done = load(PARTIAL)
    reuse = {r: v for r, v in done.items()
             if r in stats and v[1] == stats[r][0] and v[2] == stats[r][1]}
    todo = [(r, f) for r, f in files if r not in reuse]
    if reuse:
        print("     resuming: %s already hashed, %s to go"
              % (format(len(reuse), ","), format(len(todo), ",")))

    out = open(PARTIAL, "a", encoding="utf-8")
    n = 0; hashed_bytes = 0
    for rel, full in todo:
        try:
            h = md5(full)
        except OSError as e:
            sys.stderr.write("  !! cannot read %s: %s\n" % (rel, e))
            log.write("UNREADABLE\t%s\t%s\n" % (rel, e))
            continue
        sz, mt = stats[rel]
        out.write("%s\t%d\t%d\t%s\n" % (h, sz, mt, rel))
        n += 1; hashed_bytes += sz
        if n % 500 == 0:
            out.flush()
            el = time.time() - t0
            rate = hashed_bytes / el if el else 0
            sys.stdout.write("\r     %s/%s hashed, %s, %s/s   "
                             % (format(n, ","), format(len(todo), ","),
                                human(hashed_bytes), human(rate)))
            sys.stdout.flush()
    out.close()
    sys.stdout.write("\r" + " " * 78 + "\r")

    entries = load(PARTIAL)
    entries = {r: v for r, v in entries.items() if r in stats}
    tmp = tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(manifest),
                                      encoding="utf-8")
    tmp.write("# theduchess archive manifest\n")
    tmp.write("# built %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))
    tmp.write("# %d files, %d bytes\n" % (len(entries), sum(v[1] for v in entries.values())))
    tmp.write("# md5\tsize\tmtime\tpath\n")
    for rel in sorted(entries):
        h, sz, mt = entries[rel]
        tmp.write("%s\t%d\t%d\t%s\n" % (h, sz, mt, rel))
    tmp.close()
    os.replace(tmp.name, manifest)
    try: os.unlink(PARTIAL)
    except OSError: pass

    with open(SIDECAR, "w", encoding="utf-8") as f:
        f.write("%s  %s\n" % (md5(manifest), _mb))

    print("     recorded %s files, %s" % (format(len(entries), ","),
                                          human(sum(v[1] for v in entries.values()))))
    print("     manifest checksum in %s" % os.path.basename(SIDECAR))
    sys.exit(0)

# ---------------------------------------------------------------- check
# The manifest is the thing being trusted, so check it has not itself rotted.
sidecar = SIDECAR
if os.path.exists(sidecar):
    want = open(sidecar, encoding="utf-8").read().split()[0]
    got = md5(manifest)
    if want != got:
        print("  !! MANIFEST ITSELF HAS CHANGED since it was built.")
        print("     recorded %s, found %s" % (want, got))
        print("     Either it was rebuilt without updating MANIFEST.md5, or it is damaged.")
        print()
        log.write("MANIFEST-MISMATCH\t%s\t%s\n" % (want, got))
    else:
        print("     manifest checksum OK")
else:
    print("  !! no %s sidecar - manifest integrity not verified" % os.path.basename(SIDECAR))
print()

recorded = load(manifest)
on_disk = set(stats)
missing = sorted(set(recorded) - on_disk)
added   = sorted(on_disk - set(recorded))
shared  = sorted(set(recorded) & on_disk)

changed = []; unreadable = []
if quick:
    for rel in shared:
        h, sz, mt = recorded[rel]
        dsz, dmt = stats[rel]
        # exFAT stores mtime to 2-second granularity.
        if sz != dsz or abs(mt - dmt) > 2:
            changed.append(rel)
else:
    n = 0; done_bytes = 0
    tb = sum(stats[r][0] for r in shared)
    for rel in shared:
        h, sz, mt = recorded[rel]
        try:
            got = md5(os.path.join(root, rel))
        except OSError as e:
            unreadable.append(rel); log.write("UNREADABLE\t%s\t%s\n" % (rel, e)); continue
        if got != h:
            changed.append(rel)
            log.write("CHANGED\t%s\trecorded %s\tfound %s\n" % (rel, h, got))
        n += 1; done_bytes += stats[rel][0]
        if n % 500 == 0:
            el = time.time() - t0
            rate = done_bytes / el if el else 0
            sys.stdout.write("\r     %s/%s checked, %s, %s/s   "
                             % (format(n, ","), format(len(shared), ","),
                                human(done_bytes), human(rate)))
            sys.stdout.flush()
    sys.stdout.write("\r" + " " * 78 + "\r")

for rel in missing: log.write("MISSING\t%s\n" % rel)
for rel in added:   log.write("NEW\t%s\n" % rel)
if quick:
    for rel in changed: log.write("CHANGED-QUICK\t%s\n" % rel)

print("     %-28s %s" % ("verified unchanged", format(len(shared) - len(changed) - len(unreadable), ",")))
print("     %-28s %s" % ("changed", format(len(changed), ",")))
print("     %-28s %s" % ("missing (gone from disk)", format(len(missing), ",")))
print("     %-28s %s" % ("new (not in manifest)", format(len(added), ",")))
if unreadable:
    print("     %-28s %s" % ("unreadable", format(len(unreadable), ",")))
print()

def preview(label, rows):
    if not rows: return
    print("     %s:" % label)
    for r in rows[:10]: print("       %s" % r)
    if len(rows) > 10: print("       ... %s more, full list in the log" % format(len(rows) - 10, ","))
    print()

preview("changed", changed)
preview("missing", missing)
preview("new", added)

bad = len(changed) + len(missing) + len(unreadable)
if bad == 0 and not added:
    print("     Archive matches the manifest.")
elif bad == 0:
    print("     No damage. Files have been added since the manifest was built -")
    print("     re-run with --build to record them.")
else:
    print("     Damage or drift detected. Read %s." % logpath)
    print("     'changed' on a read-only archive means corruption, not an edit.")
sys.exit(1 if bad else 0)
PY
rc=$?
echo
if [ "$rc" -eq 0 ]; then ok "verify finished clean"; else warn "verify reported problems - see $LOG"; fi
exit "$rc"
