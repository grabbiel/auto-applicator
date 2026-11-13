#!/bin/bash
# Builds "Auto Applicator.app" (Apple silicon, macOS 14+) from the Swift package.
#   Usage:  bash scripts/build_app.sh [output folder]     (default: build/)
# Needs Xcode 26 or newer (its macOS SDK has Apple's on-device AI framework). The people you share the app with need
# nothing installed.
# Set AA_SIGN_IDENTITY="Developer ID Application: …" to sign for distribution (default: ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/build}"
APP="$OUT_DIR/Auto Applicator.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
if [ ! -d "$SDK/System/Library/Frameworks/FoundationModels.framework" ]; then
  echo "This SDK ($SDK) has no FoundationModels framework: install Xcode 26 or newer (xcode-select -s …)." >&2
  exit 1
fi

echo "Compiling (release, arm64)…"
swift build --package-path "$ROOT" -c release --arch arm64 --product AutoApplicator
BIN="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)/AutoApplicator"

mkdir -p "$OUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoApplicator"
strip -x "$APP/Contents/MacOS/AutoApplicator"

ICON="$ROOT/Resources/AppIcon.icns"
[ -f "$ICON" ] || swift "$ROOT/scripts/make_icon.swift" "$ROOT/Resources"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# The optional cloud browser's address (written by scripts/deploy_cloud.sh). AA_CLOUD_CONFIG can name another file,
# or "none" to leave it out (a copy for other people).
CLOUD_CONFIG="${AA_CLOUD_CONFIG:-$ROOT/Resources/CloudConfig.json}"
if [ "$CLOUD_CONFIG" != none ] && [ -f "$CLOUD_CONFIG" ]; then
  plutil -convert json -o /dev/null "$CLOUD_CONFIG"   # stops the build if it isn't valid JSON
  cp "$CLOUD_CONFIG" "$APP/Contents/Resources/CloudConfig.json"
  echo "Included the cloud browser settings."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Auto Applicator</string>
  <key>CFBundleExecutable</key><string>AutoApplicator</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.grabbiel.autoapplicator</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Auto Applicator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>io.github.grabbiel.autoapplicator.run</string>
      <key>CFBundleURLSchemes</key><array><string>autoapplicator</string></array>
    </dict>
  </array>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSRequiresNativeExecution</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Runs entirely on your Mac.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

xattr -cr "$APP"
if [ -n "${AA_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$AA_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc: required to run on Apple silicon
fi
codesign --verify --strict "$APP"
lipo -archs "$APP/Contents/MacOS/AutoApplicator" | grep -qx arm64
touch "$APP"
echo "Built: $APP (version $VERSION, $(du -sh "$APP" | cut -f1))"
