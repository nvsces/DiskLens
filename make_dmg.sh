#!/bin/bash
# Собирает DiskLens.app, подписывает Developer ID, нотаризует и упаковывает в DMG.
#
#   ./make_dmg.sh 1.0            подпись + нотаризация (если настроена)
#   ./make_dmg.sh 1.0 --no-notarize   только подпись
#
# Разовая настройка нотаризации:
#   xcrun notarytool store-credentials notary \
#     --apple-id <ваш@apple.id> --team-id DT7W5LCT3Z --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
NOTARIZE=true
[[ "${2:-}" == "--no-notarize" ]] && NOTARIZE=false

APP="DiskLens.app"
DMG="DiskLens-$VERSION.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"

# Ищем Developer ID Application в связке ключей.
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')

if [ -z "$IDENTITY" ]; then
  echo "⚠️  Developer ID Application не найден — подписываю ad-hoc."
  echo "   Такой DMG на чужих машинах вызовет предупреждение Gatekeeper."
  IDENTITY="-"
  NOTARIZE=false
else
  echo "→ Сертификат: $IDENTITY"
fi

./make_app.sh

if [ "$IDENTITY" != "-" ]; then
  echo "→ Подпись приложения (hardened runtime)…"
  # Hardened runtime обязателен для нотаризации; timestamp — тоже.
  codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2
fi

echo "→ Сборка DMG…"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DiskLens" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ "$IDENTITY" != "-" ]; then
  echo "→ Подпись DMG…"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [ "$NOTARIZE" = true ]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "→ Нотаризация (обычно 1–5 минут)…"
    if xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
      echo "→ Прикрепление штампа…"
      xcrun stapler staple "$DMG"
      xcrun stapler validate "$DMG"
    else
      echo "⚠️  Нотаризация не прошла. Журнал:"
      echo "   xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    fi
  else
    echo "⚠️  Профиль нотаризации «$NOTARY_PROFILE» не настроен, пропускаю."
    echo "   xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "     --apple-id <ваш@apple.id> --team-id DT7W5LCT3Z --password <app-specific-password>"
  fi
fi

echo
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
echo "  SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  /' || true
