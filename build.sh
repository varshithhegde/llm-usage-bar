#!/usr/bin/env bash
# Builds "build/LLM Usage.app".
# Usage: ./build.sh [--install] [--selftest] [--dist]
#   --dist  also writes dist/LLM-Usage-<version>-macOS.zip for sharing
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LLM Usage"
BUNDLE_ID="dev.varshith.LLMUsageBar"
EXEC="LLMUsageBar"
VERSION="1.0.0"
APP="build/${APP_NAME}.app"

INSTALL=0
SELFTEST=0
DIST=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --selftest) SELFTEST=1 ;;
    --dist) DIST=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

echo "▸ Building (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${EXEC}"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${EXEC}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${EXEC}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Varshith</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep -s - "$APP"
codesign --verify --verbose=1 "$APP"

if [[ $SELFTEST -eq 1 ]]; then
  echo "▸ Running self-test…"
  "$APP/Contents/MacOS/${EXEC}" --selftest
fi

if [[ $INSTALL -eq 1 ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/${APP_NAME}.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "▸ Installed to ~/Applications/${APP_NAME}.app"
fi

if [[ $DIST -eq 1 ]]; then
  echo "▸ Packaging shareable zip…"
  STAGE="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$STAGE'" EXIT
  cp -R "$APP" "$STAGE/"
  xattr -cr "$STAGE"
  cat > "$STAGE/How to open.txt" <<EOF
LLM Usage ${VERSION}
A menu-bar app for LiteLLM spend. Requires macOS 14 or later on Apple Silicon.

1. Move "LLM Usage.app" into your Applications folder (or anywhere you keep apps).
2. The first launch is blocked, because this copy is not notarized by Apple.
   Right-click the app, choose Open, then Open again.
   If macOS says the app is damaged, run this in Terminal:

   xattr -dr com.apple.quarantine "/Applications/LLM Usage.app"

3. A chart icon appears in the menu bar. Click it, open Settings, paste your
   LiteLLM key, and choose Save. The key stays in your Mac's Keychain.
   The gateway starts at https://ai-gateway.dev.devrev-eng.ai — change it
   in Settings if yours is different.
EOF
  mkdir -p dist
  OUT="dist/LLM-Usage-${VERSION}-macOS.zip"
  rm -f "$OUT"
  # Archive the folder contents so the zip opens straight onto the app.
  # --norsrc drops AppleDouble (._*) sidecars so the zip stays just the app.
  ditto -c -k --norsrc "$STAGE" "$OUT"
  echo "✓ Share this file: $OUT"
fi

echo "✓ Done: $APP"
