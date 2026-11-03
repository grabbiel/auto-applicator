from __future__ import annotations

import io
import json
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from src import installer
from src.config import LLMSettings


@pytest.fixture
def tools(tmp_path, monkeypatch):
    monkeypatch.setenv("AA_HOME", str(tmp_path / "home"))
    return tmp_path / "home" / "tools"


def test_download_ollama_extracts_flat_archive(tmp_path, tools):
    archive = tmp_path / "ollama-darwin.tgz"
    with tarfile.open(archive, "w:gz") as tar:
        for name, data in (("ollama", b"#!/bin/sh\necho ok\n"), ("libggml.dylib", b"lib")):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    progress: list[float] = []
    binary = installer.download_ollama(progress.append, url=archive.as_uri())
    assert binary == tools / "ollama" / "ollama" and binary.stat().st_mode & 0o111
    assert installer.bundled_ollama() == binary
    assert progress and progress[-1] == 1.0
    assert not (tools / "ollama-darwin.tgz.part").exists()


class FakeOllama(BaseHTTPRequestHandler):
    events: list[dict] = []
    installed: set[str] = set()

    def log_message(self, *args):  # silence
        pass

    def do_GET(self):  # noqa: N802
        body = json.dumps({"models": [{"name": n} for n in self.installed]} if self.path == "/api/tags" else {"version": "1"})
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body.encode())

    def do_POST(self):  # noqa: N802
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.end_headers()
        for e in self.events:
            self.wfile.write((json.dumps(e) + "\n").encode())


@pytest.fixture
def fake_ollama(monkeypatch):
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    monkeypatch.setattr(installer, "OLLAMA_API", f"http://127.0.0.1:{httpd.server_address[1]}")
    yield FakeOllama
    httpd.shutdown()


def test_pull_model_reports_progress_across_layers(fake_ollama):
    fake_ollama.events = [
        {"status": "pulling manifest"},
        {"status": "pulling a", "digest": "a", "total": 300, "completed": 150},
        {"status": "pulling b", "digest": "b", "total": 100, "completed": 0},
        {"status": "pulling a", "digest": "a", "total": 300, "completed": 300},
        {"status": "pulling b", "digest": "b", "total": 100, "completed": 100},
        {"status": "success"},
    ]
    seen: list[float] = []
    installer.pull_model("qwen2.5:7b", seen.append)
    assert seen == [0.5, 150 / 400, 300 / 400, 1.0]


def test_pull_model_error_is_reported(fake_ollama):
    fake_ollama.events = [{"error": "pull model manifest: file does not exist"}]
    with pytest.raises(installer.InstallError, match="does not exist"):
        installer.pull_model("nope:1b", lambda p: None)


def test_model_installed(fake_ollama):
    fake_ollama.installed = {"qwen2.5:7b", "llama3:latest"}
    assert installer.ollama_running()
    assert installer.model_installed("qwen2.5:7b") and installer.model_installed("llama3")
    assert not installer.model_installed("qwen2.5:14b")


def test_installer_runs_steps_in_order_and_retries(monkeypatch):
    inst = installer.Installer(LLMSettings())
    ran: list[str] = []
    fail_once = {"engine": True}

    def step(key):
        def run(s):
            ran.append(key)
            if fail_once.pop(key, False):
                raise ConnectionError("network down")
            s.progress = 0.5
        return run

    for key in ("browser", "engine", "model"):
        monkeypatch.setattr(inst, f"_install_{key}", step(key))
    inst.start()
    inst._thread.join(5)
    snap = inst.snapshot()
    assert snap["failed"] and not snap["done"] and ran == ["browser", "engine"]
    assert "internet connection" in inst.step("engine").error
    assert inst.step("model").status == "waiting"

    inst.start()  # Retry: finished steps are skipped
    inst._thread.join(5)
    assert inst.done.is_set() and ran == ["browser", "engine", "engine", "model"]
    assert inst.snapshot()["overall"] == 1.0


def test_recommended_model(monkeypatch):
    monkeypatch.delenv("AA_DEFAULT_MODEL", raising=False)
    monkeypatch.setattr(installer, "memory_gb", lambda: 16.0)
    assert installer.recommended_model() == "qwen2.5:7b"
    monkeypatch.setattr(installer, "memory_gb", lambda: 64.0)
    assert installer.recommended_model() == "qwen2.5:14b"
    monkeypatch.setenv("AA_DEFAULT_MODEL", "qwen2.5:3b")
    assert installer.recommended_model() == "qwen2.5:3b"
