# Duchess Drive → /Volumes/Duchess backup runbook

Pulls the Google Workspace Drive for **johannes@theduchess.co.za** (~621 GB) down to an
external disk mounted at `/Volumes/Duchess`, using rclone.

Everything here runs **on your Mac**. Nothing in this repo runs the transfer for you.

---

## Why your sign-in got stuck

Almost certainly one of these two, and the fix for both is the same:

1. **rclone's shared client ID is being retired and stops working during 2026.**
   rclone ships with a built-in OAuth client that everyone shares. Google is
   retiring it, and it is already failing for many users. If you left
   `client_id` blank during `rclone config`, this is your problem.

2. **Workspace blocks unverified third-party apps.** A Workspace admin can
   restrict which OAuth apps users may authorise (Admin console → Security →
   Access and data control → API controls). rclone is not on the trusted list
   by default, so the sign-in page dead-ends with "Access blocked".

**The fix: create your own OAuth client inside the theduchess.co.za
organisation, as an Internal app.** An Internal app is first-party to your own
Workspace — it is not subject to the third-party app block, needs no Google
verification review, and (importantly) does not expire its refresh token after
7 days the way an External app left in "Testing" does. A 621 GB transfer can
easily run longer than a day, and a token that dies mid-run is miserable.

---

## Step 1 — Create the OAuth client (~10 minutes, browser)

Sign in to <https://console.cloud.google.com/> **as johannes@theduchess.co.za**.
This matters: the Cloud project must belong to the theduchess.co.za
organisation, or the "Internal" option will not be offered.

1. Create a new project (top-left project picker → **New Project**). Name it
   something like `duchess-drive-backup`. Confirm the **Organization** field
   reads `theduchess.co.za` — if it says "No organization", you are signed in
   with the wrong account, or you lack permission to create projects in the org
   (ask a super admin to create it and grant you Editor).
2. **APIs & Services → Library** → search **Google Drive API** → **Enable**.
3. **APIs & Services → OAuth consent screen** (newer consoles call this
   *Google Auth Platform*) → **Get started**.
   - App name: `rclone-duchess-backup`
   - User support email: your address
   - **Audience: Internal** ← this is the important one
   - Contact email, agree, **Create**.
4. **Data access → Add or remove scopes** → add:
   - `https://www.googleapis.com/auth/drive.readonly`

   Read-only is deliberate. You are pulling a backup down; rclone should have
   no ability to modify or delete anything in the live Drive.
5. **Clients → Create client** → Application type: **Desktop app** → **Create**.
6. Copy the **Client ID** and **Client secret**. You will paste them in Step 3.

Because the app is Internal, there is no "Publish app" step and no test-user
list to manage. Skip both.

> If your account cannot create the project or cannot select Internal, you need
> a theduchess.co.za super admin to do Step 1 for you. There is no way around
> it — the alternative (External + Testing) gives you a token that dies after 7
> days, which will strand a transfer this size.

---

## Step 2 — Preflight the disk

```bash
./scripts/00-preflight.sh
```

This checks rclone's version, that `/Volumes/Duchess` is mounted and writable,
how much free space it has, and — the two that actually bite:

- **Filesystem.** If the disk is **FAT32**, stop: no file over 4 GB can be
  written. Reformat as **APFS** (or **exFAT** if the disk must also be readable
  on Windows). Reformatting erases the disk.
- **Case sensitivity.** APFS and HFS+ are case-*insensitive* by default. Google
  Drive is case-*sensitive*, so it can hold `Invoice.pdf` and `invoice.pdf` in
  one folder. On a case-insensitive disk one silently overwrites the other.
  The preflight tells you which you have; the verify step in Step 6 catches any
  collisions that actually occurred.

---

## Step 3 — Configure the rclone remote

```bash
./scripts/01-configure-remote.sh
```

It prompts for the client ID and secret from Step 1, creates a remote called
`duchess` with `drive.readonly` scope, and opens your browser for the Google
sign-in. Sign in as **johannes@theduchess.co.za** and grant access.

If the browser does not open or the page hangs on `127.0.0.1:53682`, re-run
`rclone config` manually and answer **n** to "Use web browser to automatically
authenticate?". rclone then prints an exact `rclone authorize` command to run
on any machine that does have a working browser, and you paste the resulting
token back.

The script finishes by calling `rclone about duchess:` — if that prints your
quota, the auth is genuinely working.

---

## Step 4 — Inventory before you copy

```bash
./scripts/02-inventory.sh
```

Writes `inventory/` with:

- total quota and usage (`rclone about`)
- top-level folders in My Drive
- **every Shared Drive** the account can see, into `inventory/shared-drives.tsv`

This step exists because "621 GB" is probably the org's total. My Drive and
each Shared Drive are separate roots in the Drive API — a plain `rclone copy
duchess:` gets **My Drive only** and will silently miss every Shared Drive.
Check the TSV before you start, and delete any line you do not want copied.

`rclone size duchess: --fast-list` is also run; on a Drive this large it can
take 10–30 minutes, so it is the last thing the script does and you can Ctrl-C
it once you have seen the rest.

---

## Step 5 — Run the transfer

```bash
./scripts/03-copy.sh
```

Copies, in order:

| Source | Lands in |
|---|---|
| My Drive | `/Volumes/Duchess/theduchess-backup/my-drive/` |
| each Shared Drive in the TSV | `/Volumes/Duchess/theduchess-backup/shared-drives/<name>/` |
| Shared with me *(only if `INCLUDE_SHARED_WITH_ME=1`)* | `/Volumes/Duchess/theduchess-backup/shared-with-me/` |

It wraps the run in `caffeinate` so the Mac will not idle-sleep mid-transfer.

**Keep the laptop lid open.** `caffeinate` cannot stop clamshell sleep — closing
the lid on battery or without an external display will suspend the machine and
stall the transfer. It will resume when you wake it, but it is cleaner not to.

**How long.** 621 GB, roughly:

| Your download speed | Wall clock |
|---|---|
| 50 Mbit/s | ~28 hours |
| 100 Mbit/s | ~14 hours |
| 200 Mbit/s | ~7 hours |
| 500 Mbit/s | ~3 hours |

Assume slower — many small files transfer well below line rate.

**It is safe to interrupt.** Ctrl-C, then re-run the same script. `rclone copy`
skips files already present with matching size and modtime, so a restart picks
up where it left off. Nothing on the Google side is ever modified (read-only
scope).

Useful knobs, all environment variables:

```bash
TRANSFERS=4 ./scripts/03-copy.sh          # gentler on a spinning USB disk
BWLIMIT="08:00,2M 18:00,off" ./scripts/03-copy.sh   # throttle during work hours
INCLUDE_SHARED_WITH_ME=1 ./scripts/03-copy.sh
```

Logs go to `~/duchess-backup/logs/`.

### About Google Docs, Sheets and Slides

Native Google files have no downloadable bytes — rclone exports them. This
runbook uses the default `docx,xlsx,pptx,svg`. So a Google Sheet becomes an
`.xlsx`. These exports are conversions, not fidelity-perfect copies: comments,
revision history, and some formatting do not survive. If you need true
archival copies of the native docs, that is a separate job (Google Takeout
preserves more), and worth flagging before you rely on this backup for them.

### Files Google refuses to serve

Some files (often `.exe`, `.apk`, archives) return `cannotDownloadAbusiveFile`.
The scripts pass `--drive-acknowledge-abuse` to download them anyway. Note that
some rclone builds only honour this with the full `drive` scope rather than
`drive.readonly`; if you still see those errors in the log, that is the reason,
and the fix is to re-run `01-configure-remote.sh` with `SCOPE=drive`.

---

## Step 6 — Verify

```bash
./scripts/04-verify.sh
```

Runs `rclone check --one-way`, which compares **MD5 hashes** of every file on
both sides — a real integrity check, not just a file count. Google-native docs
are excluded (`--drive-skip-gdocs`) because their exported form legitimately
has a different hash than the source.

Read the summary at the end of `~/duchess-backup/logs/verify-*.log`. Zero
differences means the backup is byte-for-byte good. Any listed differences are
worth investigating before you trust the disk — case-collisions from Step 2
show up here.

---

## Quick reference

```bash
rclone about duchess:                       # quota / usage
rclone backend drives duchess:              # list Shared Drives
rclone size duchess: --fast-list            # measure My Drive
rclone ls duchess: --max-depth 1            # peek
rclone config file                          # where the config lives
```

The rclone config (including your OAuth token) lives at
`~/.config/rclone/rclone.conf`. **It is a credential — do not commit it to this
repo or copy it to the backup disk.**
