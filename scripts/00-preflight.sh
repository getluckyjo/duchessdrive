#!/usr/bin/env bash
# Checks the Mac and the external disk are ready before configuring or copying.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

REQUIRED_GB="${REQUIRED_GB:-621}"
problems=0

say "rclone"
if ! command -v rclone >/dev/null 2>&1; then
  die "rclone not installed. Run: brew install rclone"
fi
ver="$(rclone version 2>/dev/null | head -1 | awk '{print $2}')"
ok "$(rclone version | head -1)"
maj="$(printf '%s' "$ver" | sed 's/^v//' | cut -d. -f1)"
min="$(printf '%s' "$ver" | sed 's/^v//' | cut -d. -f2)"
if [ "${maj:-0}" -eq 1 ] && [ "${min:-0}" -lt 60 ]; then
  warn "rclone $ver is old; these scripts assume >= 1.60. Run: brew upgrade rclone"
  problems=$((problems+1))
fi

say "External disk at $DEST_ROOT"
if [ ! -d "$DEST_ROOT" ]; then
  die "$DEST_ROOT is not mounted. Plug the disk in and re-run."
fi
if mount | grep -q " on $DEST_ROOT "; then
  ok "mounted"
else
  warn "$DEST_ROOT is a plain folder, not a mount point. Wrong disk, or it failed to mount."
  problems=$((problems+1))
fi

say "Filesystem"
fs="$(diskutil info "$DEST_ROOT" 2>/dev/null | awk -F: '/File System Personality/ {sub(/^[ \t]+/,"",$2); print $2}')"
fs="${fs:-unknown}"
echo "     $fs"
case "$fs" in
  *APFS*|*HFS*)
    ok "fine for a 621 GB backup" ;;
  *ExFAT*|*exFAT*)
    warn "exFAT: works, but no symlinks and no POSIX permissions. Acceptable for a backup." ;;
  *FAT32*|*MS-DOS*)
    warn "FAT32/MS-DOS: STOP. Files over 4 GB cannot be written. Reformat as APFS (erases the disk)."
    problems=$((problems+1)) ;;
  *)
    warn "Could not determine the filesystem. Check manually: diskutil info $DEST_ROOT" ;;
esac

say "Free space"
avail_gb="$(df -g "$DEST_ROOT" 2>/dev/null | tail -1 | awk '{print $4}')"
if [ -n "${avail_gb:-}" ]; then
  echo "     ${avail_gb} GB available, ${REQUIRED_GB} GB needed"
  if [ "$avail_gb" -lt "$REQUIRED_GB" ]; then
    warn "Not enough space for the full copy."
    problems=$((problems+1))
  elif [ "$avail_gb" -lt $((REQUIRED_GB + 50)) ]; then
    warn "Very little headroom. Google Docs exports and metadata add to the total."
  else
    ok "enough space"
  fi
else
  warn "Could not read free space."
fi

say "Writable"
probe="$DEST_ROOT/.duchess-preflight.$$"
if mkdir -p "$probe" 2>/dev/null; then
  ok "writable"
else
  die "Cannot write to $DEST_ROOT (read-only mount, or permissions)."
fi

say "Case sensitivity"
: > "$probe/CaseTest" 2>/dev/null
if [ -e "$probe/casetest" ]; then
  warn "Case-INSENSITIVE. Google Drive is case-sensitive, so 'Invoice.pdf' and"
  warn "'invoice.pdf' in one Drive folder would collide here and one would win."
  warn "Usually harmless, but scripts/04-verify.sh will surface any real collisions."
else
  ok "case-sensitive"
fi
rm -rf "$probe"

say "Google reachable"
if curl -sS -o /dev/null -m 15 -w '%{http_code}' https://www.googleapis.com/discovery/v1/apis 2>/dev/null | grep -q '^2'; then
  ok "googleapis.com reachable"
else
  warn "Could not reach googleapis.com. Check your network before starting a long transfer."
fi

echo
if [ "$problems" -eq 0 ]; then
  say "Preflight clean. Next: ./scripts/01-configure-remote.sh"
else
  say "Preflight finished with $problems issue(s) above. Resolve them before copying."
  exit 1
fi
