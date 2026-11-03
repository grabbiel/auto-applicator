"""The native app's link to the Python side: JSON lines over standard input and output.

Auto Applicator.app (macos/App) starts `python -m src.main --app-backend` and talks to it through its pipes, so
nothing listens on the network and no browser page is involved. Each request is one line
`{"id": 1, "method": "state", "params": {...}}` and gets one reply line `{"id": 1, "result": ...}` or
`{"id": 1, "error": "message"}`. Requests run on worker threads, so a slow one (an email test) doesn't hold up the
others. The process exits when the app closes its end of the pipe.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable, TextIO

from . import __version__
from .answers import coerce_answer
from .config import Paths
from .db import Database
from .llm import FieldSpec
from .setup_gui import MAX_RESUME_BYTES, SetupApp, merge_extraction

log = logging.getLogger(__name__)

STATUS_LABELS = {
    "APPLIED": "Applied",
    "DRY_RUN_COMPLETE": "Practice: filled in, not sent",
    "SKIPPED_NEEDS_ANSWER": "Waiting for your answer",
    "SKIPPED_BLACKLIST": "Skipped: company on your list",
    "SKIPPED_TITLE_FILTER": "Skipped: job title filter",
    "SKIPPED_ALREADY_APPLIED": "Already applied",
    "FAILED_OTP_TIMEOUT": "Didn't finish: no email code arrived",
    "FAILED_CHALLENGE": "Didn't finish: the site asked to verify you're human",
    "FAILED_FORM_ERROR": "Didn't finish: problem with the form",
}
CHROME_EPOCH_OFFSET = 11_644_473_600  # seconds between 1601-01-01 (Chrome's cookie clock) and 1970-01-01


def linkedin_signed_in(paths: Paths) -> bool:
    """Whether the app's browser profile holds an unexpired LinkedIn session cookie (read-only, works while it runs)."""
    for db in (paths.chrome_profile / "Default" / "Network" / "Cookies", paths.chrome_profile / "Default" / "Cookies"):
        if not db.exists():
            continue
        try:
            con = sqlite3.connect(f"{db.as_uri()}?mode=ro&immutable=1", uri=True)
            try:
                row = con.execute(
                    "SELECT expires_utc FROM cookies WHERE name = 'li_at' AND host_key LIKE '%linkedin.com' "
                    "ORDER BY expires_utc DESC LIMIT 1"
                ).fetchone()
            finally:
                con.close()
        except sqlite3.Error:
            continue
        if row:
            return row[0] == 0 or row[0] > (time.time() + CHROME_EPOCH_OFFSET) * 1_000_000
    return False


class Bridge:
    def __init__(self, app: SetupApp):
        self.app = app
        self.methods: dict[str, Callable[[dict[str, Any]], Any]] = {
            "hello": self.hello,
            "state": self.state,
            "install": self.install,
            "set_draft": self.set_draft,
            "resume": self.resume,
            "import_resume": self.import_resume,
            "merge_import": self.merge_import,
            "test_email": self.test_email,
            "save": self.save,
            "linkedin": self.linkedin,
            "pending": self.pending,
            "answer": self.answer,
            "dismiss": self.dismiss,
            "results": self.results,
            "set_schedule": self.set_schedule,
        }

    def handle(self, line: str) -> str | None:
        try:
            request = json.loads(line)
            rid, method, params = request.get("id"), request["method"], request.get("params") or {}
        except (ValueError, KeyError, AttributeError):
            return json.dumps({"id": None, "error": "Bad request"})
        handler = self.methods.get(method)
        if handler is None:
            return json.dumps({"id": rid, "error": f"Unknown method: {method}"})
        try:
            return json.dumps({"id": rid, "result": handler(params)})
        except Exception as e:  # noqa: BLE001 – report to the app instead of dying
            log.exception("App request failed: %s", method)
            return json.dumps({"id": rid, "error": f"Something went wrong: {e}"})

    # ------------------------------------------------------------------ methods

    def hello(self, _: dict[str, Any]) -> dict[str, Any]:
        return {"version": __version__, "options": self.app.options(), "draft": self.app.draft, "state": self.state({})}

    def state(self, _: dict[str, Any]) -> dict[str, Any]:
        state = self.app.state()
        db = Database(self.app.paths.db_file)
        try:
            state["pending_count"] = len(db.list_pending())
        finally:
            db.close()
        state["linkedin_signed_in"] = linkedin_signed_in(self.app.paths)
        state["screenshots"] = str(self.app.paths.screenshots_dir)
        return state

    def install(self, _: dict[str, Any]) -> dict[str, Any]:
        self.app.installer.start()  # also retries failed steps
        return {"ok": True}

    def set_draft(self, p: dict[str, Any]) -> dict[str, Any]:
        self.app.draft = p["draft"]
        return {"ok": True}

    def resume(self, p: dict[str, Any]) -> dict[str, Any]:
        path = Path(str(p.get("path") or ""))
        if not path.is_file():
            return {"ok": False, "message": "That file couldn't be found."}
        if path.stat().st_size > MAX_RESUME_BYTES:
            return {"ok": False, "message": "That file is too big (over 25 MB)."}
        return self.app.upload_resume(path.read_bytes(), str(p.get("name") or path.name), bool(p.get("read")))

    def import_resume(self, _: dict[str, Any]) -> dict[str, Any]:
        if self.app.resume_path.exists():
            self.app.imports.start()
        return {"ok": self.app.resume_path.exists()}

    def merge_import(self, p: dict[str, Any]) -> dict[str, Any]:
        result = self.app.imports.result
        draft = merge_extraction(p["draft"], result) if result else p["draft"]
        self.app.draft = draft
        return {"draft": draft}

    def test_email(self, p: dict[str, Any]) -> dict[str, Any]:
        return self.app.test_email(str(p.get("address", "")), str(p.get("password", "")), str(p.get("host", "")))

    def save(self, p: dict[str, Any]) -> dict[str, Any]:
        return self.app.save(p["draft"])

    def linkedin(self, _: dict[str, Any]) -> dict[str, Any]:
        self.app.login.start()
        return {"ok": True}

    def pending(self, _: dict[str, Any]) -> list[dict[str, Any]]:
        db = Database(self.app.paths.db_file)
        try:
            return [
                {"hash": q["question_hash"], "question": q["question_text"], "field_type": q["field_type"],
                 "options": q["options"], "companies": q["companies"][:6]}
                for q in db.list_pending()
            ]  # fmt: skip
        finally:
            db.close()

    def answer(self, p: dict[str, Any]) -> dict[str, Any]:
        db = Database(self.app.paths.db_file)
        try:
            q = next((q for q in db.list_pending() if q["question_hash"] == p.get("hash")), None)
            if q is None:
                return {"ok": False, "message": "That question was already answered."}
            spec = FieldSpec(field_id="q", label=q["question_text"], field_type=q["field_type"], options=q["options"])
            value = coerce_answer(spec, str(p.get("answer") or "").strip())
            if value is None:
                hint = "Please enter a number." if q["field_type"] == "number" else "Please choose or type an answer."
                return {"ok": False, "message": "That answer doesn't fit this question. " + hint}
            db.resolve_pending(q["question_hash"], value)
            return {"ok": True}
        finally:
            db.close()

    def dismiss(self, p: dict[str, Any]) -> dict[str, Any]:
        db = Database(self.app.paths.db_file)
        try:
            db.dismiss_pending(str(p.get("hash") or ""))
            return {"ok": True}
        finally:
            db.close()

    def results(self, _: dict[str, Any]) -> dict[str, Any]:
        db = Database(self.app.paths.db_file)
        try:
            counts = db.status_counts()
            jobs = db.recent_jobs(100)
        finally:
            db.close()
        return {
            "counts": [{"status": s, "label": STATUS_LABELS.get(s, s), "count": n} for s, n in counts.items()],
            "jobs": [
                {"id": j["job_id"], "when": (j["updated_at"] or "")[:16].replace("T", " "), "company": j["company"] or "",
                 "title": j["title"] or "", "status": j["status"] or "", "label": STATUS_LABELS.get(j["status"], j["status"] or ""),
                 "notes": j["notes"] or "", "url": j["url"] or ""}
                for j in jobs
            ],
        }  # fmt: skip

    def set_schedule(self, p: dict[str, Any]) -> dict[str, Any]:
        if not self.app.saved:
            return {"ok": False, "message": "Finish setting up first."}
        enabled = bool(p.get("enabled"))
        warnings = self.app._apply_schedule(enabled)
        if not warnings:
            self.app.draft["search"]["schedule_enabled"] = enabled
        return {"ok": not warnings, "message": " ".join(warnings)}


def serve(paths: Paths, stdin: TextIO | None = None, stdout: TextIO | None = None) -> int:
    if stdout is None:
        stdout = os.fdopen(os.dup(1), "w", encoding="utf-8")
        os.dup2(2, 1)  # anything else that prints (libraries, child processes) goes to the log, not into the protocol
    stdin = stdin or sys.stdin
    bridge = Bridge(SetupApp(paths))
    write_lock = threading.Lock()

    def respond(line: str) -> None:
        reply = bridge.handle(line)
        if reply is not None:
            with write_lock:
                stdout.write(reply + "\n")
                stdout.flush()

    log.info("App backend started (version %s)", __version__)
    with ThreadPoolExecutor(max_workers=6, thread_name_prefix="app-request") as pool:
        for line in stdin:
            if line.strip():
                pool.submit(respond, line)
    log.info("App closed; backend exiting")
    return 0
