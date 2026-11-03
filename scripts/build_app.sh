#!/bin/bash
# Builds "Auto Applicator.app": the native macOS app (Swift, in macos/App) carrying the Python code inside it
# (Contents/Resources/app), which it installs into ~/Library/Application Support/AutoApplicator on first launch.
#   Usage:  bash scripts/build_app.sh [output folder]     (default: the project folder)
# Needs the Xcode command line tools (swiftc). The people you share the app with don't need them.
# Set AA_SIGN_IDENTITY="Developer ID Application: …" to sign for distribution (default: ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT}"
APP="$OUT_DIR/Auto Applicator.app"
PAYLOAD="$APP/Contents/Resources/app"
VERSION=$(awk -F'"' '/^version/ {print $2; exit}' "$ROOT/pyproject.toml")
# Only these are bundled (an allowlist): never your settings, keys, resumes or anything else in this folder.
INCLUDE=(README.md pyproject.toml uv.lock .python-version .env.example config.yaml profile.example.yaml aa src scripts macos)

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
SDK="$(xcrun --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos13.0" -sdk "$SDK" \
    "$ROOT"/macos/App/*.swift -o "$BUILD/AutoApplicator-$arch"
done

mkdir -p "$OUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$PAYLOAD"
lipo -create "$BUILD/AutoApplicator-arm64" "$BUILD/AutoApplicator-x86_64" -output "$APP/Contents/MacOS/AutoApplicator"

for item in "${INCLUDE[@]}"; do
  [ -e "$ROOT/$item" ] || { echo "Missing $item"; exit 1; }
  rsync -a --exclude '__pycache__/' --exclude '.DS_Store' --exclude '*.pyc' --exclude 'App/' "$ROOT/$item" "$PAYLOAD/"
done

# Safety net: refuse to bundle anything that looks personal or secret.
LEAKS=$(cd "$PAYLOAD" && find . \( -name '.env' -o -name 'profile.yaml' -o -name '*.db' -o -name 'chrome_profile' \
          -o -name '*.log' -o -iname '*key*' -o -iname '*secret*' -o -iname '*token*' -o -iname '*.pdf' \) -print)
[ -z "$LEAKS" ] || { echo "Refusing to bundle possibly personal files:"; echo "$LEAKS"; rm -rf "$APP"; exit 1; }

# A fingerprint of the bundled code: an installed copy is refreshed when it changes.
(cd "$PAYLOAD" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16) \
  > "$PAYLOAD/.build-stamp"

# Icon (drawn by scripts/make_icon.py; skipped if the dev environment isn't installed yet)
if uv run --project "$ROOT" --quiet python "$ROOT/scripts/make_icon.py" "$BUILD/AppIcon.iconset" 2>/dev/null \
   && iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then :; fi

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
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
if [ -n "${AA_SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$AA_SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"   # ad-hoc: required to run on Apple Silicon
fi
codesign --verify --deep --strict "$APP"
touch "$APP"
echo "Built: $APP ($(du -sh "$APP" | cut -f1))"
