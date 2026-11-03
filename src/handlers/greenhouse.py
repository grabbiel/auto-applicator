"""Greenhouse adapter (boards.greenhouse.io, job-boards.greenhouse.io and embedded job_app forms).

After the first submit, Greenhouse may show an email "security code" screen with eight one-character
inputs (#security-input-0..7). The code is read from the user's inbox and the form is re-submitted.
"""

from __future__ import annotations

from datetime import datetime

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Page
from playwright.async_api import TimeoutError as PlaywrightTimeout

from ..db import ATSType, JobStatus
from ..forms import Scope, find_button
from .base import SUBMIT_RE, ApplyResult, BaseHandler

FORM_SELECTORS = ("#application-form", "#application_form", "form[action*='greenhouse']", "form#application")
CODE_INPUTS = "#security-input-0, input[id^='security-input-'], #security_code, input[name='security_code']"


class GreenhouseHandler(BaseHandler):
    ats_type = ATSType.GREENHOUSE

    async def apply(self, page: Page) -> ApplyResult:
        root = await self._form_root(page)
        if root is None:
            page = await self.click_apply_entry(page)
            await page.wait_for_timeout(1500)
            root = await self._form_root(page)
        if root is None:
            return await self.failure(page, "Greenhouse application form not found.")

        async def scope() -> Scope:
            return page

        return await self.run_form_flow(page, scope, root)

    @staticmethod
    async def _form_root(page: Page) -> str | None:
        for sel in FORM_SELECTORS:
            try:
                if await page.locator(sel).count():
                    return sel
            except PlaywrightError:
                continue
        return None

    async def after_submit(self, page: Page, scope: Scope, submitted_at: datetime) -> ApplyResult | None:
        try:
            await page.wait_for_selector(CODE_INPUTS, timeout=8000, state="visible")
        except PlaywrightTimeout:
            return None  # no security-code step
        self.log.info("Greenhouse asked for an email security code")
        if not self.ctx.verifier.configured:
            return await self.failure(page, "Greenhouse emailed a security code but email (IMAP) is not set up.",
                                      JobStatus.FAILED_OTP_TIMEOUT)
        result = await self.ctx.verifier.wait_for_verification(
            "greenhouse", submitted_at, timeout_sec=self.limits.otp_timeout_sec, kind="code", code_length=8
        )
        if not result or not result.code:
            return await self.failure(page, f"No Greenhouse security code arrived within {self.limits.otp_timeout_sec}s.",
                                      JobStatus.FAILED_OTP_TIMEOUT)
        await self._enter_code(page, result.code)
        button = await find_button(page, SUBMIT_RE)
        if button is None:
            return await self.failure(page, "Entered the security code but found no Submit button.")
        await button.click()
        await page.wait_for_timeout(2500)
        return None

    @staticmethod
    async def _enter_code(page: Page, code: str) -> None:
        single = page.locator("#security_code, input[name='security_code']").first
        if await single.count():
            await single.fill(code)
            return
        for i, ch in enumerate(code):
            box = page.locator(f"#security-input-{i}").first
            if await box.count():
                await box.fill(ch)
