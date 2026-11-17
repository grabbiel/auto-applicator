#!/bin/bash
# Publishes v<VERSION> from this Mac: the fallback for when GitHub's Mac machines can't build it (README › Releases).
# Same steps as .github/workflows/release.yml: test, build the disk image without your cloud browser address, then
# create the release at main's latest commit (or replace the disk image of an existing release).
#   AA_SIGN_IDENTITY and AA_NOTARY_PROFILE sign and notarize it, as in scripts/package.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"

git fetch -q origin main --tags
if [ -n "$(git status --porcelain --untracked-files=no)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Publish from main as it is on GitHub: commit and push first, then git checkout main && git pull." >&2
  exit 1
fi
if gh run list --workflow release.yml --status queued --json databaseId --jq 'length' | grep -qv '^0$'; then
  echo "A Release run is still waiting for a Mac on GitHub; cancel it first (Actions › Release) so both don't publish." >&2
  exit 1
fi

swift test --skip LiveAITests --skip Cloud
AA_CLOUD_CONFIG=none bash scripts/package.sh

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" dist/AutoApplicator.dmg --clobber
  echo "Replaced the disk image of $TAG."
else
  gh release create "$TAG" dist/AutoApplicator.dmg --target "$(git rev-parse HEAD)" --latest \
    --title "Auto Applicator $VERSION" --notes-file .github/release-notes.md --generate-notes
  echo "Published $TAG."
fi
echo "Download: https://github.com/grabbiel/auto-applicator/releases/latest/download/AutoApplicator.dmg"
