"""Handler base class (shared form-step logic) and the GenericAXTreeHandler fallback for unknown portals."""

from __future__ import annotations

import asyncio
import logging
import random
import re
from abc import ABC, abstractmethod
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import ClassVar

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Locator, Page
from playwright.async_api import TimeoutError as PlaywrightTimeout

from ..answers import Answerer, Resolution
from ..config import Settings
from ..db import ATSType, Database, JobStatus
from ..email_verifier import EmailVerifier
from ..forms import (
    FormField,
    Scope,
    classify_file_field,
    collect_errors,
    extract_fields,
    fill_field,
    find_button,
    upload_file,
    visible_text,
)
from ..llm import JobContext, LLMClient, LLMError

SUCCESS_RE = re.compile(
    r"thank(s| you)[^.!\n]{0,40}(for (applying|your (application|interest|submission))|application)|"
    r"application (has been |was )?(successfully )?(submitted|received|sent|complete)|"
    r"we('ve| have) received your application|your application (has been|was) (submitted|received|sent)",
    re.I,
)
SUBMIT_RE = r"^(submit( (my )?application)?|send application|apply|complete application|finish)$"
NEXT_RE = r"^(next|continue|save (and|&) continue|next step|continue to next step|review|review application)\b"
APPLY_ENTRY_RE = r"^(apply( now| for this (job|position|role)| here| online)?|start (my )?application|i'?m interested)$"


@dataclass
class ApplyContext:
    job_id: str
    job: JobContext
    settings: Settings
    db: Database
    answerer: Answerer
    llm: LLMClient
    verifier: EmailVerifier
    dry_run: bool

    @property
    def company(self) -> str:
        return self.job.company


@dataclass
class ApplyResult:
    status: JobStatus
    notes: str = ""
    screenshot: Path | None = None
    external_url: str | None = None


@dataclass
class FillOutcome:
    fields: list[FormField] = field(default_factory=list)
    blocked: Resolution | None = None
    failures: list[str] = field(default_factory=list)
    missing_files: list[str] = field(default_factory=list)


class BaseHandler(ABC):
    ats_type: ClassVar[ATSType] = ATSType.GENERIC_EXTERNAL
    # Containers whose controls must never be touched (search boxes, cookie banners, ...).
    exclude: ClassVar[tuple[str, ...]] = (
        "header", "nav", "footer", "[role=search]", "#onetrust-consent-sdk", "[id*=cookie i]", "[class*=cookie i]",
    )  # fmt: skip

    def __init__(self, ctx: ApplyContext):
        self.ctx = ctx
        self.log = logging.getLogger(f"{__name__}.{type(self).__name__}")
        self._cover_letter_text: str | None = None

    @abstractmethod
    async def apply(self, page: Page) -> ApplyResult: ...

    # ------------------------------------------------------------------ pacing / evidence

    @property
    def limits(self):
        return self.ctx.settings.config.limits

    async def short_pause(self) -> None:
        if self.limits.max_delay_sec > 0:
            await asyncio.sleep(random.uniform(0.3, 0.8))

    async def step_pause(self) -> None:
        lo, hi = self.limits.min_delay_sec, self.limits.max_delay_sec
        await asyncio.sleep(random.uniform(lo, hi) / 2)

    async def screenshot(self, page: Page, tag: str) -> Path | None:
        safe = re.sub(r"[^A-Za-z0-9]+", "-", f"{self.ctx.company}-{self.ctx.job.title}")[:60].strip("-")
        path = self.ctx.settings.paths.screenshots_dir / f"{datetime.now():%Y%m%d-%H%M%S}-{tag}-{safe}-{self.ctx.job_id}.png"
        try:
            await page.screenshot(path=str(path), full_page=True)
            return path
        except PlaywrightError as e:
            self.log.warning("Screenshot failed: %s", e)
            return None

    async def failure(self, page: Page, note: str, status: JobStatus = JobStatus.FAILED_FORM_ERROR) -> ApplyResult:
        self.log.warning("%s: %s", self.ctx.company, note)
        return ApplyResult(status, notes=note, screenshot=await self.screenshot(page, "error"), external_url=page.url)

    def needs_answer(self, res: Resolution, page: Page | None = None) -> ApplyResult:
        self.ctx.answerer.flag_unresolved(res, self.ctx.job_id, self.ctx.company)
        questions = "; ".join(f.label for f in res.unresolved)[:500]
        return ApplyResult(
            JobStatus.SKIPPED_NEEDS_ANSWER,
            notes=f"Needs your answer: {questions}",
            external_url=page.url if page else None,
        )

    # ------------------------------------------------------------------ documents

    async def cover_letter_text(self) -> str:
        if self._cover_letter_text is None:
            self._cover_letter_text = await self.ctx.llm.cover_letter(self.ctx.answerer.profile_text, self.ctx.job)
        return self._cover_letter_text

    async def cover_letter_file(self) -> Path:
        existing = self.ctx.settings.cover_letter_path
        if existing and existing.exists():
            return existing
        text = await self.cover_letter_text()
        safe = re.sub(r"[^A-Za-z0-9]+", "-", self.ctx.company)[:40].strip("-") or "company"
        path = self.ctx.settings.paths.cover_letters_dir / f"Cover-Letter-{safe}-{self.ctx.job_id}.txt"
        path.write_text(text + "\n", encoding="utf-8")
        return path

    async def handle_documents(self, fields: list[FormField]) -> tuple[set[str], list[str]]:
        """Upload resume / cover letter, fill cover-letter text boxes. Returns (handled ids, missing required)."""
        handled: set[str] = set()
        missing: list[str] = []
        resume = self.ctx.settings.resume_path
        for f in fields:
            if f.kind == "file":
                handled.add(f.field_id)
                kind = classify_file_field(f)
                if f.spec.current_value:
                    continue
                if kind == "resume" or (kind is None and f.spec.required and "resume" not in {classify_file_field(x) for x in fields}):
                    if not await upload_file(f, resume):
                        missing.append(f.spec.label or "resume")
                elif kind == "cover_letter" and (f.spec.required or self.ctx.settings.cover_letter_path):
                    try:
                        if not await upload_file(f, await self.cover_letter_file()):
                            missing.append(f.spec.label)
                    except LLMError as e:
                        missing.append(f"{f.spec.label} ({e})")
                elif f.spec.required:
                    missing.append(f.spec.label or "file upload")
                await self.short_pause()
            elif f.kind == "text" and re.search(r"cover[\s_-]*letter", f.spec.label, re.I) and not f.spec.current_value:
                handled.add(f.field_id)
                if f.spec.required or f.spec.field_type == "textarea":
                    try:
                        await fill_field(f, await self.cover_letter_text())
                    except LLMError as e:
                        if f.spec.required:
                            missing.append(f"{f.spec.label} ({e})")
        return handled, missing

    # ------------------------------------------------------------------ form steps

    async def fill_step(self, scope: Scope, root: str | None = None, *, exclude: tuple[str, ...] | None = None) -> FillOutcome:
        fields = await extract_fields(scope, root, exclude=exclude if exclude is not None else self.exclude)
        handled, missing = await self.handle_documents(fields)
        todo = [f for f in fields if f.field_id not in handled]
        res = await self.ctx.answerer.resolve([f.spec for f in todo], self.ctx.job)
        if res.blocked:
            return FillOutcome(fields=fields, blocked=res, missing_files=missing)
        failures = []
        for f in todo:
            answer = res.answers.get(f.field_id)
            if answer is None:
                continue
            if not await fill_field(f, answer):
                failures.append(f.describe())
            await self.short_pause()
        self.log.info("Filled %d field(s) (%d left blank, %d failed)", len(res.answers), len(res.left_blank), len(failures))
        return FillOutcome(fields=fields, failures=failures, missing_files=missing)

    async def fix_errors(self, scope: Scope, errors: dict[str, str], root: str | None = None,
                         *, exclude: tuple[str, ...] | None = None) -> FillOutcome:
        """Re-answer fields the form rejected, feeding the validation messages back to the LLM."""
        fields = await extract_fields(scope, root, exclude=exclude if exclude is not None else self.exclude)
        targets = [f for f in fields if f.field_id in errors and f.kind != "file"]
        for f in targets:
            f.spec.error = errors[f.field_id]
            f.spec.required = True
        res = await self.ctx.answerer.resolve([f.spec for f in targets], self.ctx.job, feedback={f.field_id: errors[f.field_id] for f in targets})
        if res.blocked:
            return FillOutcome(fields=fields, blocked=res)
        failures = []
        for f in targets:
            if (answer := res.answers.get(f.field_id)) is not None and not await fill_field(f, answer):
                failures.append(f.describe())
        return FillOutcome(fields=fields, failures=failures)

    async def click_and_validate(
        self,
        page: Page,
        scope: Scope,
        find: Callable[[], Awaitable[Locator | None]],
        root: str | None = None,
        *,
        exclude: tuple[str, ...] | None = None,
        retries: int = 2,
    ) -> tuple[bool, ApplyResult | None]:
        """Click a Next/Submit button; on validation errors re-answer and retry. Returns (advanced, result)."""
        for attempt in range(retries + 1):
            button = await find()
            if button is None:
                return False, await self.failure(page, "The Next/Submit button disappeared.")
            await button.click()
            await page.wait_for_timeout(1800)
            errors = await collect_errors(scope, root)
            if not errors:
                return True, None
            self.log.info("Validation errors (attempt %d): %s", attempt + 1, list(errors.values())[:4])
            if attempt == retries:
                break
            fix = await self.fix_errors(scope, errors, root, exclude=exclude)
            if fix.blocked:
                return False, self.needs_answer(fix.blocked, page)
        msgs = "; ".join(list((await collect_errors(scope, root)).values())[:4])
        return False, await self.failure(page, f"Form rejected the answers: {msgs}")

    async def dry_run_result(self, page: Page) -> ApplyResult:
        shot = await self.screenshot(page, "dry-run")
        return ApplyResult(JobStatus.DRY_RUN_COMPLETE, notes="Dry run: stopped at the final Submit button.",
                           screenshot=shot, external_url=page.url)

    async def confirm_submitted(self, page: Page, scope: Scope | None = None, timeout_ms: int = 15000) -> bool:
        scope = scope or page
        deadline = asyncio.get_running_loop().time() + timeout_ms / 1000
        while asyncio.get_running_loop().time() < deadline:
            for s in {scope, page}:
                if SUCCESS_RE.search(await visible_text(s)):
                    return True
            await asyncio.sleep(1)
        try:
            check = await self.ctx.llm.check_submission(await visible_text(page))
            return check.submitted
        except LLMError:
            return False

    async def after_submit(self, page: Page, scope: Scope, submitted_at: datetime) -> ApplyResult | None:
        """Hook for post-submit steps such as email security codes. Return a result to stop early."""
        return None

    async def run_form_flow(self, page: Page, get_scope: Callable[[], Awaitable[Scope]], root: str | None = None) -> ApplyResult:
        """Generic loop: fill visible fields, click Next until a Submit button appears, then submit (or dry-run)."""
        for step in range(self.limits.max_form_steps):
            scope = await get_scope()
            outcome = await self.fill_step(scope, root)
            if outcome.blocked:
                return self.needs_answer(outcome.blocked, page)
            if outcome.missing_files:
                return await self.failure(page, f"Required upload not supported: {', '.join(outcome.missing_files)}")
            submit = await find_button(scope, SUBMIT_RE, root)
            if submit is None:
                nxt = await find_button(scope, NEXT_RE, root)
                if nxt is None:
                    return await self.failure(page, "No Next or Submit button found on the form.")
                advanced, result = await self.click_and_validate(page, scope, lambda: find_button(scope, NEXT_RE, root), root)
                if not advanced:
                    return result  # type: ignore[return-value]
                await self.step_pause()
                continue
            if self.ctx.dry_run:
                return await self.dry_run_result(page)
            submitted_at = datetime.now(UTC)
            advanced, result = await self.click_and_validate(page, scope, lambda: find_button(scope, SUBMIT_RE, root), root)
            if not advanced:
                return result  # type: ignore[return-value]
            if (early := await self.after_submit(page, scope, submitted_at)) is not None:
                return early
            if await self.confirm_submitted(page, scope):
                return ApplyResult(JobStatus.APPLIED, notes=f"Submitted via {self.ats_type.value}", external_url=page.url)
            return await self.failure(page, "Clicked Submit but could not confirm the application went through.")
        return await self.failure(page, f"Gave up after {self.limits.max_form_steps} form steps.")

    async def click_apply_entry(self, page: Page) -> Page:
        """On a job-posting page, click its "Apply" button (which may open a new tab). Returns the active page."""
        btn = await find_button(page, APPLY_ENTRY_RE)
        if btn is None:
            return page
        try:
            async with page.context.expect_page(timeout=5000) as info:
                await btn.click()
            new = await info.value
            await new.wait_for_load_state("domcontentloaded")
            return new
        except PlaywrightTimeout:
            await page.wait_for_timeout(2000)
            return page


# --------------------------------------------------------------------------- generic fallback

_COUNT_FIELDS_JS = r"""
() => [...document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]), textarea, select')]
  .filter(e => { const r = e.getBoundingClientRect(); const cs = getComputedStyle(e);
                 return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; }).length
"""
_PASSWORD_JS = "() => [...document.querySelectorAll('input[type=password]')].some(e => e.getBoundingClientRect().width > 0)"


async def best_frame(page: Page) -> Scope:
    """The frame holding the most visible form controls (application forms are often embedded in iframes)."""
    best: tuple[int, Scope] = (-1, page)
    for frame in page.frames:
        try:
            n = await frame.evaluate(_COUNT_FIELDS_JS)
        except PlaywrightError:
            continue
        if n > best[0]:
            best = (n, page if frame == page.main_frame else frame)
    return best[1]


class GenericAXTreeHandler(BaseHandler):
    """Fallback for unknown career sites: label-driven field mapping + LLM answers + Next/Submit loop."""

    ats_type = ATSType.GENERIC_EXTERNAL

    async def apply(self, page: Page) -> ApplyResult:
        scope = await best_frame(page)
        if await scope.evaluate(_COUNT_FIELDS_JS) < 3:
            page = await self.click_apply_entry(page)
            await page.wait_for_timeout(2500)
            scope = await best_frame(page)
        if await scope.evaluate(_PASSWORD_JS):
            return await self.failure(page, "This career site requires signing in/creating an account; not automated for unknown portals.")
        if await scope.evaluate(_COUNT_FIELDS_JS) == 0:
            return await self.failure(page, "No application form found on the company site.")
        return await self.run_form_flow(page, lambda: best_frame(page))
