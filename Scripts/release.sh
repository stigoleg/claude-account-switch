#!/usr/bin/env bash
# Local release pipeline. Signing and notarization run on this Mac, so the
# Developer ID private key never leaves the login keychain.
#
#   Scripts/release.sh 2.1.0            pre-release check: lint, tests, signed +
#                                       notarized artifacts in dist/, nothing pushed
#   Scripts/release.sh 2.1.0 --publish  the same, then tag, push main and the tag,
#                                       and create the GitHub release; the cask
#                                       workflow then updates the Homebrew tap
#
# Signing values come from the environment or from $SIGNING_ENV_FILE (default:
# ./.env when present, else ~/.config/apple-signing/claude-profile-switcher.env):
#   CODESIGN_IDENTITY, APPLE_TEAM_ID, DEVELOPER_ID_PROVISIONING_PROFILE,
#   APPLE_API_KEY_ID, APPLE_API_ISSUER, APPLE_API_PRIVATE_KEY_PATH
#   (or NOTARY_KEYCHAIN_PROFILE instead of the three APPLE_API_* values)
set -euo pipefail

cd "$(dirname "$0")/.."

version="${1:-}"
publish=0
[[ "${2:-}" == "--publish" ]] && publish=1
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "usage: $0 <version, e.g. 2.1.0 or 2.1.0-rc.1> [--publish]" >&2
  exit 2
fi
[[ "$version" != "0.0.0-dev" ]] || { echo "usage: make release-check VERSION=x.y.z" >&2; exit 2; }
tag="v$version"

default_env="$HOME/.config/apple-signing/claude-profile-switcher.env"
[[ -f .env ]] && default_env="$PWD/.env"
env_file="${SIGNING_ENV_FILE:-$default_env}"
if [[ -f "$env_file" ]]; then
  echo "==> loading signing values from $env_file"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
fi
: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY is not set (see SIGNING.md)}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}"
: "${DEVELOPER_ID_PROVISIONING_PROFILE:?DEVELOPER_ID_PROVISIONING_PROFILE is not set}"
export CODESIGN_IDENTITY APPLE_TEAM_ID DEVELOPER_ID_PROVISIONING_PROFILE

echo "==> preflight"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "error: release from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is not clean" >&2; exit 1; }
git fetch --quiet --tags origin main
if ! git merge-base --is-ancestor origin/main HEAD; then
  echo "error: origin/main has commits that are not in HEAD; pull first" >&2
  exit 1
fi
head_sha="$(git rev-parse HEAD)"
remote_tag_sha="$(git ls-remote origin "refs/tags/$tag^{}" | cut -f1)"
[[ -n "$remote_tag_sha" ]] || remote_tag_sha="$(git ls-remote origin "refs/tags/$tag" | cut -f1)"
if [[ -n "$remote_tag_sha" && "$remote_tag_sha" != "$head_sha" ]]; then
  echo "error: $tag already exists on origin at ${remote_tag_sha:0:7}, not HEAD" >&2
  exit 1
fi
if gh release view "$tag" >/dev/null 2>&1; then
  echo "error: GitHub release $tag already exists" >&2
  exit 1
fi
local_tag_sha="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" || true)"
if [[ -n "$local_tag_sha" && "$local_tag_sha" != "$head_sha" ]]; then
  echo "error: local tag $tag points at ${local_tag_sha:0:7}, not HEAD" >&2
  exit 1
fi

echo "==> lint and tests"
make lint
make test

echo "==> signed, notarized artifacts for $version"
# APP_VERSION stamps the bundle without needing the tag to exist yet.
export APP_VERSION="$version"
bash ./Scripts/notarize-release.sh

stamped="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "build/Claude Profile Switcher.app/Contents/Info.plist")"
[[ "$stamped" == "$version" ]] || { echo "error: bundle stamped $stamped, expected $version" >&2; exit 1; }
(cd dist && shasum -a 256 -c SHA256SUMS)
assets=(dist/ClaudeProfileSwitcher-"$version".zip dist/ClaudeProfileSwitcher-"$version".dmg
  dist/ClaudeProfileSwitcher.spdx.json dist/SHA256SUMS)
ls -l "${assets[@]}"

if [[ "$publish" != "1" ]]; then
  echo
  echo "Pre-release check passed. Nothing was pushed. Publish with:"
  echo "  make release VERSION=$version"
  exit 0
fi

echo "==> publishing $tag"
[[ -n "$local_tag_sha" ]] || git tag -a "$tag" -m "$tag"
git push origin main
git push origin "$tag"
release_flags=()
[[ "$version" == *-* ]] && release_flags+=(--prerelease)
gh release create "$tag" --verify-tag --title "$tag" --generate-notes \
  ${release_flags[@]+"${release_flags[@]}"} "${assets[@]}"

echo
echo "Released $tag. The cask workflow updates stigoleg/homebrew-tap for"
echo "non-prerelease versions; follow it with: gh run list --workflow cask.yml"
