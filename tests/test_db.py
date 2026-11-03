from __future__ import annotations

from src.db import ATSType, JobStatus, normalize_question, question_hash


def test_question_hash_normalization():
    a = question_hash("  Do you require Sponsorship? *", "radio", ["No", "Yes"])
    b = question_hash("do you require sponsorship", "radio", ["yes", "no "])
    c = question_hash("do you require sponsorship", "select", ["yes", "no"])
    assert a == b
    assert a != c
    assert normalize_question("First Name (required)*:") == "first name"


def test_upsert_merges_fields(db):
    db.upsert_job("1", status=JobStatus.FAILED_FORM_ERROR, title="Eng", company="Acme", ats_type=ATSType.GREENHOUSE,
                  count_attempt=True)
    db.upsert_job("1", status=JobStatus.APPLIED, notes="ok", count_attempt=True)
    job = db.get_job("1")
    assert job["title"] == "Eng" and job["company"] == "Acme" and job["ats_type"] == "GREENHOUSE"
    assert job["status"] == "APPLIED" and job["attempts"] == 2 and job["notes"] == "ok"


def test_skip_reason_rules(db):
    assert db.skip_reason("new", dry_run=False) is None
    db.upsert_job("applied", status=JobStatus.APPLIED)
    assert db.skip_reason("applied", dry_run=False) == "APPLIED"

    db.upsert_job("dry", status=JobStatus.DRY_RUN_COMPLETE)
    assert db.skip_reason("dry", dry_run=True) == "DRY_RUN_COMPLETE"
    assert db.skip_reason("dry", dry_run=False) is None  # a real run should apply

    db.upsert_job("fail", status=JobStatus.FAILED_OTP_TIMEOUT, count_attempt=True)
    assert db.skip_reason("fail", dry_run=False, max_attempts=2) is None
    db.upsert_job("fail", status=JobStatus.FAILED_OTP_TIMEOUT, count_attempt=True)
    assert "gave up" in db.skip_reason("fail", dry_run=False, max_attempts=2)


def test_pending_questions_flow(db):
    qh = question_hash("Years with Rust?", "number", [])
    db.upsert_job("j1", status=JobStatus.SKIPPED_NEEDS_ANSWER)
    db.add_pending(qh, "Years with Rust?", "number", [], "j1", "Acme")
    db.add_pending(qh, "Years with Rust?", "number", [], "j2", "Globex")
    pending = db.list_pending()
    assert len(pending) == 1 and pending[0]["job_ids"] == ["j1", "j2"] and pending[0]["companies"] == ["Acme", "Globex"]
    assert db.skip_reason("j1", dry_run=False) == "SKIPPED_NEEDS_ANSWER"

    db.resolve_pending(qh, "2")
    assert db.list_pending() == []
    assert db.cache_get(qh) == "2" and db.cache_source(qh) == "user"
    assert db.skip_reason("j1", dry_run=False) is None  # retried now that the answer exists


def test_status_counts(db):
    db.upsert_job("a", status=JobStatus.APPLIED)
    db.upsert_job("b", status=JobStatus.APPLIED)
    db.upsert_job("c", status=JobStatus.SKIPPED_BLACKLIST)
    assert db.status_counts() == {"APPLIED": 2, "SKIPPED_BLACKLIST": 1}
