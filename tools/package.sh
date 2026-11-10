#!/usr/bin/env bash
# Zips the addon for a manual upload (CurseForge, Wago, GitHub release):
#   tools/package.sh            -> dist/Wayward-<version>.zip
# The version is the latest git tag (git describe), written over the
# @project-version@ keyword as the BigWigs packager does for tagged releases
# (.github/workflows/release.yml). Only Wayward/ goes in; nothing else from
# the repository does.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(git describe --tags --always)
[ -n "$version" ] || { echo "no git tag or commit to name the version" >&2; exit 1; }
lua tests/wayward_smoke.lua >/dev/null
WAYWARD_GAME=era lua tests/wayward_smoke.lua >/dev/null
mkdir -p dist
out="dist/Wayward-$version.zip"
rm -f "$out"
stage=$(mktemp -d)
cp -R Wayward "$stage/Wayward"
cp LICENSE "$stage/Wayward/LICENSE.txt"
cp CHANGELOG.md "$stage/Wayward/CHANGELOG.md"
find "$stage/Wayward" \( -name '*.lua' -o -name '*.toc' \) -exec sed -i.bak "s/@project-version@/$version/g" {} + &&
  find "$stage/Wayward" -name '*.bak' -delete
(cd "$stage" && zip -qr "$OLDPWD/$out" Wayward -x '*.DS_Store' -x '*/.*')
rm -rf "$stage"
echo "$out ($(du -h "$out" | cut -f1))"
