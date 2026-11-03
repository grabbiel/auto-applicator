"""Install/remove the launchd agent that runs the pipeline on a schedule."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from xml.sax.saxutils import escape

from .config import PROJECT_ROOT, Schedule, Settings

LABEL = "com.local.auto-applicator"
TEMPLATE = PROJECT_ROOT / "scripts" / f"{LABEL}.plist"
AGENT_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def _calendar_xml(s: Schedule) -> str:
    days = range(1, 6) if s.weekdays_only else [None]
    entries = []
    for d in days:
        weekday = f"<key>Weekday</key><integer>{d}</integer>" if d else ""
        entries.append(f"<dict><key>Hour</key><integer>{s.hour}</integer><key>Minute</key><integer>{s.minute}</integer>{weekday}</dict>")
    return "<array>\n        " + "\n        ".join(entries) + "\n    </array>"


def render_plist(settings: Settings, uv_path: str) -> str:
    path_env = os.pathsep.join(
        dict.fromkeys([str(Path(uv_path).parent), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    )
    replacements = {
        "__UV__": escape(uv_path),
        "__PROJECT__": escape(str(PROJECT_ROOT)),
        "__PATH__": escape(path_env),
        "__AA_HOME__": escape(str(settings.paths.home)),
        "__LOGS__": escape(str(settings.paths.logs_dir)),
        "__CALENDAR__": _calendar_xml(settings.config.schedule),
    }
    text = TEMPLATE.read_text(encoding="utf-8")
    for k, v in replacements.items():
        text = text.replace(k, v)
    return text


def _launchctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["launchctl", *args], capture_output=True, text=True)


def install(settings: Settings) -> Path:
    uv = shutil.which("uv") or next((p for p in ("/opt/homebrew/bin/uv", str(Path.home() / ".local/bin/uv")) if Path(p).exists()), None)
    if not uv:
        raise RuntimeError("Could not find the `uv` executable; run setup again.")
    AGENT_PATH.parent.mkdir(parents=True, exist_ok=True)
    AGENT_PATH.write_text(render_plist(settings, uv), encoding="utf-8")
    domain = f"gui/{os.getuid()}"
    _launchctl("bootout", f"{domain}/{LABEL}")
    proc = _launchctl("bootstrap", domain, str(AGENT_PATH))
    if proc.returncode != 0:
        raise RuntimeError(f"launchctl bootstrap failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return AGENT_PATH


def uninstall() -> bool:
    _launchctl("bootout", f"gui/{os.getuid()}/{LABEL}")
    if AGENT_PATH.exists():
        AGENT_PATH.unlink()
        return True
    return False


def is_installed() -> bool:
    return AGENT_PATH.exists()


def describe(s: Schedule) -> str:
    days = "every weekday" if s.weekdays_only else "every day"
    return f"{days} at {s.hour:02d}:{s.minute:02d}"
