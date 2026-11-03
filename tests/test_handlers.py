from __future__ import annotations

from datetime import UTC, datetime

import pytest

from src.answers import Answerer
from src.config import Secrets
from src.db import JobStatus
from src.email_verifier import EmailVerifier
from src.handlers import EasyApplyHandler, GenericAXTreeHandler, GreenhouseHandler, detect_ats
from src.handlers.base import ApplyContext
from src.db import ATSType
from src.llm import JobContext

from .conftest import FakeLLM, fixture_url
from .test_email_verifier import FakeIMAP, make_email

pytestmark = pytest.mark.browser


def make_ctx(settings, db, llm, *, dry_run, verifier=None) -> ApplyContext:
    settings.config.limits.min_delay_sec = 0
    settings.config.limits.max_delay_sec = 0
    return ApplyContext(
        job_id="4242",
        job=JobContext(title="Backend Engineer", company="Initech", location="Remote", description="Python, AWS"),
        settings=settings,
        db=db,
        answerer=Answerer(settings.profile, db, llm),
        llm=llm,
        verifier=verifier or EmailVerifier(Secrets()),
        dry_run=dry_run,
    )


EASY_LLM = dict(feedback_table={"start date": ("12/01/2026", "high")})


async def test_easy_apply_dry_run_stops_before_submit(page, settings, db):
    await page.goto(fixture_url("easy_apply.html"))
    ctx = make_ctx(settings, db, FakeLLM(**EASY_LLM), dry_run=True)
    result = await EasyApplyHandler(ctx).apply(page)
    assert result.status == JobStatus.DRY_RUN_COMPLETE, result.notes
    assert result.screenshot and result.screenshot.exists()
    assert await page.evaluate("window.__submitted") is False
    assert await page.evaluate("window.__discarded") is True


async def test_easy_apply_submits_and_fixes_validation(page, settings, db):
    await page.goto(fixture_url("easy_apply.html"))
    llm = FakeLLM(**EASY_LLM)
    ctx = make_ctx(settings, db, llm, dry_run=False)
    result = await EasyApplyHandler(ctx).apply(page)
    assert result.status == JobStatus.APPLIED, result.notes
    assert await page.evaluate("window.__submitted") is True
    assert await page.evaluate("window.__followAtSubmit") is False  # follow-company was unchecked
    # the start-date rule answer was rejected, then corrected via LLM feedback
    assert any(fb and "MM/DD/YYYY" in next(iter(fb.values())) for fb in llm.feedback)


async def test_easy_apply_unknown_required_question_skips_and_flags(page, settings, db):
    await page.goto(fixture_url("easy_apply.html") + "?extra=rust")
    ctx = make_ctx(settings, db, FakeLLM({"rust": ("1", "low")}, **EASY_LLM), dry_run=False)
    result = await EasyApplyHandler(ctx).apply(page)
    assert result.status == JobStatus.SKIPPED_NEEDS_ANSWER
    assert "Rust" in result.notes
    assert await page.evaluate("window.__submitted") is False
    assert await page.evaluate("window.__discarded") is True
    pending = db.list_pending()
    assert len(pending) == 1 and pending[0]["job_ids"] == ["4242"]


async def test_greenhouse_submit_with_email_security_code(page, settings, db):
    await page.goto(fixture_url("greenhouse.html"))
    imap = FakeIMAP([])
    secrets = Secrets(imap_user="jane.doe@example.com", imap_app_password="abcdabcdabcdabcd")  # type: ignore[arg-type]
    verifier = EmailVerifier(secrets, imap_factory=lambda h, p: imap, poll_interval=0.05)

    real_wait = verifier.wait_for_verification

    async def wait_and_deliver(*args, **kwargs):
        # the code email "arrives" after the form is submitted
        imap.messages[b"1"] = [make_email("no-reply@us.greenhouse-mail.io", "Security code",
                                          text="Copy and paste this code into the security code field on your application: nE5Cx0Ky",
                                          when=datetime.now(UTC)), False]
        return await real_wait(*args, **kwargs)

    verifier.wait_for_verification = wait_and_deliver  # type: ignore[method-assign]
    ctx = make_ctx(settings, db, FakeLLM(), dry_run=False, verifier=verifier)
    result = await GreenhouseHandler(ctx).apply(page)
    assert result.status == JobStatus.APPLIED, result.notes
    assert await page.evaluate("window.__finalSubmit") == 1
    assert "Thank you for applying" in await page.inner_text("body")


async def test_greenhouse_dry_run_fills_without_submitting(page, settings, db):
    await page.goto(fixture_url("greenhouse.html"))
    ctx = make_ctx(settings, db, FakeLLM(), dry_run=True)
    result = await GreenhouseHandler(ctx).apply(page)
    assert result.status == JobStatus.DRY_RUN_COMPLETE
    assert await page.input_value("#first_name") == "Jane"
    assert await page.input_value("#email") == "jane.doe@example.com"
    assert await page.input_value("#question_1") == "https://www.linkedin.com/in/janedoe"
    assert await page.input_value("#question_2") == "No"
    assert await page.input_value("#gender") == "Decline To Self Identify"
    assert await page.evaluate("document.getElementById('resume').files.length") == 1


async def test_generic_handler_end_to_end(page, settings, db):
    await page.goto(fixture_url("generic_form.html"))
    llm = FakeLLM({
        "why do you want": ("I like building reliable Python services.", "medium"),
        "driver": ("Yes", "high"),
        "languages": ("Python ; Rust", "high"),
        "certify": ("Yes", "high"),
    })
    ctx = make_ctx(settings, db, llm, dry_run=False)
    result = await GenericAXTreeHandler(ctx).apply(page)
    assert result.status == JobStatus.APPLIED, result.notes
    assert "Thank you for applying" in await page.inner_text("body")


def test_detect_ats():
    assert detect_ats("https://job-boards.greenhouse.io/initech/jobs/123") == ATSType.GREENHOUSE
    assert detect_ats("https://initech.com/careers?gh_jid=123") == ATSType.GREENHOUSE
    assert detect_ats("https://jobs.lever.co/initech/abc") == ATSType.LEVER
    assert detect_ats("https://jobs.ashbyhq.com/initech/abc") == ATSType.ASHBY
    assert detect_ats("https://initech.wd5.myworkdayjobs.com/en-US/careers/job/x") == ATSType.WORKDAY
    assert detect_ats("https://careers.initech.com/apply") == ATSType.GENERIC_EXTERNAL
