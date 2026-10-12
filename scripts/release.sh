#!/bin/bash
# Offline DMG. Optional Developer ID + notarization when SIGN_ID/NOTARY_PROFILE are supplied.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
WITH_MODELS="${WITH_MODELS:-1}" ./build.sh
APP="$PWD/build.noindex/DigUp-ZH.app"
mkdir -p dist
STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/digup-zh-dmg.XXXXXX")"
ditto --noextattr --noqtn "$APP" "$STAGE/DigUp-ZH.app"
# Finder/iCloud metadata may be reattached after the app is moved into the source workspace.
# Remove it from this temporary release copy and re-check the sealed contents before making the DMG.
xattr -cr "$STAGE/DigUp-ZH.app"
codesign --verify --strict --deep "$STAGE/DigUp-ZH.app"
ln -s /Applications "$STAGE/Applications"
DMG="$PWD/dist/DigUp-ZH-$VERSION-arm64.dmg"
[[ ! -e "$DMG" ]] || { echo "Refusing to overwrite $DMG; move the previous artifact first."; exit 1; }
if [[ -n "${SIGN_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$STAGE/DigUp-ZH.app" "$STAGE/notarize.zip"
  xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE/DigUp-ZH.app"
  rm "$STAGE/notarize.zip"
fi
hdiutil create -volname "DigUp-ZH 安装" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
hdiutil verify "$DMG"
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/private/tmp}/digup-zh-verify.XXXXXX")"
trap 'hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true; rmdir "$VERIFY_MOUNT" 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$VERIFY_MOUNT"
codesign --verify --strict --deep "$VERIFY_MOUNT/DigUp-ZH.app"
hdiutil detach "$VERIFY_MOUNT"
rmdir "$VERIFY_MOUNT"
trap - EXIT
if [[ -n "${SIGN_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG"
echo "Created $DMG"
echo "Staging copy retained for inspection: $STAGE"
