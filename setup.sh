#!/bin/bash
# For running from this source folder (developers). Builds "Auto Applicator.app" into build/ and opens it; the app
# installs its components and shows its setup screens. People you share the app with don't need this script:
# send them the disk image from `bash scripts/package.sh` (or the GitHub release).
# Needs the Xcode command line tools (`xcode-select --install`) for swiftc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/Library/Application Support/AutoApplicator/tools/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[ "$(uname)" = "Darwin" ] || { echo "Auto Applicator runs on macOS only."; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "Install uv first (https://docs.astral.sh/uv/), or just open a packaged Auto Applicator.app."; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "Install the Xcode command line tools first: xcode-select --install"; exit 1; }
(cd "$ROOT" && uv sync)
bash "$ROOT/scripts/build_app.sh" "$ROOT/build"
open "$ROOT/build/Auto Applicator.app"
