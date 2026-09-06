#!/bin/bash
# Собирает DiskLens.app и упаковывает в DMG для распространения.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(grep -m1 'CFBundleShortVersionString' -A1 make_app.sh | grep -o '[0-9.]\+' | head -1)}"
VERSION="${VERSION:-1.0}"

./make_app.sh

DMG="DiskLens-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R DiskLens.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "DiskLens" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
echo "  shasum: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
