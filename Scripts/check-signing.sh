#!/usr/bin/env bash
set -euo pipefail

echo "Code-signing identities:"
security find-identity -v -p codesigning
echo

if ! security find-identity -v -p codesigning | grep -q 'Developer ID Application:'; then
  echo "MISSING: Developer ID Application certificate and private key." >&2
  echo "Create it in Apple Developer → Certificates or Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 2
fi

if [[ -z "${APPLE_TEAM_ID:-}" ]]; then
  echo "MISSING: APPLE_TEAM_ID" >&2
  exit 2
fi
if [[ -z "${DEVELOPER_ID_PROVISIONING_PROFILE:-}" ]]; then
  echo "MISSING: DEVELOPER_ID_PROVISIONING_PROFILE" >&2
  exit 2
fi
if [[ ! -f "$DEVELOPER_ID_PROVISIONING_PROFILE" ]]; then
  echo "MISSING: provisioning profile at $DEVELOPER_ID_PROVISIONING_PROFILE" >&2
  exit 2
fi

signing_check_tmp="$(mktemp -d /tmp/claude-profile-signing-check.XXXXXX)"
cleanup() {
  case "$signing_check_tmp" in
    /tmp/claude-profile-signing-check.*) rm -rf "$signing_check_tmp" ;;
  esac
}
trap cleanup EXIT

security cms -D -i "$DEVELOPER_ID_PROVISIONING_PROFILE" > "$signing_check_tmp/profile.plist"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$signing_check_tmp/profile.plist")"
profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$signing_check_tmp/profile.plist")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$signing_check_tmp/profile.plist")"

if [[ "$profile_team" != "$APPLE_TEAM_ID" ]]; then
  echo "ERROR: provisioning profile team $profile_team does not match APPLE_TEAM_ID $APPLE_TEAM_ID" >&2
  exit 3
fi
if [[ "$profile_app_id" != "$APPLE_TEAM_ID.com.stigole.ClaudeProfileSwitcher" ]]; then
  echo "ERROR: provisioning profile is for $profile_app_id, not Claude Profile Switcher" >&2
  exit 3
fi
if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.ubiquity-container-identifiers' \
    "$signing_check_tmp/profile.plist" | grep -q 'iCloud.com.stigole.ClaudeProfileSwitcher'; then
  echo "ERROR: provisioning profile does not include the required iCloud container" >&2
  exit 3
fi

echo "Developer ID prerequisites look valid."
echo "Provisioning profile: $profile_name"
echo "Team: $profile_team"
echo "App identifier: $profile_app_id"
