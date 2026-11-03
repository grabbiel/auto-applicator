"""SQLite state: processed jobs, the question/answer cache, and questions waiting for the user."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from collections.abc import Iterable
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Any


class JobStatus(StrEnum):
    APPLIED = "APPLIED"
    DRY_RUN_COMPLETE = "DRY_RUN_COMPLETE"
    SKIPPED_BLACKLIST = "SKIPPED_BLACKLIST"
    SKIPPED_TITLE_FILTER = "SKIPPED_TITLE_FILTER"
    SKIPPED_ALREADY_APPLIED = "SKIPPED_ALREADY_APPLIED"
    SKIPPED_NEEDS_ANSWER = "SKIPPED_NEEDS_ANSWER"
    FAILED_OTP_TIMEOUT = "FAILED_OTP_TIMEOUT"
    FAILED_FORM_ERROR = "FAILED_FORM_ERROR"


class ATSType(StrEnum):
    LINKEDIN_EASY_APPLY = "LINKEDIN_EASY_APPLY"
    GREENHOUSE = "GREENHOUSE"
    LEVER = "LEVER"
    ASHBY = "ASHBY"
    WORKDAY = "WORKDAY"
    GENERIC_EXTERNAL = "GENERIC_EXTERNAL"


# Never retried: the outcome is final.
FINAL_STATUSES = {
    JobStatus.APPLIED,
    JobStatus.SKIPPED_BLACKLIST,
    JobStatus.SKIPPED_TITLE_FILTER,
    JobStatus.SKIPPED_ALREADY_APPLIED,
}
FAILED_STATUSES = {JobStatus.FAILED_OTP_TIMEOUT, JobStatus.FAILED_FORM_ERROR}

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    job_id        TEXT PRIMARY KEY,
    title         TEXT,
    company       TEXT,
    location      TEXT,
    ats_type      TEXT,
    url           TEXT,
    external_url  TEXT,
    status        TEXT,
    notes         TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    updated_at    DATETIME
);
CREATE TABLE IF NOT EXISTS qa_cache (
    question_hash TEXT PRIMARY KEY,
    question_text TEXT,
    field_type    TEXT,
    options_json  TEXT,
    answer        TEXT,
    source        TEXT,
    updated_at    DATETIME
);
CREATE TABLE IF NOT EXISTS pending_questions (
    question_hash TEXT PRIMARY KEY,
    question_text TEXT,
    field_type    TEXT,
    options_json  TEXT,
    job_ids       TEXT,
    companies     TEXT,
    first_seen    DATETIME,
    last_seen     DATETIME
);
"""

_WS = re.compile(r"\s+")
_LABEL_NOISE = re.compile(r"(\(required\)|\(optional\)|\*|✱|required$)", re.I)


def now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def normalize_question(text: str) -> str:
    t = _LABEL_NOISE.sub(" ", text or "")
    t = _WS.sub(" ", t).strip().lower()
    return t.strip(" :?.-–")


def question_hash(label: str, field_type: str, options: Iterable[str] = ()) -> str:
    opts = sorted({normalize_question(o) for o in options if o and o.strip()})
    raw = "\x1f".join([normalize_question(label), (field_type or "").lower(), json.dumps(opts)])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


class Database:
    def __init__(self, path: Path | str):
        self.path = Path(path)
        if str(path) != ":memory:":
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(path), check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    # ------------------------------------------------------------------ jobs

    def get_job(self, job_id: str) -> dict[str, Any] | None:
        row = self.conn.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
        return dict(row) if row else None

    def upsert_job(
        self,
        job_id: str,
        *,
        status: JobStatus | str,
        title: str | None = None,
        company: str | None = None,
        location: str | None = None,
        ats_type: ATSType | str | None = None,
        url: str | None = None,
        external_url: str | None = None,
        notes: str | None = None,
        count_attempt: bool = False,
    ) -> None:
        existing = self.get_job(job_id) or {}
        merged = {
            "title": title if title is not None else existing.get("title"),
            "company": company if company is not None else existing.get("company"),
            "location": location if location is not None else existing.get("location"),
            "ats_type": str(ats_type) if ats_type is not None else existing.get("ats_type"),
            "url": url if url is not None else existing.get("url"),
            "external_url": external_url if external_url is not None else existing.get("external_url"),
            "notes": notes if notes is not None else existing.get("notes"),
        }
        attempts = int(existing.get("attempts") or 0) + (1 if count_attempt else 0)
        self.conn.execute(
            """INSERT INTO jobs (job_id, title, company, location, ats_type, url, external_url, status, notes,
                                 attempts, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(job_id) DO UPDATE SET
                 title=excluded.title, company=excluded.company, location=excluded.location,
                 ats_type=excluded.ats_type, url=excluded.url, external_url=excluded.external_url,
                 status=excluded.status, notes=excluded.notes, attempts=excluded.attempts,
                 updated_at=excluded.updated_at""",
            (
                job_id,
                merged["title"],
                merged["company"],
                merged["location"],
                merged["ats_type"],
                merged["url"],
                merged["external_url"],
                str(status),
                merged["notes"],
                attempts,
                now_iso(),
            ),
        )
        self.conn.commit()

    def skip_reason(self, job_id: str, *, dry_run: bool, max_attempts: int = 2) -> str | None:
        """Why an already-seen job should not be processed again (None = process it)."""
        job = self.get_job(job_id)
        if not job:
            return None
        status = job["status"]
        if status in FINAL_STATUSES:
            return status
        if status == JobStatus.DRY_RUN_COMPLETE:
            return status if dry_run else None
        if status == JobStatus.SKIPPED_NEEDS_ANSWER:
            return status if self.job_has_pending(job_id) else None
        if status in FAILED_STATUSES and int(job["attempts"] or 0) >= max_attempts:
            return f"{status} (gave up after {job['attempts']} attempts)"
        return None

    def recent_jobs(self, limit: int = 30) -> list[dict[str, Any]]:
        rows = self.conn.execute("SELECT * FROM jobs ORDER BY updated_at DESC LIMIT ?", (limit,)).fetchall()
        return [dict(r) for r in rows]

    def status_counts(self) -> dict[str, int]:
        rows = self.conn.execute("SELECT status, COUNT(*) AS n FROM jobs GROUP BY status ORDER BY n DESC").fetchall()
        return {r["status"]: r["n"] for r in rows}

    # ------------------------------------------------------------------ QA cache

    def cache_get(self, qhash: str) -> str | None:
        row = self.conn.execute("SELECT answer FROM qa_cache WHERE question_hash = ?", (qhash,)).fetchone()
        return row["answer"] if row else None

    def cache_source(self, qhash: str) -> str | None:
        row = self.conn.execute("SELECT source FROM qa_cache WHERE question_hash = ?", (qhash,)).fetchone()
        return row["source"] if row else None

    def cache_put(
        self, qhash: str, question: str, field_type: str, options: list[str], answer: str, source: str = "llm"
    ) -> None:
        self.conn.execute(
            """INSERT INTO qa_cache (question_hash, question_text, field_type, options_json, answer, source, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(question_hash) DO UPDATE SET answer=excluded.answer, source=excluded.source,
                 updated_at=excluded.updated_at""",
            (qhash, question, field_type, json.dumps(options), answer, source, now_iso()),
        )
        self.conn.commit()

    def cache_delete(self, qhash: str) -> None:
        self.conn.execute("DELETE FROM qa_cache WHERE question_hash = ?", (qhash,))
        self.conn.commit()

    def cache_entries(self) -> list[dict[str, Any]]:
        rows = self.conn.execute("SELECT * FROM qa_cache ORDER BY updated_at DESC").fetchall()
        return [dict(r) for r in rows]

    # ------------------------------------------------------------------ pending questions

    def add_pending(
        self, qhash: str, question: str, field_type: str, options: list[str], job_id: str, company: str = ""
    ) -> None:
        row = self.conn.execute(
            "SELECT job_ids, companies FROM pending_questions WHERE question_hash = ?", (qhash,)
        ).fetchone()
        ts = now_iso()
        if row:
            jobs = set(json.loads(row["job_ids"] or "[]")) | {job_id}
            companies = set(json.loads(row["companies"] or "[]")) | ({company} if company else set())
            self.conn.execute(
                "UPDATE pending_questions SET job_ids=?, companies=?, last_seen=? WHERE question_hash=?",
                (json.dumps(sorted(jobs)), json.dumps(sorted(companies)), ts, qhash),
            )
        else:
            self.conn.execute(
                """INSERT INTO pending_questions
                   (question_hash, question_text, field_type, options_json, job_ids, companies, first_seen, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    qhash,
                    question,
                    field_type,
                    json.dumps(options),
                    json.dumps([job_id]),
                    json.dumps([company] if company else []),
                    ts,
                    ts,
                ),
            )
        self.conn.commit()

    def list_pending(self) -> list[dict[str, Any]]:
        rows = self.conn.execute("SELECT * FROM pending_questions ORDER BY last_seen DESC").fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["options"] = json.loads(d.pop("options_json") or "[]")
            d["job_ids"] = json.loads(d["job_ids"] or "[]")
            d["companies"] = json.loads(d["companies"] or "[]")
            out.append(d)
        return out

    def resolve_pending(self, qhash: str, answer: str) -> None:
        row = self.conn.execute("SELECT * FROM pending_questions WHERE question_hash = ?", (qhash,)).fetchone()
        if not row:
            return
        self.cache_put(
            qhash, row["question_text"], row["field_type"], json.loads(row["options_json"] or "[]"), answer, "user"
        )
        self.conn.execute("DELETE FROM pending_questions WHERE question_hash = ?", (qhash,))
        self.conn.commit()

    def dismiss_pending(self, qhash: str) -> None:
        self.conn.execute("DELETE FROM pending_questions WHERE question_hash = ?", (qhash,))
        self.conn.commit()

    def job_has_pending(self, job_id: str) -> bool:
        rows = self.conn.execute("SELECT job_ids FROM pending_questions").fetchall()
        return any(job_id in json.loads(r["job_ids"] or "[]") for r in rows)
