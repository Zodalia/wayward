#!/usr/bin/env bash
# Zips the addon for a manual upload (CurseForge, Wago, GitHub release):
#   tools/package.sh            -> dist/Wayward-<version>.zip
# The version comes from the TOC. Only Wayward/ goes in; nothing else from
# the repository does.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(sed -n 's/^## Version: *//p' Wayward/Wayward.toc | tr -d '\r')
[ -n "$version" ] || { echo "no ## Version in Wayward/Wayward.toc" >&2; exit 1; }
lua tests/wayward_smoke.lua >/dev/null
mkdir -p dist
out="dist/Wayward-$version.zip"
rm -f "$out"
zip -qr "$out" Wayward -x '*.DS_Store' -x '*/.*'
echo "$out ($(du -h "$out" | cut -f1))"
