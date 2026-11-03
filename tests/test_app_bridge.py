from __future__ import annotations

import io
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

from src import setup_gui
from src.app_bridge import CHROME_EPOCH_OFFSET, Bridge, linkedin_signed_in, serve
from src.config import Paths
from src.db import Database

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(autouse=True)
def no_launchd(monkeypatch):
    monkeypatch.setattr(setup_gui.schedule, "is_installed", lambda: False)
    monkeypatch.setattr(setup_gui.schedule, "install", lambda settings: None)
    monkeypatch.setattr(setup_gui.schedule, "uninstall", lambda: None)


@pytest.fixture
def paths(tmp_path, monkeypatch) -> Paths:
    monkeypatch.setenv("AA_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("AA_DEFAULT_MODEL", "qwen2.5:7b")
    for var in ("IMAP_HOST", "IMAP_PORT", "IMAP_USER", "IMAP_APP_PASSWORD", "ATS_DEFAULT_PASSWORD"):
        monkeypatch.delenv(var, raising=False)
    return Paths(tmp_path / "home").ensure()


@pytest.fixture
def bridge(paths) -> Bridge:
    return Bridge(setup_gui.SetupApp(paths))


def call(bridge: Bridge, method: str, **params):
    reply = json.loads(bridge.handle(json.dumps({"id": 7, "method": method, "params": params})))
    assert reply["id"] == 7
    return reply


def test_hello_returns_draft_options_and_state(bridge):
    result = call(bridge, "hello")["result"]
    assert result["state"]["mode"] == "first" and result["state"]["pending_count"] == 0
    assert result["state"]["linkedin_signed_in"] is False
    assert {"value": "past_week", "label": "The last week"} in result["options"]["dates"]
    assert set(result["draft"]) == {"profile", "search", "email"}


def test_bad_requests_get_error_replies(bridge):
    assert json.loads(bridge.handle("not json"))["error"] == "Bad request"
    assert call(bridge, "nope")["error"] == "Unknown method: nope"
    assert call(bridge, "save")["error"].startswith("Something went wrong")  # missing draft


def test_set_draft_and_resume_file(bridge, tmp_path):
    draft = call(bridge, "hello")["result"]["draft"]
    draft["profile"]["personal"]["first_name"] = "Ana"
    assert call(bridge, "set_draft", draft=draft)["result"] == {"ok": True}
    assert bridge.app.draft["profile"]["personal"]["first_name"] == "Ana"

    assert call(bridge, "resume", path=str(tmp_path / "missing.pdf"))["result"]["ok"] is False
    pdf = tmp_path / "Ana Resume.pdf"
    pdf.write_bytes(b"%PDF-1.4 fake")
    assert call(bridge, "resume", path=str(pdf), name=pdf.name, read=False)["result"]["ok"] is True
    assert call(bridge, "state")["result"]["resume"]["present"] is True


def test_questions_answer_and_dismiss(bridge, paths):
    db = Database(paths.db_file)
    db.upsert_job("41", status="SKIPPED_NEEDS_ANSWER", title="Analyst", company="Summit Health")
    db.add_pending("h1", "Years with Looker?", "number", [], "41", "Summit Health")
    db.add_pending("h2", "Can you commute?", "radio", ["Yes", "No"], "41", "Summit Health")
    db.close()

    pending = call(bridge, "pending")["result"]
    assert {q["hash"] for q in pending} == {"h1", "h2"}
    assert all(q["companies"] == ["Summit Health"] for q in pending)
    assert call(bridge, "state")["result"]["pending_count"] == 2

    bad = call(bridge, "answer", hash="h1", answer="lots")["result"]
    assert bad["ok"] is False and "number" in bad["message"]
    assert call(bridge, "answer", hash="h1", answer="2")["result"] == {"ok": True}
    assert call(bridge, "answer", hash="h1", answer="3")["result"]["ok"] is False  # already answered
    assert call(bridge, "dismiss", hash="h2")["result"] == {"ok": True}
    assert call(bridge, "pending")["result"] == []

    results = call(bridge, "results")["result"]
    assert results["jobs"][0]["company"] == "Summit Health"
    assert results["jobs"][0]["label"] == "Waiting for your answer"
    assert {"status": "SKIPPED_NEEDS_ANSWER", "label": "Waiting for your answer", "count": 1} in results["counts"]


def test_schedule_needs_setup_first(bridge):
    assert call(bridge, "set_schedule", enabled=True)["result"]["ok"] is False


def _cookie_db(paths: Paths, expires_utc: int) -> None:
    db = paths.chrome_profile / "Default" / "Network" / "Cookies"
    db.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE cookies (host_key TEXT, name TEXT, expires_utc INTEGER)")
    con.execute("INSERT INTO cookies VALUES ('.www.linkedin.com', 'li_at', ?)", (expires_utc,))
    con.commit()
    con.close()


def test_linkedin_signed_in_reads_the_session_cookie(paths):
    assert linkedin_signed_in(paths) is False
    _cookie_db(paths, int((time.time() + CHROME_EPOCH_OFFSET + 86_400) * 1_000_000))
    assert linkedin_signed_in(paths) is True


def test_linkedin_expired_cookie_is_signed_out(paths):
    _cookie_db(paths, int((time.time() + CHROME_EPOCH_OFFSET - 86_400) * 1_000_000))
    assert linkedin_signed_in(paths) is False


def test_serve_answers_each_line(paths):
    stdin = io.StringIO('{"id": 1, "method": "hello"}\n\n{"id": 2, "method": "pending"}\n')
    stdout = io.StringIO()
    assert serve(paths, stdin=stdin, stdout=stdout) == 0
    replies = {r["id"]: r for r in map(json.loads, stdout.getvalue().splitlines())}
    assert set(replies) == {1, 2} and replies[2]["result"] == []


def test_backend_process_speaks_clean_json(paths):
    """The real entry point: only protocol lines on stdout, and it exits when its input closes."""
    env = {k: v for k, v in os.environ.items() if k not in ("VIRTUAL_ENV", "PYTHONPATH")}
    env |= {"AA_HOME": str(paths.home), "AA_DEFAULT_MODEL": "qwen2.5:7b", "NO_COLOR": "1"}
    proc = subprocess.run(
        [sys.executable, "-m", "src.main", "--app-backend"],
        input='{"id": 1, "method": "hello"}\n', capture_output=True, text=True, cwd=ROOT, env=env, timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    assert len(lines) == 1 and json.loads(lines[0])["result"]["state"]["mode"] == "first"
