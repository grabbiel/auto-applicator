"""Small macOS helpers: notifications and bringing the automation browser to the front."""

from __future__ import annotations

import logging
import subprocess
import sys
from pathlib import Path

log = logging.getLogger(__name__)


def _osa_quote(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(title: str, message: str, *, sound: str | None = "Glass") -> None:
    if sys.platform != "darwin":
        return
    script = f"display notification {_osa_quote(message)} with title {_osa_quote(title)}"
    if sound:
        script += f" sound name {_osa_quote(sound)}"
    subprocess.run(["osascript", "-e", script], check=False, capture_output=True, timeout=10)


def app_bundle_for(executable: str | Path) -> Path | None:
    """'/x/Google Chrome for Testing.app/Contents/MacOS/...' -> '/x/Google Chrome for Testing.app'."""
    p = Path(executable)
    for parent in [p, *p.parents]:
        if parent.suffix == ".app":
            return parent
    return None


def activate_app(bundle: Path | None) -> None:
    """Bring an app to the foreground (equivalent of `tell application ... to activate`)."""
    if sys.platform != "darwin" or bundle is None:
        return
    subprocess.run(["open", "-a", str(bundle)], check=False, capture_output=True, timeout=10)


def is_interactive() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty()


def open_in_finder(path: Path) -> None:
    subprocess.run(["open", str(path)], check=False)
