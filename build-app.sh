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
DISPATCHER_BIN="$BIN_PATH/ClaudeProfileDispatcher"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi
if [[ ! -x "$DISPATCHER_BIN" ]]; then
    echo "error: built dispatcher not found at $DISPATCHER_BIN" >&2
    exit 1
fi

OUT_DIR="${OUT_DIR:-./build}"
APP="$OUT_DIR/$DISPLAY_NAME.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$DISPATCHER_BIN" "$APP/Contents/Helpers/ClaudeProfileDispatcher"
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

# The optional shared Claude setup (Manage Profiles → … → Install Shared Claude
# Setup). Plain copy, not an SPM resource; must happen before signing.
mkdir -p "$APP/Contents/Resources/SharedConfig"
cp -R SharedConfig/claude-shared "$APP/Contents/Resources/SharedConfig/"
cp SharedConfig/settings-fragment.json "$APP/Contents/Resources/SharedConfig/"
find "$APP/Contents/Resources/SharedConfig" -name .DS_Store -delete

# SPM may produce a resource bundle for any explicit resources; copy it through if present.
BUNDLE="$BIN_PATH/ClaudeProfileSwitcher_ClaudeProfileSwitcher.bundle"
if [[ -d "$BUNDLE" ]]; then
    cp -R "$BUNDLE" "$APP/Contents/Resources/"
fi

# Default is ad-hoc ("-"). Apple Development identities produce a local-only
# account-signed build. Developer ID Application identities enable the release
# entitlements and are suitable for notarized distribution.
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> ad-hoc code-signing"
    ENTITLEMENTS="AppBundle/ClaudeProfileSwitcher.local.entitlements"
    SIGN_OPTIONS=(--options runtime)
elif [[ "$SIGN_IDENTITY" == Apple\ Development:* ]]; then
    echo "==> local Apple Development signing as: $SIGN_IDENTITY"
    ENTITLEMENTS="AppBundle/ClaudeProfileSwitcher.local.entitlements"
    SIGN_OPTIONS=(--options runtime)
else
    if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
        echo "error: release identity must begin with 'Developer ID Application:'" >&2
        exit 1
    fi
    echo "==> Developer ID signing as: $SIGN_IDENTITY"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for Developer ID signing}"
    ENTITLEMENTS="$OUT_DIR/ClaudeProfileSwitcher.release.entitlements"
    cp AppBundle/ClaudeProfileSwitcher.entitlements "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c \
        "Set :com.apple.developer.ubiquity-kvstore-identifier ${APPLE_TEAM_ID}.com.stigole.ClaudeProfileSwitcher" \
        "$ENTITLEMENTS"
    SIGN_OPTIONS=(--options runtime --timestamp)
    if [[ -n "${DEVELOPER_ID_PROVISIONING_PROFILE:-}" ]]; then
        cp "$DEVELOPER_ID_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    fi
fi
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_OPTIONS[@]}" \
    "$APP/Contents/Helpers/ClaudeProfileDispatcher"
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_OPTIONS[@]}" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

echo
echo "Built: $APP"
echo "Launch with: open \"$APP\""
