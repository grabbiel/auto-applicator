"""LinkedIn native Easy Apply modal state machine."""

from __future__ import annotations

import re

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Locator, Page

from ..db import ATSType, JobStatus
from ..forms import FormField, find_button, visible_text
from .base import ApplyContext, ApplyResult, BaseHandler

ROOT = '[data-auto-root="easy-apply"]'
SUBMIT = r"^submit application$"
REVIEW = r"^review( your application)?$"
NEXT = r"^(next|continue to next step|continue)$"
SENT_RE = re.compile(r"application (was )?sent|your application was sent|application submitted", re.I)

_TAG_MODAL_JS = r"""
() => {
  document.querySelectorAll('[data-auto-root="easy-apply"]').forEach(e => e.removeAttribute('data-auto-root'));
  const m = document.querySelector('.jobs-easy-apply-modal') ||
            [...document.querySelectorAll('[role=dialog]')].find(d => /apply to|easy apply|contact info/i.test(d.innerText));
  if (!m) return null;
  m.setAttribute('data-auto-root', 'easy-apply');
  const bar = m.querySelector('[role=progressbar], progress, .artdeco-completeness-meter-linear__progress-element');
  return bar ? (bar.getAttribute('aria-valuenow') || bar.getAttribute('value') || '') : '';
}
"""

_RESUME_SELECTED_JS = r"""
() => {
  const root = document.querySelector('[data-auto-root="easy-apply"]');
  if (!root) return false;
  return !!root.querySelector('.jobs-document-upload-redesign-card__container--selected, ' +
    '[class*="document-upload"][aria-checked="true"], [class*="resume"] [aria-checked="true"], ' +
    '[class*="document-upload"] input[type=radio]:checked');
}
"""


class EasyApplyHandler(BaseHandler):
    ats_type = ATSType.LINKEDIN_EASY_APPLY
    exclude = ("#follow-company-checkbox", "[class*=follow-company]", "header", "footer")

    def __init__(self, ctx: ApplyContext, apply_button: Locator | None = None):
        super().__init__(ctx)
        self.apply_button = apply_button
        self._page: Page | None = None

    async def apply(self, page: Page) -> ApplyResult:
        self._page = page
        if not await self._open_modal(page):
            return await self.failure(page, "The Easy Apply dialog did not open.")
        try:
            return await self._run(page)
        except PlaywrightError as e:
            result = await self.failure(page, f"Browser error during Easy Apply: {str(e).splitlines()[0]}")
            await self._discard(page)
            return result

    async def _open_modal(self, page: Page) -> bool:
        btn = self.apply_button
        if btn is None:
            btn = page.locator("main").get_by_role("button", name=re.compile("easy apply", re.I)).first
        try:
            await btn.click()
            await page.wait_for_selector(".jobs-easy-apply-modal, [role=dialog]", timeout=10000)
            await page.wait_for_timeout(1200)
        except PlaywrightError:
            return False
        return await page.evaluate(_TAG_MODAL_JS) is not None

    async def _run(self, page: Page) -> ApplyResult:
        last_state: tuple[str, tuple[str, ...]] | None = None
        stuck = 0
        for _ in range(self.limits.max_form_steps):
            progress = await page.evaluate(_TAG_MODAL_JS)
            if progress is None:
                return await self.failure(page, "The Easy Apply dialog closed unexpectedly.")
            outcome = await self.fill_step(page, ROOT)
            if outcome.blocked:
                await self._discard(page)
                return self.needs_answer(outcome.blocked, page)
            if outcome.missing_files:
                await self._discard(page)
                return await self.failure(page, f"Could not upload: {', '.join(outcome.missing_files)}")
            await self._uncheck_follow(page)

            state = (str(progress), tuple(sorted(f.spec.label for f in outcome.fields)))
            stuck = stuck + 1 if state == last_state else 0
            if stuck >= 2:
                result = await self.failure(page, "Easy Apply did not advance (same step three times).")
                await self._discard(page)
                return result
            last_state = state

            if await find_button(page, SUBMIT, ROOT):
                if self.ctx.dry_run:
                    result = await self.dry_run_result(page)
                    await self._discard(page)
                    return result
                advanced, result = await self.click_and_validate(page, page, lambda: find_button(page, SUBMIT, ROOT), ROOT)
                if not advanced:
                    await self._discard(page)
                    return result  # type: ignore[return-value]
                return await self._confirm(page)

            pattern = REVIEW if await find_button(page, REVIEW, ROOT) else NEXT
            if not await find_button(page, pattern, ROOT):
                result = await self.failure(page, "No Next/Review/Submit button in the Easy Apply dialog.")
                await self._discard(page)
                return result
            advanced, result = await self.click_and_validate(page, page, lambda: find_button(page, pattern, ROOT), ROOT)
            if not advanced:
                await self._discard(page)
                return result  # type: ignore[return-value]
            await self.step_pause()
        result = await self.failure(page, f"Easy Apply exceeded {self.limits.max_form_steps} steps.")
        await self._discard(page)
        return result

    async def handle_documents(self, fields: list[FormField]) -> tuple[set[str], list[str]]:
        # LinkedIn keeps previously uploaded resumes; if one is already selected, don't upload another copy.
        if self._page is not None and await self._page.evaluate(_RESUME_SELECTED_JS):
            resume_ids = {f.field_id for f in fields if f.kind == "file" and "cover" not in f.spec.label.lower()}
            handled, missing = await super().handle_documents([f for f in fields if f.field_id not in resume_ids])
            return handled | resume_ids, missing
        return await super().handle_documents(fields)

    async def _uncheck_follow(self, page: Page) -> None:
        box = page.locator(f"{ROOT} #follow-company-checkbox").first
        label = page.locator(f'{ROOT} label[for="follow-company-checkbox"]').first
        try:
            if not (await box.count() and await box.is_checked()):
                return
            if await label.count() and await label.is_visible():
                await label.click(timeout=3000)
            elif await box.is_visible():
                await box.uncheck(timeout=3000)
        except PlaywrightError:
            pass

    async def _confirm(self, page: Page) -> ApplyResult:
        for _ in range(15):
            if SENT_RE.search(await visible_text(page)):
                await self._close_dialogs(page)
                return ApplyResult(JobStatus.APPLIED, notes="Submitted via LinkedIn Easy Apply")
            await page.wait_for_timeout(1000)
        if await self.confirm_submitted(page, timeout_ms=3000):
            await self._close_dialogs(page)
            return ApplyResult(JobStatus.APPLIED, notes="Submitted via LinkedIn Easy Apply")
        return await self.failure(page, "Clicked Submit but LinkedIn did not confirm the application was sent.")

    async def _close_dialogs(self, page: Page) -> None:
        for pattern in (r"^(done|not now)$", r"^dismiss$"):
            btn = await find_button(page, pattern, "[role=dialog]")
            if btn:
                try:
                    await btn.click()
                    await page.wait_for_timeout(500)
                except PlaywrightError:
                    pass

    async def _discard(self, page: Page) -> None:
        """Close the modal without submitting (LinkedIn asks to Save or Discard)."""
        try:
            dismiss = page.locator(f'{ROOT} button[aria-label="Dismiss"], {ROOT} button[aria-label*="Dismiss"]').first
            if await dismiss.count():
                await dismiss.click()
            else:
                await page.keyboard.press("Escape")
            await page.wait_for_timeout(800)
            confirm = page.locator('button[data-control-name="discard_application_confirm_btn"]').first
            if await confirm.count():
                await confirm.click()
            elif btn := await find_button(page, r"^discard$", "[role=dialog], [role=alertdialog]"):
                await btn.click()
            await page.wait_for_timeout(500)
        except PlaywrightError:
            pass
