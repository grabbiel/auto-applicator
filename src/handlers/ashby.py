"""Ashby adapter (jobs.ashbyhq.com/<company>/<id>/application)."""

from __future__ import annotations

import re
from urllib.parse import urlparse, urlunparse

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Page

from ..db import ATSType
from ..forms import Scope
from .base import ApplyResult, BaseHandler

FORM = ".ashby-application-form-container, form"


class AshbyHandler(BaseHandler):
    ats_type = ATSType.ASHBY
    # The "Autofill from resume" widget re-parses the resume asynchronously and can overwrite answers.
    exclude = BaseHandler.exclude + ("[class*=autofill i]",)

    async def apply(self, page: Page) -> ApplyResult:
        if not urlparse(page.url).path.rstrip("/").endswith("/application"):
            tab = page.get_by_role("tab", name=re.compile(r"^application$", re.I)).first
            try:
                if await tab.count():
                    await tab.click()
                else:
                    parsed = urlparse(page.url)
                    await page.goto(urlunparse(parsed._replace(path=parsed.path.rstrip("/") + "/application")),
                                    wait_until="domcontentloaded")
            except PlaywrightError:
                pass
        try:
            await page.wait_for_selector("input[type=file], input[type=email], #_systemfield_name", timeout=15000)
        except PlaywrightError:
            return await self.failure(page, "Ashby application form not found.")

        async def scope() -> Scope:
            return page

        return await self.run_form_flow(page, scope, None)
