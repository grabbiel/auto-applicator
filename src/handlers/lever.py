"""Lever adapter (jobs.lever.co/<company>/<id>/apply)."""

from __future__ import annotations

from urllib.parse import urlparse, urlunparse

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Page

from ..db import ATSType
from ..forms import Scope
from .base import ApplyResult, BaseHandler

FORM = "#application-form, form[action*='/apply'], form.application-form"


class LeverHandler(BaseHandler):
    ats_type = ATSType.LEVER

    async def apply(self, page: Page) -> ApplyResult:
        parsed = urlparse(page.url)
        if not parsed.path.rstrip("/").endswith("/apply"):
            await page.goto(urlunparse(parsed._replace(path=parsed.path.rstrip("/") + "/apply", query="")),
                            wait_until="domcontentloaded")
        try:
            await page.wait_for_selector(FORM, timeout=15000)
        except PlaywrightError:
            return await self.failure(page, "Lever application form not found.")
        await self._preupload_resume(page)

        async def scope() -> Scope:
            return page

        return await self.run_form_flow(page, scope, FORM)

    async def _preupload_resume(self, page: Page) -> None:
        """Lever parses the resume and pre-fills fields; upload first so the parse can't overwrite our answers."""
        file_input = page.locator(f"{FORM} input[type=file][name=resume]").first
        try:
            if not await file_input.count():
                return
            await file_input.set_input_files(str(self.ctx.settings.resume_path))
            try:
                await page.wait_for_selector(".resume-upload-success, .resume-upload-working", timeout=4000)
                await page.wait_for_selector(".resume-upload-working", state="hidden", timeout=15000)
            except PlaywrightError:
                await page.wait_for_timeout(3000)
        except PlaywrightError as e:
            self.log.warning("Lever resume pre-upload failed: %s", e)
