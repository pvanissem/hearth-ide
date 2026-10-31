#!/usr/bin/env bash
# Builds, packages and publishes a Hearth IDE release (Apple Silicon only).
#
#   scripts/release.sh v0.1.0
#
# 1. release build + app bundle, zipped with a SHA-256 checksum
# 2. cumulative CHANGELOG.md and latest-version.txt
# 3. annotated tag + push
# 4. GitHub release with all files attached; the app and install.sh read them
#    from https://github.com/<repo>/releases/latest/download/<file>
#
# Needs the GitHub CLI (`gh auth login`) with push rights on the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${HEARTH_REPO:-pvanissem/hearth}"
ASSET="hearth-macos-arm64.zip"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh vX.Y.Z" >&2
  exit 1
fi

step() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

step "Checks"
[[ "$(uname -m)" == "arm64" ]] || fail "Release builds must run on Apple Silicon."
command -v gh >/dev/null || fail "GitHub CLI (gh) not found."
gh auth status >/dev/null 2>&1 || fail "Not logged in: run gh auth login."
[[ -z "$(git status --porcelain)" ]] || fail "Working tree not clean – commit first."
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "Releases are cut from main."
git fetch --quiet --tags origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in sync with origin/main – push or pull first."
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && fail "Tag $VERSION already exists."

step "Build $VERSION"
CONFIG=release VERSION="$VERSION" scripts/bundle.sh
OUT="build/release/$VERSION"
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent "build/Hearth IDE.app" "$OUT/$ASSET"
(cd "$OUT" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
cat "$OUT/$ASSET.sha256"
printf '%s\n' "$VERSION" > "$OUT/latest-version.txt"
cp install.sh "$OUT/install.sh"

step "Changelog"
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
NOTES="$(git log --no-merges --format='- %s' ${PREV:+$PREV..}HEAD | head -n 60 || true)"
{
  printf '## %s · %s\n\n%s\n\n' "${VERSION#v}" "$(date +%Y-%m-%d)" "${NOTES:--}"
  # Keep earlier releases' notes (cumulative, newest first); tolerate a missing file.
  curl -fsSL "https://github.com/$REPO/releases/latest/download/CHANGELOG.md" 2>/dev/null | sed '/^# /d' || true
} > "$OUT/CHANGELOG.body"
{ printf '# Hearth IDE – Änderungen\n\n'; cat "$OUT/CHANGELOG.body"; } | head -c 180000 > "$OUT/CHANGELOG.md"
rm -f "$OUT/CHANGELOG.body"
sed -n '1,12p' "$OUT/CHANGELOG.md"

step "Tag and push"
git tag -a "$VERSION" -m "Hearth IDE $VERSION"
git push origin "$VERSION"

step "GitHub release"
BODY="$(printf 'Installation / Update:\n\n```bash\ncurl -fsSL https://github.com/%s/releases/latest/download/install.sh | bash\n```\n\n### Änderungen\n%s\n' "$REPO" "${NOTES:--}")"
gh release create "$VERSION" --repo "$REPO" --title "Hearth IDE $VERSION" --notes "$BODY" --latest \
  "$OUT/$ASSET" "$OUT/$ASSET.sha256" "$OUT/latest-version.txt" "$OUT/CHANGELOG.md" "$OUT/install.sh"
echo "Release $VERSION: https://github.com/$REPO/releases/tag/$VERSION"
