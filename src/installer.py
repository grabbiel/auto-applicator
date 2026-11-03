"""Installs the heavy components on first launch: the browser engine, the local AI runtime (Ollama) and the model.

Used by the app's setup screens, which show each step's progress. Every step is idempotent: re-running it skips work
that's already done, so "Retry" after a network error just continues.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import threading
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Literal

from .config import PROJECT_ROOT, LLMSettings, default_home

log = logging.getLogger(__name__)

OLLAMA_URL = "https://github.com/ollama/ollama/releases/latest/download/ollama-darwin.tgz"
OLLAMA_API = "http://127.0.0.1:11434"
MODEL_SIZES_GB = {"qwen2.5:7b": 4.7, "qwen2.5:14b": 9.0, "qwen2.5:3b": 1.9}

StepStatus = Literal["waiting", "running", "done", "error"]


def tools_dir() -> Path:
    """Where the app keeps tools it downloaded itself (uv, Ollama) when they aren't already installed."""
    return default_home() / "tools"


class InstallError(RuntimeError):
    """A user-facing installation problem."""


@dataclass
class Step:
    key: str
    title: str
    detail: str = ""
    status: StepStatus = "waiting"
    progress: float | None = None  # 0..1 when known
    error: str = ""


@dataclass
class Installer:
    """Runs the install steps in a background thread and exposes their state for the app."""

    llm: LLMSettings
    browser_channel: str = "chromium"
    steps: list[Step] = field(default_factory=list)

    def __post_init__(self) -> None:
        size = MODEL_SIZES_GB.get(self.llm.text_model)
        self.steps = [
            Step("browser", "Browser for applications", "A private browser, separate from your own"),
            Step("engine", "AI engine (Ollama)", "Runs the AI on this Mac – nothing is sent online"),
            Step("model", "AI model", f"{self.llm.text_model}" + (f" · {size:g} GB download" if size else "")),
        ]
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self.done = threading.Event()

    # ------------------------------------------------------------------ control

    def start(self) -> None:
        with self._lock:
            if self._thread and self._thread.is_alive():
                return
            for s in self.steps:
                if s.status == "error":
                    s.status, s.error, s.progress = "waiting", "", None
            self._thread = threading.Thread(target=self._run, name="installer", daemon=True)
            self._thread.start()

    @property
    def failed(self) -> bool:
        return any(s.status == "error" for s in self.steps)

    @property
    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    def step(self, key: str) -> Step:
        return next(s for s in self.steps if s.key == key)

    def snapshot(self) -> dict:
        # The model download is by far the biggest step, so weight it more in the overall bar.
        weights = {"browser": 1.0, "engine": 1.0, "model": 6.0}
        total = sum(weights.values())
        overall = sum(
            weights[s.key] * (1.0 if s.status == "done" else (s.progress or 0.0) * 0.95) for s in self.steps
        ) / total
        return {
            "done": self.done.is_set(),
            "failed": self.failed,
            "running": self.running,
            "overall": round(overall, 3),
            "steps": [asdict(s) for s in self.steps],
        }

    def _run(self) -> None:
        actions: dict[str, Callable[[Step], None]] = {
            "browser": self._install_browser,
            "engine": self._install_engine,
            "model": self._install_model,
        }
        for s in self.steps:
            if s.status == "done":
                continue
            s.status, s.progress = "running", None
            try:
                actions[s.key](s)
            except Exception as e:  # noqa: BLE001 – every failure is shown to the user with a Retry button
                log.exception("Install step %s failed", s.key)
                s.status, s.error = "error", friendly_error(e)
                return
            s.status, s.progress = "done", 1.0
        self.done.set()

    # ------------------------------------------------------------------ steps

    def _install_browser(self, s: Step) -> None:
        if self.browser_channel == "chrome":
            s.detail = "Using your installed Google Chrome"
            return
        cmd = [sys.executable, "-m", "playwright", "install", "--no-shell", "chromium"]  # the app never runs headless
        proc = subprocess.Popen(cmd, cwd=PROJECT_ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert proc.stdout
        tail: list[str] = []
        buf = b""
        while chunk := proc.stdout.read(256):
            buf += chunk
            *lines, buf = re.split(rb"[\r\n]", buf)
            for raw in lines:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                tail = (tail + [line])[-5:]
                if m := re.search(r"(\d{1,3})%", line):
                    s.progress = min(int(m.group(1)), 100) / 100
        if proc.wait() != 0:
            raise InstallError("Couldn't download the browser. " + " ".join(tail[-2:]))

    def _install_engine(self, s: Step) -> None:
        from .llm import ollama_binary, start_ollama

        if not ollama_running():
            if not (Path("/Applications/Ollama.app").exists() or ollama_binary()):
                s.detail = "Downloading…"
                download_ollama(lambda p: setattr(s, "progress", p))
            s.detail, s.progress = "Starting…", None
            if not start_ollama(wait_sec=40):
                raise InstallError("The AI engine didn't start. Restart your Mac and open Auto Applicator again.")
        s.detail = "Running on this Mac"

    def _install_model(self, s: Step) -> None:
        name = self.llm.text_model
        if not model_installed(name):
            pull_model(name, lambda p: setattr(s, "progress", p))
        s.detail, s.progress = "Preparing…", None
        self._prepare_model()
        s.detail = f"{name} ready"

    def _prepare_model(self) -> None:
        import asyncio

        from .llm import LLMClient, LLMError

        try:
            asyncio.run(LLMClient(self.llm).ensure_ready())
        except LLMError as e:
            raise InstallError(str(e)) from e


# --------------------------------------------------------------------------- helpers


def friendly_error(e: Exception) -> str:
    msg = str(e) or e.__class__.__name__
    if "No space left" in msg:
        return "Your Mac is out of disk space. Free up about 10 GB, then press Retry."
    if isinstance(e, (urllib.error.URLError, ConnectionError, TimeoutError)):
        return f"Couldn't download a component – check your internet connection, then press Retry. ({msg})"
    return msg


def _api(path: str, timeout: float = 5) -> dict:
    with urllib.request.urlopen(f"{OLLAMA_API}{path}", timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def ollama_running() -> bool:
    try:
        _api("/api/version", timeout=2)
        return True
    except OSError:
        return False


def model_installed(name: str) -> bool:
    try:
        names = {m.get("name") for m in _api("/api/tags").get("models", [])}
    except OSError:
        return False
    return name in names or (":" not in name and f"{name}:latest" in names)


def pull_model(name: str, on_progress: Callable[[float], None]) -> None:
    """Download a model through Ollama's API, reporting overall progress across its layers."""
    req = urllib.request.Request(
        f"{OLLAMA_API}/api/pull", data=json.dumps({"model": name, "stream": True}).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    layers: dict[str, tuple[int, int]] = {}
    with urllib.request.urlopen(req, timeout=120) as r:
        for raw in r:
            if not raw.strip():
                continue
            event = json.loads(raw)
            if err := event.get("error"):
                raise InstallError(f"Couldn't download the AI model: {err}")
            if (digest := event.get("digest")) and event.get("total"):
                layers[digest] = (int(event.get("completed") or 0), int(event["total"]))
                done = sum(c for c, _ in layers.values())
                total = sum(t for _, t in layers.values())
                on_progress(done / total if total else 0.0)
            if event.get("status") == "success":
                return
    if not model_installed(name):
        raise InstallError("The AI model download stopped before finishing. Press Retry to continue it.")


def download_ollama(on_progress: Callable[[float], None], url: str = OLLAMA_URL) -> Path:
    """Download the official Ollama command-line build into the app's tools folder; returns the binary."""
    dest = tools_dir() / "ollama"
    archive = tools_dir() / "ollama-darwin.tgz.part"
    tools_dir().mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=60) as r, open(archive, "wb") as out:
        total = int(r.headers.get("Content-Length") or 0)
        got = 0
        while chunk := r.read(1 << 20):
            out.write(chunk)
            got += len(chunk)
            if total:
                on_progress(got / total)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        tar.extractall(dest, filter="data")
    archive.unlink()
    binary = find_ollama_in(dest)
    if not binary:
        raise InstallError("The downloaded AI engine looks incomplete. Press Retry.")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return binary


def find_ollama_in(folder: Path) -> Path | None:
    candidates = [p for p in folder.rglob("ollama") if p.is_file()]
    return min(candidates, key=lambda p: len(p.parts)) if candidates else None


def bundled_ollama() -> Path | None:
    folder = tools_dir() / "ollama"
    return find_ollama_in(folder) if folder.is_dir() else None


def memory_gb() -> float:
    try:
        return int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) / 2**30
    except (ValueError, OSError):
        return 16.0


def recommended_model() -> str:
    """qwen2.5:7b (~5 GB in memory) fits 16 GB Macs alongside the browser; 32 GB+ can afford the 14b model."""
    return os.environ.get("AA_DEFAULT_MODEL") or ("qwen2.5:14b" if memory_gb() >= 32 else "qwen2.5:7b")
