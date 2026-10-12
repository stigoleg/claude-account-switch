#!/usr/bin/env bash
set -euo pipefail

: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${DEVELOPER_ID_PROVISIONING_PROFILE:?Set DEVELOPER_ID_PROVISIONING_PROFILE}"
# notarytool credentials: a stored keychain profile, or an App Store Connect
# API key given directly (the same key works for every app on the team).
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notary_auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" && -f "${APPLE_API_PRIVATE_KEY_PATH:-}" ]]; then
  notary_auth=(--key "$APPLE_API_PRIVATE_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
else
  echo "error: set NOTARY_KEYCHAIN_PROFILE, or APPLE_API_KEY_ID, APPLE_API_ISSUER and APPLE_API_PRIVATE_KEY_PATH" >&2
  exit 2
fi

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
  "${notary_auth[@]}" --wait
xcrun stapler staple "build/Claude Profile Switcher.app"
xcrun stapler validate "build/Claude Profile Switcher.app"
spctl --assess --type execute --verbose=4 "build/Claude Profile Switcher.app"

make dist-from-build
for disk_image in dist/*.dmg; do
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$disk_image"
  codesign --verify --strict --verbose=2 "$disk_image"
  xcrun notarytool submit "$disk_image" \
    "${notary_auth[@]}" --wait
  xcrun stapler staple "$disk_image"
  xcrun stapler validate "$disk_image"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$disk_image"
done
make checksums

echo "Notarized release artifacts are ready in dist/."
