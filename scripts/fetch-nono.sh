#!/usr/bin/env bash
# Downloads the pinned nono release for Apple Silicon into Vendor/nono/<version>/nono
# and verifies it against the checksum pinned below. scripts/bundle.sh copies it
# into "Hearth IDE.app/Contents/Helpers/nono".
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="v0.80.0"
ASSET="nono-${VERSION}-aarch64-apple-darwin.tar.gz"
SHA256="ae824167b3d90531b830429ba92b7781379b1c2d79f9b11fdd88b0fd267e4e32"
URL="https://github.com/nolabs-ai/nono/releases/download/${VERSION}/${ASSET}"
DEST="Vendor/nono/${VERSION}"

if [[ -x "$DEST/nono" ]]; then echo "$DEST/nono"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ASSET" "$URL"
echo "$SHA256  $TMP/$ASSET" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for $ASSET" >&2; exit 1; }
mkdir -p "$TMP/x" && tar -xzf "$TMP/$ASSET" -C "$TMP/x"
BIN="$(find "$TMP/x" -type f -name nono -perm -u+x | head -n1)"
[[ -n "$BIN" ]] || { echo "No nono binary in $ASSET" >&2; exit 1; }
mkdir -p "$DEST" && cp "$BIN" "$DEST/nono" && chmod 755 "$DEST/nono"
find "$TMP/x" -maxdepth 2 -iname 'LICENSE*' -exec cp {} "$DEST/" \; 2>/dev/null || true
echo "$DEST/nono"
