#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-./dist/ClaudeProfileSwitcher.spdx.json}"
VERSION="$(./Scripts/version.sh version)"
REVISION="$(git rev-parse HEAD)"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$OUT")"

jq -n \
  --arg version "$VERSION" \
  --arg revision "$REVISION" \
  --arg created "$CREATED" \
  '{
    spdxVersion: "SPDX-2.3",
    dataLicense: "CC0-1.0",
    SPDXID: "SPDXRef-DOCUMENT",
    name: ("ClaudeProfileSwitcher-" + $version),
    documentNamespace: ("https://github.com/stigoleg/claude-account-switch/sbom/" + $revision),
    creationInfo: {
      created: $created,
      creators: ["Tool: ClaudeProfileSwitcher-SBOM"]
    },
    packages: [{
      name: "ClaudeProfileSwitcher",
      SPDXID: "SPDXRef-Package-ClaudeProfileSwitcher",
      versionInfo: $version,
      downloadLocation: "https://github.com/stigoleg/claude-account-switch",
      filesAnalyzed: false,
      supplier: "Organization: stigoleg",
      externalRefs: [{
        referenceCategory: "PACKAGE-MANAGER",
        referenceType: "purl",
        referenceLocator: ("pkg:github/stigoleg/claude-account-switch@" + $revision)
      }]
    }],
    relationships: [{
      spdxElementId: "SPDXRef-DOCUMENT",
      relationshipType: "DESCRIBES",
      relatedSpdxElement: "SPDXRef-Package-ClaudeProfileSwitcher"
    }]
  }' > "$OUT"
