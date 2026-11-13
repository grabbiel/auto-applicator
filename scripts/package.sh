#!/bin/bash
# Creates dist/AutoApplicator.dmg to share: the app, a shortcut to Applications to drag it onto (on a styled
# background), and a one-page "How to install". No personal data is ever included: it all lives in
# ~/Library/Application Support/AutoApplicator. Your cloud browser's address (Resources/CloudConfig.json) is included
# when present; for a copy to give to other people, run with AA_CLOUD_CONFIG=none.
#   Optional: AA_SIGN_IDENTITY="Developer ID Application: …" signs the app and the disk image, and
#   AA_NOTARY_PROFILE=<notarytool keychain profile> also notarizes it, so it opens without the "Open Anyway" step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
OUT="$ROOT/dist/AutoApplicator.dmg"
NAME="Auto Applicator"

WORK="$(mktemp -d)"
MNT="$WORK/mnt"
trap 'hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background" "$MNT" "$ROOT/dist"
bash "$ROOT/scripts/build_app.sh" "$STAGE"
cp "$ROOT/macos/How to install.txt" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift "$ROOT/scripts/make_dmg_background.swift" "$WORK/bg" >/dev/null
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# A writable image first, so Finder can store the window layout in it; compressed afterwards.
RW="$WORK/rw.dmg"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 60m "$RW"
# Window layout: background, icon size and positions (matching make_dmg_background.swift). Finder needs to see
# the volume by name, so this runs on a browsable mount; if Finder can't be scripted here, the plain layout stays.
DEV="$(hdiutil attach -readwrite -noautoopen "$RW" | awk -F'\t' '/Apple_HFS/ {print $1}' | tr -d ' ')"
VOL="/Volumes/$NAME"
# (At most a minute: on a machine where Finder may not be scripted, macOS could otherwise wait for a permission click.)
if perl -e 'alarm 60; exec @ARGV' osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 104
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" of container window to {170, 210}
    set position of item "Applications" of container window to {490, 210}
    set position of item "How to install.txt" of container window to {330, 312}
    try
      set position of item ".background" of container window to {900, 900}
      set position of item ".fseventsd" of container window to {1000, 900}
    end try
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "Styled the disk image window."
else
  echo "Finder couldn't be scripted here (Automation permission); the disk image keeps Finder's default layout." >&2
fi
SetFile -a C "$VOL" 2>/dev/null || true
# Keep the support folders out of sight (some people's Finders show hidden files).
chflags hidden "$VOL/.background" 2>/dev/null || true
rm -rf "$VOL/.fseventsd"
sync
hdiutil detach -quiet "$DEV" || hdiutil detach -quiet -force "$DEV"

rm -f "$OUT"
hdiutil convert -quiet "$RW" -format ULFO -o "$OUT"   # LZFSE: smaller and faster to open on Apple silicon

if [ -n "${AA_SIGN_IDENTITY:-}" ]; then
  codesign --sign "$AA_SIGN_IDENTITY" --timestamp "$OUT"
  if [ -n "${AA_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$AA_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
  fi
fi

# The app inside still has a valid signature, and everything is where the instructions say.
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$OUT"
codesign --verify --deep --strict "$MNT/$NAME.app"
[ -L "$MNT/Applications" ] && [ -f "$MNT/How to install.txt" ] && [ -f "$MNT/.background/background.tiff" ]
hdiutil detach -quiet "$MNT"

echo "Created $OUT (version $VERSION, $(du -h "$OUT" | cut -f1))"
