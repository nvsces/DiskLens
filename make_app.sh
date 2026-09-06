#!/bin/bash
# Собирает DiskLens.app из SPM-бинарника.
set -euo pipefail
cd "$(dirname "$0")"

APP="DiskLens.app"
BUNDLE_ID="com.nvsces.disklens"

echo "→ Сборка релиза…"
swift build -c release

BIN=$(swift build -c release --show-bin-path)/DiskLens

echo "→ Формирование бандла…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskLens"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DiskLens</string>
    <key>CFBundleDisplayName</key><string>DiskLens</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>DiskLens</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>DiskLens</string>
</dict>
</plist>
PLIST

# Иконка: рисуем PDF-кольцо и прогоняем через iconutil.
if [ -f icon.png ]; then
  echo "→ Иконка…"
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Локальная подпись: без неё macOS ругается на неподписанный бинарник.
echo "→ Подпись…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (подпись пропущена)"

echo "✓ Готово: $(pwd)/$APP"
