#!/bin/bash
# Creates dist/AutoApplicator.dmg to share with another Mac user: the app, a shortcut to Applications to drag it
# onto, and a one-page "How to install" note. The app bundles only the allowlisted code (see build_app.sh); your
# profile, .env, cookies, database and logs live in ~/Library/Application Support/AutoApplicator and are never
# included.
#   Optional: AA_SIGN_IDENTITY="Developer ID Application: …" signs the app and the disk image, and
#   AA_NOTARY_PROFILE=<notarytool keychain profile> also notarizes it, so it opens without the "Open Anyway" step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=$(awk -F'"' '/^version/ {print $2; exit}' "$ROOT/pyproject.toml")
OUT="$ROOT/dist/AutoApplicator.dmg"

WORK="$(mktemp -d)"
MNT="$WORK/mnt"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$WORK"' EXIT
STAGE="$WORK/Auto Applicator"
mkdir -p "$STAGE" "$MNT" "$ROOT/dist"
bash "$ROOT/scripts/build_app.sh" "$STAGE" >/dev/null
cp "$ROOT/macos/How to install.txt" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -quiet -volname "Auto Applicator" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT"

if [ -n "${AA_SIGN_IDENTITY:-}" ]; then
  codesign --sign "$AA_SIGN_IDENTITY" --timestamp "$OUT"
  if [ -n "${AA_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$AA_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
  fi
fi

# Check the app inside the disk image still has a valid signature.
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$OUT"
codesign --verify --deep --strict "$MNT/Auto Applicator.app"
[ -L "$MNT/Applications" ] && [ -f "$MNT/How to install.txt" ]
hdiutil detach -quiet "$MNT"

echo "Created $OUT (version $VERSION, $(du -h "$OUT" | cut -f1))"
echo "Share it (e.g. as a GitHub release asset); the recipient follows 'How to install.txt' inside."
