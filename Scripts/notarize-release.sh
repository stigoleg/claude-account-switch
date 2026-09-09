#!/usr/bin/env bash
set -euo pipefail

: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${DEVELOPER_ID_PROVISIONING_PROFILE:?Set DEVELOPER_ID_PROVISIONING_PROFILE}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to the notarytool keychain profile name}"

version="$(./Scripts/version.sh version)"
if [[ "$version" == "0.0.0-dev" && "${ALLOW_DEV_NOTARIZATION:-0}" != "1" ]]; then
  echo "error: notarized releases must be built from a v* tag (or set APP_VERSION explicitly)" >&2
  exit 2
fi

./Scripts/check-signing.sh
make build
codesign --verify --strict --verbose=2 \
  "build/Claude Profile Switcher.app/Contents/Helpers/ClaudeProfileDispatcher"
codesign --verify --strict --verbose=2 "build/Claude Profile Switcher.app"

notary_tmp_dir="$(mktemp -d /tmp/claude-profile-notary.XXXXXX)"
cleanup() {
  case "$notary_tmp_dir" in
    /tmp/claude-profile-notary.*) rm -rf "$notary_tmp_dir" ;;
  esac
}
trap cleanup EXIT

ditto -c -k --keepParent \
  "build/Claude Profile Switcher.app" "$notary_tmp_dir/app.zip"
xcrun notarytool submit "$notary_tmp_dir/app.zip" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "build/Claude Profile Switcher.app"
xcrun stapler validate "build/Claude Profile Switcher.app"
spctl --assess --type execute --verbose=4 "build/Claude Profile Switcher.app"

make dist-from-build
for disk_image in dist/*.dmg; do
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$disk_image"
  codesign --verify --strict --verbose=2 "$disk_image"
  xcrun notarytool submit "$disk_image" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$disk_image"
  xcrun stapler validate "$disk_image"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$disk_image"
done
make checksums

echo "Notarized release artifacts are ready in dist/."
