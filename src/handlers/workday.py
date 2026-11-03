"""Workday adapter: Apply → (Autofill with Resume | Apply Manually) → sign in / create account → wizard.

Candidate accounts use profile.personal.email and ATS_DEFAULT_PASSWORD from .env. When a new tenant
account must be verified, the verification link is read from the user's inbox (EmailVerifier).
"""

from __future__ import annotations

import re
from datetime import UTC, datetime

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Locator, Page

from ..answers import match_option
from ..db import ATSType, JobStatus
from ..forms import collect_errors, visible_text
from .base import ApplyResult, BaseHandler


def aid(name: str) -> str:
    return f'[data-automation-id="{name}"]'


NEXT_BUTTON = f'{aid("bottom-navigation-next-button")}, {aid("pageFooterNextButton")}'
WORKDAY_SUCCESS = re.compile(r"application (has been )?submitted|congratulations|thank you for applying", re.I)
VERIFY_PROMPT = re.compile(r"verify your (email|account)|verification email|check your email|account (has not been|isn't) verified", re.I)


class WorkdayHandler(BaseHandler):
    ats_type = ATSType.WORKDAY
    exclude = BaseHandler.exclude + (
        aid("utilityButtonBar"), aid("navigationPanel"), aid("multiselectInputContainer"),
        aid("dateSectionMonth-input"), aid("dateSectionDay-input"), aid("dateSectionYear-input"),
    )  # fmt: skip

    async def apply(self, page: Page) -> ApplyResult:
        await page.wait_for_timeout(2500)
        if btn := await self._visible(page, aid("adventureButton")):
            await btn.click()
            await page.wait_for_timeout(2000)
        used_autofill = await self._choose_start(page)

        if (gate := await self._auth(page)) is not None:
            return gate
        if used_autofill or await self._visible(page, aid("autofillWithResume")):
            used_autofill = await self._choose_start(page) or used_autofill
            await self._upload_resume(page)

        for _ in range(self.limits.max_form_steps):
            await self._wait_idle(page)
            if WORKDAY_SUCCESS.search(await visible_text(page)):
                return ApplyResult(JobStatus.APPLIED, notes="Submitted via Workday", external_url=page.url)
            next_btn = await self._visible(page, NEXT_BUTTON)
            if next_btn is None:
                return await self.failure(page, "Workday: no Next/Submit button on this step.")
            label = (await next_btn.inner_text()).strip()
            is_submit = bool(re.search(r"^submit", label, re.I))

            if not is_submit:
                await self._fill_source(page)
                await self._fill_today_dates(page)
                outcome = await self.fill_step(page)
                if outcome.blocked:
                    return self.needs_answer(outcome.blocked, page)
            if is_submit:
                if self.ctx.dry_run:
                    return await self.dry_run_result(page)
                await next_btn.click()
                await page.wait_for_timeout(4000)
                if await self.confirm_submitted(page):
                    return ApplyResult(JobStatus.APPLIED, notes="Submitted via Workday", external_url=page.url)
                return await self.failure(page, "Workday: clicked Submit but saw no confirmation.")

            async def find_next() -> Locator | None:
                return await self._visible(page, NEXT_BUTTON)

            advanced, result = await self.click_and_validate(page, page, find_next)
            if not advanced:
                return result  # type: ignore[return-value]
            await self.step_pause()
        return await self.failure(page, f"Workday: exceeded {self.limits.max_form_steps} steps.")

    # ------------------------------------------------------------------ helpers

    @staticmethod
    async def _visible(page: Page, selector: str) -> Locator | None:
        loc = page.locator(selector)
        try:
            for i in range(min(await loc.count(), 5)):
                if await loc.nth(i).is_visible():
                    return loc.nth(i)
        except PlaywrightError:
            pass
        return None

    async def _wait_idle(self, page: Page) -> None:
        try:
            await page.wait_for_load_state("networkidle", timeout=8000)
        except PlaywrightError:
            pass
        await page.wait_for_timeout(800)

    async def _choose_start(self, page: Page) -> bool:
        """Prefer "Autofill with Resume"; fall back to "Apply Manually". Returns True if autofill was chosen."""
        for name, autofill in (("autofillWithResume", True), ("applyManually", False)):
            if btn := await self._visible(page, aid(name)):
                await btn.click()
                await page.wait_for_timeout(2500)
                return autofill
        return False

    async def _click_submit(self, page: Page, name: str) -> None:
        btn = page.locator(aid(name)).first
        overlay = btn.locator(aid("click_filter")).first
        target = overlay if await overlay.count() else btn
        await target.click(force=True)

    async def _auth(self, page: Page) -> ApplyResult | None:
        email_box = await self._visible(page, aid("email"))
        if email_box is None:
            return None
        password = self.ctx.settings.secrets.ats_default_password.get_secret_value()
        if not password or password == "StrongPortalPassword123!":
            return await self.failure(page, "Workday needs a candidate account: set a portal password in setup (ATS_DEFAULT_PASSWORD).")
        email = self.ctx.settings.require_profile().personal.email

        if not await self._visible(page, aid("verifyPassword")):
            if await self._sign_in(page, email, password):
                return None
            if link := await self._visible(page, aid("createAccountLink")):
                await link.click()
                await page.wait_for_timeout(1500)

        if await self._visible(page, aid("verifyPassword")):
            created_at = datetime.now(UTC)
            await page.locator(aid("email")).first.fill(email)
            await page.locator(aid("password")).first.fill(password)
            await page.locator(aid("verifyPassword")).first.fill(password)
            if box := await self._visible(page, aid("createAccountCheckbox")):
                if not await box.is_checked():
                    await box.click()
            await self._click_submit(page, "createAccountSubmitButton")
            await page.wait_for_timeout(4000)
            errors = await collect_errors(page)
            if errors or await self._visible(page, aid("errorMessage")):
                msg = "; ".join(errors.values()) or (await visible_text(page, 400))
                return await self.failure(page, f"Workday account creation failed: {msg[:200]}")
            if VERIFY_PROMPT.search(await visible_text(page)) or await self._visible(page, aid("email")):
                if (res := await self._verify_email(page, created_at)) is not None:
                    return res
                if await self._visible(page, aid("email")) and not await self._sign_in(page, email, password):
                    return await self.failure(page, "Workday: could not sign in after creating the account.")
        return None

    async def _sign_in(self, page: Page, email: str, password: str) -> bool:
        if link := await self._visible(page, aid("signInLink")):
            await link.click()
            await page.wait_for_timeout(1200)
        if await self._visible(page, aid("email")) is None:
            return True
        await page.locator(aid("email")).first.fill(email)
        await page.locator(aid("password")).first.fill(password)
        await self._click_submit(page, "signInSubmitButton")
        await page.wait_for_timeout(4000)
        return await self._visible(page, aid("email")) is None and not await self._visible(page, aid("errorMessage"))

    async def _verify_email(self, page: Page, since: datetime) -> ApplyResult | None:
        if not self.ctx.verifier.configured:
            return await self.failure(page, "Workday sent a verification email but email (IMAP) is not set up.",
                                      JobStatus.FAILED_OTP_TIMEOUT)
        res = await self.ctx.verifier.wait_for_verification(
            "workday|myworkday", since, timeout_sec=self.limits.otp_timeout_sec, kind="link"
        )
        if not res or not res.url:
            return await self.failure(page, "Workday verification email did not arrive in time.", JobStatus.FAILED_OTP_TIMEOUT)
        verify_page = await page.context.new_page()
        try:
            await verify_page.goto(res.url, wait_until="domcontentloaded")
            await verify_page.wait_for_timeout(3000)
        finally:
            await verify_page.close()
        await page.reload(wait_until="domcontentloaded")
        await page.wait_for_timeout(2500)
        return None

    async def _upload_resume(self, page: Page) -> None:
        file_input = page.locator(f'{aid("file-upload-input-ref")}, input[type=file]').first
        try:
            if await file_input.count():
                await file_input.set_input_files(str(self.ctx.settings.resume_path))
                await page.wait_for_timeout(5000)  # Workday parses the resume
        except PlaywrightError as e:
            self.log.warning("Workday resume upload failed: %s", e)

    async def _fill_source(self, page: Page) -> None:
        """'How Did You Hear About Us?' is a hierarchical multiselect prompt."""
        containers = page.locator(aid("multiselectInputContainer"))
        source = self.ctx.settings.require_profile().preferences.how_did_you_hear or "LinkedIn"
        for i in range(await containers.count()):
            box = containers.nth(i)
            try:
                group = box.locator("xpath=ancestor::*[@data-automation-id][1]")
                question = (await group.inner_text()).lower() if await group.count() else ""
                if not re.search(r"how did you hear|source", question) or await box.locator(aid("selectedItem")).count():
                    continue
                field = box.locator("input").first
                await field.click()
                await field.fill(source)
                await field.press("Enter")
                await page.wait_for_timeout(1500)
                options = page.locator(aid("promptOption"))
                texts = [t.strip() for t in await options.all_inner_texts()]
                choice = match_option(source, texts) or (texts[0] if texts else None)
                if choice:
                    await options.nth(texts.index(choice)).click()
                    await page.wait_for_timeout(800)
            except PlaywrightError as e:
                self.log.debug("Source prompt not filled: %s", e)

    async def _fill_today_dates(self, page: Page) -> None:
        """Self-identification forms ask for today's date in segmented month/day/year inputs."""
        today = datetime.now()
        for part, value in (("Month", f"{today:%m}"), ("Day", f"{today:%d}"), ("Year", f"{today:%Y}")):
            inputs = page.locator(aid(f"dateSection{part}-input"))
            for i in range(await inputs.count()):
                box = inputs.nth(i)
                try:
                    if not await box.is_visible() or (await box.input_value()).strip():
                        continue
                    question = await box.evaluate(_FIELD_LABEL_JS)
                    if re.search(r"\bdate\b|signed|today", question, re.I):
                        await box.click()
                        await box.type(value, delay=60)
                except PlaywrightError:
                    continue


_FIELD_LABEL_JS = """
e => { const f = e.closest('[data-automation-id^="formField"]') || e.closest('fieldset');
       const l = f && f.querySelector('label, legend'); return l ? l.innerText : ''; }
"""
