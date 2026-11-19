#!/bin/bash
# Builds "Auto Applicator Admin.app": your own tool for the cloud browser's AWS side (who is invited, what each
# person has and uses, the stack, the bill). It needs the AWS CLI with an administrator profile and this project
# folder, so it only makes sense on your Mac: releases never include it.
#   Usage:  bash scripts/build_admin.sh [output folder]     (default: build/)
# Then open "build/Auto Applicator Admin.app". Try the window without AWS: AA_ADMIN_DEMO=1 <app>/Contents/MacOS/AutoApplicatorAdmin
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/build}"
APP="$OUT_DIR/Auto Applicator Admin.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

echo "Compiling (release, arm64)…"
swift build --package-path "$ROOT" -c release --arch arm64 --product AutoApplicatorAdmin
BIN="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)/AutoApplicatorAdmin"

mkdir -p "$OUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoApplicatorAdmin"
[ ! -f "$ROOT/Resources/AppIcon.icns" ] || cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Auto Applicator Admin</string>
  <key>CFBundleExecutable</key><string>AutoApplicatorAdmin</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.grabbiel.autoapplicator.admin</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Auto Applicator Admin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
