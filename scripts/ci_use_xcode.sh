#!/bin/bash
# For GitHub's Mac machines: selects the newest released Xcode 27 or later, and stops if there is none. An Xcode 26 SDK
# builds a weaker app (see AppleModel.swift), so a release is never built with one.
set -euo pipefail
XCODE=$(ls -d /Applications/Xcode_2[7-9]*.app /Applications/Xcode_[3-9][0-9]*.app 2>/dev/null | grep -vi beta | sort -V | tail -1 || true)
if [ -z "$XCODE" ]; then
  echo "::error::This machine has no Xcode 27 or newer. Use the xcode-27 image, or publish from a Mac (README › Releases)."
  exit 1
fi
sudo xcode-select -s "$XCODE"
echo "Using $XCODE"
swift --version
