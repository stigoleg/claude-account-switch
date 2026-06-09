#!/usr/bin/env bash
# Build a drag-to-Applications .dmg from a built .app bundle.
#
# Plain `hdiutil create -srcfolder` from a staging dir (app + /Applications
# symlink) — no AppleScript window-layout pass, which is the flaky half of DMG
# creation on headless CI runners.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <path/to/App.app> <out.dmg>" >&2
    exit 2
fi

APP="$1"
OUT="$2"
VOLNAME="Claude Profile Switcher"

if [[ ! -d "$APP" ]]; then
    echo "error: app bundle not found at $APP" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# hdiutil intermittently fails on GitHub runners ("Resource busy" while
# XProtect scans the staged bundle). Retry with backoff — known issue.
for attempt in 1 2 3; do
    if hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -ov "$OUT"; then
        echo "Built: $OUT"
        exit 0
    fi
    echo "hdiutil attempt $attempt failed; retrying..." >&2
    sleep $((attempt * 5))
done

echo "error: hdiutil failed after 3 attempts" >&2
exit 1
