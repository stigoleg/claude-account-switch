#!/usr/bin/env bash
# Wraps the SPM executable into a real macOS .app bundle so LSUIElement
# (hide-from-Dock) and a custom Info.plist take effect.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"            # release | debug
APP_NAME="ClaudeProfileSwitcher"
DISPLAY_NAME="Claude Profile Switcher"
BUNDLE_ID="com.stigole.ClaudeProfileSwitcher"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_PATH/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

OUT_DIR="${OUT_DIR:-./build}"
APP="$OUT_DIR/$DISPLAY_NAME.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp AppBundle/Info.plist "$APP/Contents/Info.plist"

# Stamp the version before signing — codesign seals Info.plist into the
# signature, so edits after signing would invalidate it. The committed plist
# holds template values (0.0.0 / 0); Scripts/version.sh is the source of truth.
VERSION="$(./Scripts/version.sh version)"
BUILD_NUMBER="$(./Scripts/version.sh build-number)"
echo "==> stamping version $VERSION ($BUILD_NUMBER)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Icon — referenced from Info.plist via CFBundleIconFile. Optional: a missing
# .icns doesn't fail the build, you just get the default binary icon.
if [[ -f AppBundle/AppIcon.icns ]]; then
    cp AppBundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# SPM may produce a resource bundle for any explicit resources; copy it through if present.
BUNDLE="$BIN_PATH/ClaudeProfileSwitcher_ClaudeProfileSwitcher.bundle"
if [[ -d "$BUNDLE" ]]; then
    cp -R "$BUNDLE" "$APP/Contents/Resources/"
fi

# Default is ad-hoc ("-"). Set CODESIGN_IDENTITY to a Developer ID
# Application identity to produce a distributable signature; a notarization
# step can then be added after packaging without restructuring this script.
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> ad-hoc code-signing"
else
    echo "==> code-signing as: $SIGN_IDENTITY"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements AppBundle/ClaudeProfileSwitcher.entitlements \
    "$APP"

echo
echo "Built: $APP"
echo "Launch with: open \"$APP\""
