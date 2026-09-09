# Signing and notarizing Claude Profile Switcher

An Apple Account can run ad hoc builds and, after Xcode creates an Apple
Development certificate, account-signed local builds. Public Developer ID
distribution requires an active Apple Developer Program membership.

## 1. Prepare the Apple developer account

Current state on this Mac:

- Xcode 26.6 and `notarytool` are installed.
- An Apple Development certificate and private key are available and work for
  local signing.
- `codesign` reports Team ID `49P95434EE`.
- No Developer ID Application identity, Developer ID provisioning profile, or
  App Store Connect notarization key was found locally.

Do not send an Apple password, app-specific password, `.p8` key, `.p12` file,
or private key in chat or commit it to this repository.

1. Add the Apple Account in Xcode under **Xcode → Settings → Accounts**.
2. Find the ten-character Team ID on the Apple Developer membership page.
3. Register the explicit macOS App ID com.stigole.ClaudeProfileSwitcher.
4. Enable iCloud Documents for that App ID and create or attach the container
   iCloud.com.stigole.ClaudeProfileSwitcher.
5. Create a Developer ID Application certificate. Xcode can do this under
   **Manage Certificates**, or create/download it in Certificates, Identifiers &
   Profiles. Confirm that the certificate and its private key appear together
   under **My Certificates** in Keychain Access.
6. Generate a Developer ID provisioning profile for the registered App ID with
   the iCloud capability and the Developer ID Application certificate. Download
   the .provisionprofile file.

The Developer ID certificate must be created by the Apple Developer Program
Account Holder (or an admin who has been granted cloud-managed Developer ID
access). If Xcode is still showing its first-launch component dialog, use the
Apple Developer website instead; no iOS simulator download is required for
this macOS project.

If either identifier is already owned by another team, choose a globally unique
reverse-DNS identifier and update AppBundle/Info.plist, both entitlement files,
the iCloud container in ProfileSyncService, and the release secrets together.

## 2. Verify the local identity

    security find-identity -v -p codesigning

The output must contain an identity beginning with Developer ID Application:.

This Mac currently has an `Apple Development` identity. It can sign a local
test build with your account, but it cannot pass Gatekeeper on other Macs or
enable the production iCloud container:

    export CODESIGN_IDENTITY='Apple Development: sog@posterum.no (7QJN5599B2)'
    make build
    codesign --verify --strict --verbose=2 \
      'build/Claude Profile Switcher.app'
    open 'build/Claude Profile Switcher.app'

Leave `APPLE_TEAM_ID` and the provisioning-profile variable unset for this
local-only mode.

Once the Developer ID certificate and profile are installed/downloaded, set:

    export CODESIGN_IDENTITY='Developer ID Application: Stig-Ole Gundersen (49P95434EE)'
    export APPLE_TEAM_ID='49P95434EE'
    export DEVELOPER_ID_PROVISIONING_PROFILE="$HOME/Downloads/ClaudeProfileSwitcher.provisionprofile"
    make signing-check

Use the exact identity printed by `security find-identity`; the example name
above may differ from Apple's generated certificate name.

## 3. Build a signed app

    export CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
    export APPLE_TEAM_ID='TEAMID'
    export DEVELOPER_ID_PROVISIONING_PROFILE='/absolute/path/ClaudeProfileSwitcher.provisionprofile'
    make build

The build signs the embedded dispatcher first and then seals the app with
hardened runtime, a secure timestamp, iCloud entitlements, and the provisioning
profile.

Verify the result:

    codesign --verify --deep --strict --verbose=2 \
      'build/Claude Profile Switcher.app'
    codesign -d --entitlements - \
      'build/Claude Profile Switcher.app'

For ordinary local development, leave the three variables unset and run
make build. The app receives an ad hoc signature with local-only entitlements;
iCloud-container sync is unavailable, but the app can be launched normally.

## 4. Configure notarization locally

Create an app-specific password for the Apple Account, then store a notarytool
profile in the login keychain:

    xcrun notarytool store-credentials 'claude-profile-switcher-notary' \
      --apple-id 'you@example.com' \
      --team-id 'TEAMID' \
      --password 'APP-SPECIFIC-PASSWORD'

Package, submit, and staple:

    ditto -c -k --keepParent \
      'build/Claude Profile Switcher.app' /tmp/ClaudeProfileSwitcher-notary.zip
    xcrun notarytool submit /tmp/ClaudeProfileSwitcher-notary.zip \
      --keychain-profile 'claude-profile-switcher-notary' --wait
    xcrun stapler staple 'build/Claude Profile Switcher.app'
    xcrun stapler validate 'build/Claude Profile Switcher.app'
    spctl --assess --type execute --verbose=4 \
      'build/Claude Profile Switcher.app'
    make dist-from-build

The repository also provides the complete fail-closed flow:

    export NOTARY_KEYCHAIN_PROFILE='claude-profile-switcher-notary'
    make notarized-dist

`make notarized-dist` refuses untagged `0.0.0-dev` builds, validates the
certificate/profile/iCloud container, signs the helper before the app,
submits and staples both app and DMG, runs Gatekeeper assessment, and rebuilds
the checksums. For a release candidate, tag the exact commit first:

    git tag v2.0.0-rc.1
    git push origin v2.0.0-rc.1

Never commit certificate exports, private keys, app-specific passwords, API
keys, or provisioning profiles.

## 5. Configure GitHub Actions

The release workflow requires these repository secrets:

- DEVELOPER_ID_P12_BASE64: base64-encoded .p12 containing the certificate and
  private key.
- DEVELOPER_ID_P12_PASSWORD: export password for that .p12.
- DEVELOPER_ID_APPLICATION: full Keychain identity string.
- DEVELOPER_ID_PROVISIONING_PROFILE_BASE64: base64-encoded Developer ID
  provisioning profile containing the iCloud entitlement.
- APPLE_TEAM_ID: ten-character Team ID.
- BUILD_KEYCHAIN_PASSWORD: random password used only for the ephemeral CI
  keychain.
- NOTARY_KEY_BASE64: base64-encoded App Store Connect API .p8 key.
- NOTARY_KEY_ID: API key ID.
- NOTARY_ISSUER_ID: App Store Connect issuer ID.
- TAP_GITHUB_TOKEN: fine-grained token for updating the Homebrew tap.

Generate base64 values without line wrapping:

    base64 -i DeveloperID.p12 | pbcopy
    base64 -i ClaudeProfileSwitcher.provisionprofile | pbcopy
    base64 -i AuthKey_ABC123.p8 | pbcopy

Tagged releases fail closed when signing, provisioning, notarization, stapling,
Gatekeeper assessment, or checksum generation fails.
