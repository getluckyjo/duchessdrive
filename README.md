# theduchess.co.za backup → /Volumes/Duchess

Pulls **Drive and Gmail for the 4 active accounts** in the theduchess.co.za
Workspace org onto an external disk. Everything here runs **on your Mac**.

## What is actually being copied

The "621 GB" figure is the whole org across 18 accounts and three domains, and
183 GB of it is Gmail, which rclone cannot touch. The real shape:

| | Drive | Gmail | Total |
|---|---|---|---|
| **4 Active accounts** — this backup | 265.81 GB | 109.55 GB | **375.36 GB** |
| 14 Archived accounts — *not covered* | 171.87 GB | 73.82 GB | 245.69 GB |
| All 18 | 437.68 GB | 183.37 GB | 621.06 GB |

In scope, from `accounts.tsv`:

| Account | Drive | Gmail |
|---|---|---|
| `inus@theduchess.co.za` | 231.08 GB | 44.58 GB |
| `johannes@theduchess.co.za` | 33.03 GB | 50.14 GB |
| `sebastian@drinkdope.com` | 1.47 GB | 5.43 GB |
| `johannes@drinkdope.com` | 0.23 GB | 9.40 GB |

Shared Drives are extra — their content is not counted in any user's storage
figure, so `02-inventory.sh` may turn up data beyond the 375 GB above.

**Not covered: the 14 archived accounts**, including `design@theduchess.co.za`
(135.55 GB of Drive) and `tania@theduchess.co.za` (28.31 GB). Archived users
cannot sign in, so there is no session to impersonate. Getting that data means
re-licensing each account to un-archive it, or exporting through Vault. Decide
that separately — and note the Workspace subscription is already cancelled, so
whatever retention clock applies to it is running.

## The situation this works around

The Workspace subscription for the org is cancelled. What is still billed is an
**Archived User** subscription covering the other 14 accounts — a data-retention
SKU, not a service licence. The four accounts here are Active but unlicensed,
sitting on the 15 GB free tier while holding far more than that.

Google blocks *uploads* when an account is over quota but normally still serves
reads. This whole backup rests on that. `00-check-access.sh` proves it before
you spend a night on a transfer that cannot finish.

---

## Step 1 — Prove reads still work

```bash
./scripts/00-check-access.sh
```

Uses whatever remote you already have. It reads the quota, lists My Drive, and
— the part that matters — downloads one real file.

**Green:** carry on. **Red:** if the errors mention quota, storage, or a
cancelled subscription, rclone cannot help and the data has to come out by
re-subscribing or through Vault. Send me the exact error before doing anything
else.

## Step 2 — Preflight the disk

```bash
./scripts/00-preflight.sh
```

Checks rclone, the mount, free space, filesystem and case sensitivity.

The disk is **exFAT**, which is fine — but it has no journal, so **always eject
properly** (`diskutil eject /Volumes/Duchess`) and never pull the cable
mid-write. An unclean unmount during a multi-hour transfer can cost you the
volume, not just the file in flight.

## Step 3 — Service account + domain-wide delegation

You need `inus@`'s Drive, and you are not going to ask them for a password. As
super admin you can authorise one service account to read every mailbox and
Drive in the org.

**In the Cloud console** (same `duchess-drive-backup` project, signed in as
`johannes@theduchess.co.za`):

1. **APIs & Services → Library** → enable **Google Drive API** *and* **Gmail API**.
2. **IAM & Admin → Service Accounts → Create service account**. Name it
   `duchess-backup`. Skip the optional role and user grants.
3. Open it → **Keys → Add key → Create new key → JSON**. It downloads once.
4. Still on the service account, copy its **Unique ID** — the long *numeric*
   client ID, not the email address.

**In the Admin console** (`admin.google.com`):

5. **Security → Access and data control → API controls → Manage Domain Wide
   Delegation → Add new**.
6. Paste the numeric client ID, and add both scopes, comma-separated:

```
https://www.googleapis.com/auth/drive.readonly,https://www.googleapis.com/auth/gmail.readonly
```

7. **Authorize**.

**On your Mac**, put the key where the scripts expect it:

```bash
mkdir -p ~/.config/duchess-backup
mv ~/Downloads/duchess-backup-*.json ~/.config/duchess-backup/service-account.json
chmod 600 ~/.config/duchess-backup/service-account.json
```

Both scopes are read-only. The service account can copy everything and change
nothing. The key file is a credential that opens every mailbox in the org —
keep it off the backup disk and out of this repo.

```bash
./scripts/01-configure-remote.sh
```

Rebuilds the rclone remote from the key and checks all four accounts. A failure
here is almost always a scope that was not authorised in step 6.

## Step 4 — Inventory

```bash
./scripts/02-inventory.sh
```

Per-account quota, Shared Drives, and a real measurement of each Drive. Review
`inventory/shared-drives.tsv` — delete any line you do not want copied.

## Step 5 — Copy

```bash
./scripts/03-copy-drive.sh     # ~266 GB
./scripts/05a-install-gyb.sh   # once, for the Gmail tool
./scripts/05-copy-gmail.sh     # ~110 GB
```

Both are resumable — Ctrl-C and re-run. Both wrap themselves in `caffeinate`.
**Keep the lid open**; caffeinate cannot stop clamshell sleep.

Lands as:

```
/Volumes/Duchess/theduchess-backup/
  drive/<email>/
  gmail/<email>/
  shared-drives/<name>/
```

Gmail needs **GYB (Got Your Back)** — rclone has no mail backend at all.
`05a-install-gyb.sh` resolves the right release for your Mac and installs it to
`~/.local/bin`, no sudo and nothing piped into a shell. GYB uses the same
service account and writes one `.eml` per message.

Before downloading 110 GB, `05-copy-gmail.sh` runs a one-day estimate against
the first mailbox to prove Gmail delegation actually works. If the Gmail scope
was not authorised, you find out in seconds rather than after a long failure.

At 100 Mbit/s, 375 GB is roughly 9 hours. Assume slower — small files never hit
line rate, and a 231 GB Drive of small files is the slow case.

Knobs:

```bash
TRANSFERS=4 ./scripts/03-copy-drive.sh
BWLIMIT="08:00,2M 18:00,off" ./scripts/03-copy-drive.sh
```

Logs in `~/duchess-backup/logs/`.

### Google Docs, Sheets and Slides

Native Google files have no downloadable bytes; rclone exports them, so a Sheet
becomes an `.xlsx`. Comments and revision history do not survive. If you need
faithful archival copies of the native docs, that is a different job.

## Step 6 — Verify

```bash
./scripts/04-verify.sh
```

MD5-compares every Drive file against the live account (Google-native docs
excluded, since their exported form legitimately differs), and counts the `.eml`
files per mailbox.

---

## Files

| | |
|---|---|
| `accounts.tsv` | Who gets backed up. Delete a line to skip. |
| `scripts/00-check-access.sh` | Proves reads still work. Run first. |
| `scripts/00-preflight.sh` | Disk and tooling checks. |
| `scripts/01-configure-remote.sh` | rclone remote from the service account. |
| `scripts/01a-fix-oauth-secret.sh` | Repairs an OAuth remote's client secret. |
| `scripts/02-inventory.sh` | Sizes, Shared Drives. |
| `scripts/03-copy-drive.sh` | Drive, all accounts. |
| `scripts/05a-install-gyb.sh` | Installs GYB to `~/.local/bin`. Run once. |
| `scripts/05-copy-gmail.sh` | Gmail, all accounts, via GYB. |
| `scripts/04-verify.sh` | MD5 check + message counts. |
| `scripts/06-handoff-copy.sh` | Copy one folder to another drive, to hand over. |
| `scripts/07-overlap-report.sh` | What is on the disk, and how much of an account is new. |

The rclone config lives at `~/.config/rclone/rclone.conf` and the service
account key at `~/.config/duchess-backup/service-account.json`. **Both are
credentials — not in this repo, not on the backup disk.**

---

## Handing a folder to someone on a drive

Disk to disk, no Google involved:

```bash
./scripts/06-handoff-copy.sh /Volumes/TheirDrive
./scripts/06-handoff-copy.sh /Volumes/TheirDrive "The Duchess Sales"
```

Defaults to `1 Suncamino Rum ` from `inus@theduchess.co.za` — note that folder
name genuinely ends in a space.

It refuses a FAT32 destination (4 GB file ceiling), refuses to copy a drive
onto itself, checks free space against the measured source, copies resumably,
then verifies **every file by MD5 on both drives**.

If verification reports differences, read the reason before re-running. Missing
files are fixed by a plain re-run. A file whose contents drifted while its size
and timestamp stayed the same is *not* — `rclone copy` compares size and modtime
and will skip it forever. For that, `REPAIR=1` forces a checksum comparison:

```bash
REPAIR=1 ./scripts/06-handoff-copy.sh /Volumes/TheirDrive
```

Eject before unplugging: `diskutil eject /Volumes/TheirDrive`.

---

## Before adding another account

Accounts share folders in Drive, so the same file lands on the disk under
several people. Before spending hours fetching an account, see how much of it
you would actually be adding:

```bash
./scripts/07-overlap-report.sh                          # what is on the disk now
./scripts/07-overlap-report.sh design@theduchess.co.za  # how much of that is new
```

The first form indexes every file already on the disk and reports per-account
totals, how much is held more than once, and how much distinct content there
really is. The index is cached in `inventory/local-index.tsv`; `REFRESH=1`
rebuilds it after new downloads.

With an email it also lists that account's Drive — listing only, nothing is
downloaded — and reports how much is already present under another account.

Matching is by filename and exact byte size, not by content hash. Two different
files could collide, so treat the figure as a good estimate rather than proof.

### Archived accounts are reachable

Archived users cannot sign in, but domain-wide delegation reaches their Drive
and Gmail regardless. No licence purchase and no Vault export is needed - the
same scripts work by adding a line to `accounts.tsv`. Verified against
`tania@` and `design@`.
