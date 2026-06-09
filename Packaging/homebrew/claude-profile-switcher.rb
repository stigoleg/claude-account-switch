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
    This app is ad-hoc signed (no Apple Developer ID), so Gatekeeper blocks
    the first launch unless you installed with:
      brew install --cask --no-quarantine claude-profile-switcher
    Or, after a normal install, either run:
      xattr -d com.apple.quarantine "/Applications/Claude Profile Switcher.app"
    or right-click the app in Finder and choose Open (once).

    --no-quarantine skips Gatekeeper's first-launch check — only use it for
    software you trust; you can verify downloads against the SHA256SUMS file
    attached to each GitHub release.
  EOS

  zap trash: "~/Library/Application Support/ClaudeProfileSwitcher"
end
