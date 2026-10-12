# Homebrew cask for Claude Profile Switcher.
#
# This file is the source of truth for stigoleg/homebrew-tap
# Casks/claude-profile-switcher.rb. When a release is published, cask.yml
# renders it into the tap with the release's `version` and
# `sha256` (requires the TAP_GITHUB_TOKEN secret; see
# .github/workflows/cask.yml). Edit stanzas and caveats here, not in the tap.
cask "claude-profile-switcher" do
  version "1.3.0"
  sha256 "PLACEHOLDER_UPDATED_BY_RELEASE_WORKFLOW"

  url "https://github.com/stigoleg/claude-account-switch/releases/download/v#{version}/ClaudeProfileSwitcher-#{version}.zip"
  name "Claude Profile Switcher"
  desc "Menu-bar app for switching between multiple Claude accounts (Desktop + CLI)"
  homepage "https://github.com/stigoleg/claude-account-switch"

  depends_on macos: :sonoma

  app "Claude Profile Switcher.app"

  caveats <<~EOS
    Version 2 migrates legacy profiles only after creating a verified APFS
    copy-on-write backup. Profile data is intentionally retained when the cask
    is uninstalled; use the app's Disable & Restore action first.
  EOS
end
