#!/bin/bash
# Собирает DiskLens.app через xcodebuild.
#
# Раньше сборка шла через `swift build`, но такой бинарник тянет rpath на
# Xcode-тулчейн и линкует библиотеки новее целевой ОС — на чужой машине
# приложение не запускается. xcodebuild собирает против SDK корректно.
set -euo pipefail
cd "$(dirname "$0")"

APP="DiskLens.app"
DERIVED="${DERIVED:-$(mktemp -d)/DerivedData}"
ARCHS="${ARCHS:-arm64 x86_64}"   # универсальный бинарник: работает и на Apple Silicon, и на Intel

echo "→ Сборка (xcodebuild, $ARCHS)…"
xcodebuild -project DiskLens.xcodeproj \
  -scheme DiskLens \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee /tmp/disklens-build.log | grep -E "error:|BUILD" || true

if ! grep -q "BUILD SUCCEEDED" /tmp/disklens-build.log; then
  echo "✗ Сборка не удалась, журнал: /tmp/disklens-build.log"
  exit 1
fi

BUILT="$DERIVED/Build/Products/Release/$APP"
[ -d "$BUILT" ] || { echo "✗ Сборка не удалась"; exit 1; }

rm -rf "$APP"
cp -R "$BUILT" "$APP"

echo "→ Подпись…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (подпись пропущена)"

echo "✓ Готово: $(pwd)/$APP"
lipo -info "$APP/Contents/MacOS/DiskLens" | sed 's/^/  /'
