"""The end-to-end run: search LinkedIn, filter, route each job to a handler, record the outcome."""

from __future__ import annotations

import asyncio
import logging
import random
from collections import Counter
from dataclasses import dataclass, field

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Page
from rich.console import Console
from rich.table import Table

from . import macos
from .answers import Answerer
from .browser import BrowserError, BrowserManager
from .config import ConfigError, SearchQuery, Settings
from .db import FAILED_STATUSES, ATSType, Database, JobStatus
from .email_verifier import EmailVerifier
from .handlers import ApplyContext, ApplyResult, EasyApplyHandler, detect_ats, handler_for, resolve_embedded
from .llm import JobContext, LLMClient
from .scraper import PAGE_SIZE, JobCard, LinkedInScraper, filter_reason

log = logging.getLogger(__name__)

STATUS_STYLE = {
    JobStatus.APPLIED: "bold green",
    JobStatus.DRY_RUN_COMPLETE: "cyan",
    JobStatus.SKIPPED_NEEDS_ANSWER: "yellow",
    JobStatus.FAILED_FORM_ERROR: "red",
    JobStatus.FAILED_OTP_TIMEOUT: "red",
}


class PipelineError(RuntimeError):
    pass


@dataclass
class RunSummary:
    rows: list[tuple[str, str, str, str, str]] = field(default_factory=list)  # company, title, ats, status, notes
    counts: Counter = field(default_factory=Counter)

    def add(self, card: JobCard, ats: str, status: JobStatus, notes: str) -> None:
        self.rows.append((card.company, card.title, ats, status.value, notes))
        self.counts[status.value] += 1

    def table(self) -> Table:
        t = Table(title="This run", show_lines=False)
        for col in ("Company", "Title", "Route", "Result", "Notes"):
            t.add_column(col, overflow="fold")
        for company, title, ats, status, notes in self.rows:
            t.add_row(company, title, ats, f"[{STATUS_STYLE.get(JobStatus(status), '')}]{status}[/]", notes[:120])
        return t


class Pipeline:
    def __init__(self, settings: Settings, *, dry_run: bool, console: Console | None = None):
        self.settings = settings
        self.dry_run = dry_run
        self.console = console or Console()
        self.summary = RunSummary()
        self.completed = 0

    @property
    def cfg(self):
        return self.settings.config

    def preflight(self) -> None:
        self.settings.require_profile()
        if not self.settings.resume_path.exists():
            raise ConfigError(f"Resume not found at {self.settings.resume_path}. Re-run setup to choose your resume PDF.")
        if not self.cfg.search_queries:
            raise ConfigError("config.yaml has no search_queries. Re-run setup or edit config.yaml.")

    async def run(self) -> RunSummary:
        self.preflight()
        profile = self.settings.require_profile()
        db = Database(self.settings.paths.db_file)
        llm = LLMClient(self.cfg.llm)
        try:
            with self.console.status("Starting the local AI model…"):
                await llm.ensure_ready()
            answerer = Answerer(profile, db, llm)
            verifier = EmailVerifier(self.settings.secrets, llm)
            if not verifier.configured:
                self.console.print("[yellow]Email (IMAP) is not set up: jobs that email a verification code will fail.[/]")
            async with BrowserManager(self.settings.paths, self.cfg.browser) as bm:
                page = await bm.main_page()
                if not await bm.is_logged_in(page):
                    raise PipelineError("Not signed in to LinkedIn. Use 'Sign in to LinkedIn' in the app first.")
                scraper = LinkedInScraper()
                for query in self.cfg.search_queries:
                    if self._quota_reached():
                        break
                    await self._run_query(bm, page, scraper, query, db, llm, answerer, verifier)
        finally:
            db.close()
        return self.summary

    def _quota_reached(self) -> bool:
        return self.completed >= self.cfg.limits.max_applies_per_run

    async def _run_query(self, bm, page, scraper, query: SearchQuery, db, llm, answerer, verifier) -> None:
        self.console.rule(f"[bold]{query.keywords}[/] · {query.location}")
        for page_no in range(query.max_pages):
            cards = await scraper.collect_page(page, query, page_no)
            self.console.print(f"Page {page_no + 1}: {len(cards)} job(s)")
            for card in cards:
                if self._quota_reached():
                    self.console.print(f"[bold]Reached max_applies_per_run ({self.cfg.limits.max_applies_per_run}).[/]")
                    return
                await self._consider(bm, page, scraper, query, card, db, llm, answerer, verifier)
            if len(cards) < PAGE_SIZE:
                return

    async def _consider(self, bm, page: Page, scraper, query, card: JobCard, db: Database, llm, answerer, verifier) -> None:
        if reason := filter_reason(card, self.cfg.filters):
            db.upsert_job(card.job_id, status=reason, title=card.title, company=card.company, location=card.location, url=card.url)
            self.summary.add(card, "-", reason, "filtered")
            return
        if card.applied:
            db.upsert_job(card.job_id, status=JobStatus.SKIPPED_ALREADY_APPLIED, title=card.title, company=card.company, url=card.url)
            return
        if db.skip_reason(card.job_id, dry_run=self.dry_run, max_attempts=self.cfg.limits.max_attempts_per_job):
            return

        self.console.print(f"→ [bold]{card.title}[/] at {card.company}")
        ats = "-"
        try:
            details = await scraper.open_job(page, card)
            if details.kind == "applied":
                db.upsert_job(card.job_id, status=JobStatus.SKIPPED_ALREADY_APPLIED, title=card.title, company=card.company, url=card.url)
                return
            if details.kind == "external" and not query.include_external:
                return
            if details.kind in ("closed", "unknown") or details.apply_button is None:
                result = ApplyResult(JobStatus.FAILED_FORM_ERROR, notes="No apply button (closed or unsupported posting).")
            else:
                ctx = ApplyContext(
                    job_id=card.job_id,
                    job=JobContext(title=card.title, company=card.company, location=card.location, description=details.description),
                    settings=self.settings, db=db, answerer=answerer, llm=llm, verifier=verifier, dry_run=self.dry_run,
                )
                if details.kind == "easy_apply":
                    ats = ATSType.LINKEDIN_EASY_APPLY.value
                    result = await EasyApplyHandler(ctx, details.apply_button).apply(page)
                else:
                    result, ats = await self._external(bm, page, details.apply_button, ctx)
        except (PlaywrightError, BrowserError) as e:
            log.exception("Job %s failed", card.job_id)
            result = ApplyResult(JobStatus.FAILED_FORM_ERROR, notes=f"Browser error: {str(e).splitlines()[0][:200]}")
        except Exception as e:  # noqa: BLE001 – one bad job must not stop the run
            log.exception("Job %s crashed", card.job_id)
            result = ApplyResult(JobStatus.FAILED_FORM_ERROR, notes=f"Unexpected error: {type(e).__name__}: {e}"[:300])

        db.upsert_job(
            card.job_id, status=result.status, title=card.title, company=card.company, location=card.location,
            ats_type=ats if ats != "-" else None, url=card.url, external_url=result.external_url, notes=result.notes,
            count_attempt=result.status in FAILED_STATUSES,
        )
        self.summary.add(card, ats, result.status, result.notes)
        style = STATUS_STYLE.get(result.status, "")
        self.console.print(f"  [{style}]{result.status.value}[/] {result.notes}")
        if result.status in (JobStatus.APPLIED, JobStatus.DRY_RUN_COMPLETE):
            self.completed += 1
        await asyncio.sleep(random.uniform(self.cfg.limits.min_delay_sec, self.cfg.limits.max_delay_sec))

    async def _external(self, bm: BrowserManager, page: Page, button, ctx: ApplyContext) -> tuple[ApplyResult, str]:
        ext = await bm.open_external_application(page, button)
        try:
            ats = detect_ats(ext.url)
            if ats == ATSType.GENERIC_EXTERNAL:
                ats = await resolve_embedded(ext)
            self.console.print(f"  external site: {ext.url[:90]} → {ats.value}")
            result = await handler_for(ats)(ctx).apply(ext)
            result.external_url = result.external_url or ext.url
            return result, ats.value
        finally:
            if ext is not page:
                try:
                    await ext.close()
                except PlaywrightError:
                    pass


def notify_summary(summary: RunSummary, dry_run: bool) -> None:
    c = summary.counts
    done = c.get("APPLIED", 0) + c.get("DRY_RUN_COMPLETE", 0)
    verb = "dry-run applications prepared" if dry_run else "applications submitted"
    msg = f"{done} {verb}"
    if c.get("SKIPPED_NEEDS_ANSWER"):
        msg += f", {c['SKIPPED_NEEDS_ANSWER']} need your answers"
    failed = sum(v for k, v in c.items() if k.startswith("FAILED"))
    if failed:
        msg += f", {failed} failed"
    macos.notify("Auto Applicator finished", msg)
