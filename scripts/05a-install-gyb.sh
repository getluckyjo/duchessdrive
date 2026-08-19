#!/usr/bin/env bash
# Installs GYB (Got Your Back) to ~/.local/bin. rclone has no mail backend,
# so this is what actually moves Gmail.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/common.sh

PREFIX="${PREFIX:-$HOME/.local}"
API="https://api.github.com/repos/GAM-team/got-your-back/releases/latest"

if command -v gyb >/dev/null 2>&1; then
  ok "gyb already on PATH: $(command -v gyb)"
  gyb --version 2>&1 | head -2
  exit 0
fi

case "$(uname -s)" in
  Darwin) os_pat='macos|darwin' ;;
  Linux)  os_pat='linux' ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch_pat='arm64|aarch64' ;;
  x86_64|amd64)  arch_pat='x86_64|amd64' ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

say "Finding the latest release for $(uname -s) $(uname -m)"
meta="$(mktemp)"
curl -fsSL -m 60 "$API" -o "$meta" || die "Could not reach the GitHub releases API."

read -r TAG URL NAME <<EOT
$(python3 - "$meta" "$os_pat" "$arch_pat" <<'PY'
import json, re, sys
meta, os_pat, arch_pat = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(meta))
assets = d.get("assets", [])
hit = [a for a in assets
       if re.search(os_pat, a["name"], re.I) and re.search(arch_pat, a["name"], re.I)]
if not hit:
    print("NONE NONE NONE")
    sys.stderr.write("No asset matched. Available:\n")
    for a in assets:
        sys.stderr.write("  %s\n" % a["name"])
else:
    a = sorted(hit, key=lambda x: len(x["name"]))[0]
    print("%s %s %s" % (d.get("tag_name", "?"), a["browser_download_url"], a["name"]))
PY
)
EOT
rm -f "$meta"
[ "${URL:-NONE}" != "NONE" ] || die "Could not pick a release asset - see the list above and install manually from https://github.com/GAM-team/got-your-back/releases"

ok "$TAG  ->  $NAME"

work="$(mktemp -d)"
say "Downloading"
curl -fL -m 900 --progress-bar "$URL" -o "$work/gyb.tar.xz" || die "Download failed."

say "Extracting"
tar -xJf "$work/gyb.tar.xz" -C "$work" || die "Could not extract the archive."

bin="$(find "$work" -type f -name gyb -perm -u+x 2>/dev/null | head -1)"
[ -n "$bin" ] || bin="$(find "$work" -type f -name gyb 2>/dev/null | head -1)"
[ -n "$bin" ] || die "No 'gyb' binary inside the archive."

payload="$(dirname "$bin")"
mkdir -p "$PREFIX/share" "$PREFIX/bin"
rm -rf "$PREFIX/share/gyb"
cp -R "$payload" "$PREFIX/share/gyb"
chmod +x "$PREFIX/share/gyb/gyb"
ln -sf "$PREFIX/share/gyb/gyb" "$PREFIX/bin/gyb"
rm -rf "$work"
ok "installed to $PREFIX/bin/gyb"

echo
if ! printf '%s' ":$PATH:" | grep -q ":$PREFIX/bin:"; then
  warn "$PREFIX/bin is not on your PATH. Either add it:"
  echo "        echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
  warn "or skip that - scripts/05-copy-gmail.sh looks in $PREFIX/bin regardless."
fi

echo
say "Version check"
"$PREFIX/bin/gyb" --version 2>&1 | head -3

echo
say "Next: ./scripts/05-copy-gmail.sh"
