# Homebrew cask for Claude Profile Switcher.
#
# This file is the template for the tap repo — copy it to
# stigoleg/homebrew-tap as Casks/claude-profile-switcher.rb. After that, the
# release workflow's `update-cask` job keeps `version` and `sha256` current on
# every tagged release (requires the TAP_GITHUB_TOKEN secret; see
# .github/workflows/release.yml).
cask "claude-profile-switcher" do
  version "1.3.0"
  sha256 "PLACEHOLDER_UPDATED_BY_RELEASE_WORKFLOW"

  url "https://github.com/stigoleg/claude-account-switch/releases/download/v#{version}/ClaudeProfileSwitcher-#{version}.zip"
  name "Claude Profile Switcher"
  desc "Menu-bar app for switching between multiple Claude accounts (Desktop + CLI)"
  homepage "https://github.com/stigoleg/claude-account-switch"

  depends_on macos: ">= :sonoma"

  app "Claude Profile Switcher.app"

  caveats <<~EOS
    Version 2 migrates legacy profiles only after creating a verified APFS
    copy-on-write backup. Profile data is intentionally retained when the cask
    is uninstalled; use the app's Disable & Restore action first.
  EOS
end
