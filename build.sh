#!/bin/bash
# Build the Apple Silicon app. WITH_MODELS=1 embeds the verified offline model.
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -m)" == arm64 ]] || { echo "DigUp-ZH currently builds for Apple Silicon."; exit 1; }
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
scripts/build-llama.sh
swift build -c release --product DigUpApp
swift build -c release --product digup
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p build.noindex
STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/digup-zh-app.XXXXXX")"
APP="$STAGE/DigUp-ZH.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/DigUpApp" "$APP/Contents/MacOS/DigUp-ZH"
cp "$BIN_DIR/digup" "$APP/Contents/Helpers/digup"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Acknowledgements.txt "$APP/Contents/Resources/Acknowledgements.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE"
if [[ "${WITH_MODELS:-0}" == 1 ]]; then
  MODELS="${MODEL_DIR:-$PWD/.models}"
  TEXT="Qwen.Qwen3-VL-Embedding-2B.Q4_K_M.gguf"
  MEDIA="mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf"
  [[ "$(shasum -a 256 "$MODELS/$TEXT" | awk '{print $1}')" == 42a4ebc629ecc6514649e12b1529b857f54900273bb854f853c970fb90edd09d ]] || { echo "Text model check failed"; exit 1; }
  [[ "$(shasum -a 256 "$MODELS/$MEDIA" | awk '{print $1}')" == 3f89a7768ffa6606935319f71bf56bb71871249ba549bf1080a0caea7a088613 ]] || { echo "Vision model check failed"; exit 1; }
  mkdir -p "$APP/Contents/Resources/Models"
  cp -c "$MODELS/$TEXT" "$APP/Contents/Resources/Models/$TEXT"
  cp -c "$MODELS/$MEDIA" "$APP/Contents/Resources/Models/$MEDIA"
fi
IDENTITY="${SIGN_ID:--}"
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" != - ]] && TIMESTAMP="--timestamp"
# Source assets may carry Finder/iCloud metadata. Clean only the newly assembled bundle before signing it.
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" "$APP/Contents/Helpers/digup"
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" --entitlements Resources/DigUp.entitlements "$APP"
codesign --verify --strict --deep "$APP"
DEST="$PWD/build.noindex/DigUp-ZH.app"
if [[ -e "$DEST" ]]; then mv "$DEST" "$PWD/build.noindex/DigUp-ZH.previous.$(date +%s).app"; fi
mv "$APP" "$DEST"
rmdir "$STAGE"
echo "Built $DEST"
