#!/usr/bin/env bash
# Resolve the app version / build number. Single source of truth: the git tag.
#
#   version       $APP_VERSION env > exact `v*` tag on HEAD > 0.0.0-dev
#   build-number  $APP_BUILD_NUMBER env > commit count on HEAD > 0
#
# `--exact-match` is deliberate: an untagged local build gets 0.0.0-dev, never
# a misleading "almost-released" version. The release workflow checks out the
# tag itself, so it always resolves the real version.
set -euo pipefail

case "${1:-version}" in
  version)
    if [[ -n "${APP_VERSION:-}" ]]; then
      echo "$APP_VERSION"
      exit 0
    fi
    tag="$(git describe --tags --exact-match --match 'v*' 2>/dev/null || true)"
    if [[ -n "$tag" ]]; then
      echo "${tag#v}"
      exit 0
    fi
    echo "0.0.0-dev"
    ;;
  build-number)
    echo "${APP_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
    ;;
  *)
    echo "usage: $0 [version|build-number]" >&2
    exit 2
    ;;
esac
