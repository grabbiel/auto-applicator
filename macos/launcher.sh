#!/bin/bash
# Helper for "Auto Applicator.app" (the native app in macos/App runs it from inside its bundle).
#
#   launcher.sh install-code <dir>  copy the app's code out of the .app bundle into the support folder (when new/updated)
#   launcher.sh state               print "<ready|needs-install> <profile|no-profile>"
#   launcher.sh bootstrap           install uv, Python and the app's components; progress goes to install-status.txt
#
# AA_HOME overrides the support folder (for testing on a Mac that already has a real setup).
#
# Nothing here needs admin rights, Homebrew or the Xcode tools: uv is downloaded from its official GitHub
# release (checksum-verified) into the support folder when it isn't installed already.
set -uo pipefail

SUPPORT="${AA_HOME:-$HOME/Library/Application Support/AutoApplicator}"
APP_DIR="$SUPPORT/app"
TOOLS="$SUPPORT/tools"
STATUS="$SUPPORT/install-status.txt"
LOGS="$SUPPORT/logs"
export PATH="$TOOLS/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

status() {  # state percent message  (one line, tab-separated: the app reads it while this runs)
  printf '%s\t%s\t%s' "$1" "$2" "$3" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
}
fail() {
  status error 0 "$1"
  exit 1
}

case "${1:-}" in
  install-code)
    src="${2:?bundled app folder}"
    want="$(cat "$src/.build-stamp" 2>/dev/null || echo unknown)"
    have="$(cat "$APP_DIR/.build-stamp" 2>/dev/null || true)"
    if [ "$want" != "$have" ] || [ ! -f "$APP_DIR/aa" ]; then
      mkdir -p "$APP_DIR"
      chmod 700 "$SUPPORT"
      # Replace the code but keep the installed Python environment (.venv); "bootstrap" brings it up to date.
      find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name .venv -exec rm -rf {} +
      rm -f "$APP_DIR/.venv/.aa-ready"
      ditto --noqtn "$src" "$APP_DIR"
      xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
      chflags hidden "$APP_DIR" 2>/dev/null || true
    fi
    ;;

  state)
    ready=needs-install
    if command -v uv >/dev/null 2>&1 && [ -f "$APP_DIR/.venv/.aa-ready" ]; then ready=ready; fi
    profile=no-profile
    [ -f "$SUPPORT/profile.yaml" ] && profile=profile
    echo "$ready $profile"
    ;;

  bootstrap)
    mkdir -p "$LOGS"
    log="$LOGS/install.log"
    echo "=== $(date) bootstrap" >>"$log"
    status running 3 "Getting started…"
    free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
    [ "${free_gb:-0}" -ge 8 ] || fail "Your Mac needs about 10 GB of free space for Auto Applicator (it has ${free_gb:-0} GB). Free up some space, then open Auto Applicator again."

    if ! command -v uv >/dev/null 2>&1; then
      status running 8 "Downloading the Python tools…"
      [ "$(uname -m)" = "arm64" ] && arch=aarch64 || arch=x86_64
      url="https://github.com/astral-sh/uv/releases/latest/download/uv-$arch-apple-darwin.tar.gz"
      tmp="$(mktemp -d)"
      curl -fsSL --retry 3 -o "$tmp/uv.tar.gz" "$url" >>"$log" 2>&1 \
        && curl -fsSL --retry 3 -o "$tmp/uv.tar.gz.sha256" "$url.sha256" >>"$log" 2>&1 \
        || fail "Couldn't download the Python tools. Check your internet connection, then open Auto Applicator again."
      expected="$(awk '{print $1}' "$tmp/uv.tar.gz.sha256")"
      actual="$(shasum -a 256 "$tmp/uv.tar.gz" | awk '{print $1}')"
      [ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "The Python tools download was damaged. Please open Auto Applicator again."
      mkdir -p "$TOOLS/bin"
      tar -xzf "$tmp/uv.tar.gz" -C "$tmp" && cp "$tmp"/uv-*/uv "$TOOLS/bin/" && chmod 755 "$TOOLS/bin/uv" \
        || fail "Couldn't install the Python tools."
      rm -rf "$tmp"
      chflags hidden "$TOOLS" 2>/dev/null || true
    fi

    cd "$APP_DIR" || fail "The app's files are missing. Open Auto Applicator again."
    status running 30 "Downloading Python…"
    uv python install >>"$log" 2>&1 || fail "Couldn't download Python. Check your internet connection, then open Auto Applicator again."
    status running 60 "Installing the app's components (about a minute)…"
    uv sync --no-dev --frozen >>"$log" 2>&1 \
      || fail "Couldn't install the app's components. Check your internet connection, then open Auto Applicator again. Details: $log"
    touch "$APP_DIR/.venv/.aa-ready"
    status done 100 "Ready"
    ;;

  *)
    echo "usage: launcher.sh install-code <dir> | state | bootstrap" >&2
    exit 2
    ;;
esac
