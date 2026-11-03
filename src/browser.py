"""Persistent Chromium profile (log in to LinkedIn once) and external-application tab handling."""

from __future__ import annotations

import asyncio
import logging
from urllib.parse import urlparse

from playwright.async_api import BrowserContext, Locator, Page, Playwright, async_playwright
from playwright.async_api import Error as PlaywrightError
from playwright.async_api import TimeoutError as PlaywrightTimeout

from .config import BrowserSettings, Paths
from .forms import find_button

log = logging.getLogger(__name__)

LINKEDIN = "https://www.linkedin.com"


class BrowserError(RuntimeError):
    pass


class BrowserManager:
    def __init__(self, paths: Paths, settings: BrowserSettings, *, headless: bool = False):
        self.paths = paths
        self.settings = settings
        self.headless = headless
        self._pw: Playwright | None = None
        self.context: BrowserContext | None = None

    async def __aenter__(self) -> BrowserManager:
        await self.start()
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    async def start(self) -> BrowserContext:
        self.paths.chrome_profile.mkdir(parents=True, exist_ok=True)
        self._pw = await async_playwright().start()
        kwargs: dict = {
            "user_data_dir": str(self.paths.chrome_profile),
            "headless": self.headless,
            "viewport": {"width": self.settings.viewport_width, "height": self.settings.viewport_height},
            "accept_downloads": False,
        }
        if self.settings.channel == "chrome":
            kwargs["channel"] = "chrome"
        try:
            self.context = await self._pw.chromium.launch_persistent_context(**kwargs)
        except PlaywrightError as e:
            await self._pw.stop()
            msg = str(e)
            if "ProcessSingleton" in msg or "SingletonLock" in msg or "profile appears to be in use" in msg:
                raise BrowserError(
                    "The Auto Applicator browser is already open (another run is in progress). Close it and retry."
                ) from e
            if "Executable doesn't exist" in msg:
                raise BrowserError("The browser isn't installed. Run setup again (or: uv run playwright install chromium).") from e
            raise
        self.context.set_default_timeout(15000)
        self.context.set_default_navigation_timeout(45000)
        return self.context

    async def close(self) -> None:
        if self.context:
            try:
                await self.context.close()
            except PlaywrightError:
                pass
            self.context = None
        if self._pw:
            await self._pw.stop()
            self._pw = None

    @property
    def executable_path(self) -> str | None:
        return self._pw.chromium.executable_path if self._pw else None

    async def main_page(self) -> Page:
        assert self.context
        return self.context.pages[0] if self.context.pages else await self.context.new_page()

    # ------------------------------------------------------------------ LinkedIn session

    async def has_session_cookie(self) -> bool:
        assert self.context
        cookies = await self.context.cookies(LINKEDIN)
        return any(c["name"] == "li_at" and c.get("value") for c in cookies)

    async def is_logged_in(self, page: Page) -> bool:
        if not await self.has_session_cookie():
            return False
        try:
            await page.goto(f"{LINKEDIN}/feed/", wait_until="domcontentloaded")
        except PlaywrightError:
            return False
        path = urlparse(page.url).path
        return not any(p in path for p in ("/login", "/authwall", "/checkpoint", "/uas/"))

    # ------------------------------------------------------------------ external applications

    async def open_external_application(self, page: Page, apply_button: Locator, timeout_ms: int = 20000) -> Page:
        """Click an external "Apply" button and return the page holding the company's application.

        LinkedIn usually opens a new tab; sometimes it first shows a "share your profile / continue" dialog,
        and sometimes it navigates in the same tab.
        """
        assert self.context
        start_url = page.url
        new_page: Page | None = None
        try:
            async with self.context.expect_page(timeout=8000) as info:
                await apply_button.click()
            new_page = await info.value
        except PlaywrightTimeout:
            dialog_btn = await find_button(page, r"^(continue|apply|continue to apply)$", "[role=dialog]")
            if dialog_btn:
                try:
                    async with self.context.expect_page(timeout=8000) as info:
                        await dialog_btn.click()
                    new_page = await info.value
                except PlaywrightTimeout:
                    pass
        target = new_page or page
        if new_page is None and target.url == start_url:
            raise BrowserError("The external Apply button did not open the company site.")
        await self.wait_for_redirects(target, timeout_ms)
        return target

    @staticmethod
    async def wait_for_redirects(page: Page, timeout_ms: int = 20000, stable_ms: int = 1500) -> None:
        """Wait until the URL stops changing (tracking redirects) and the DOM is loaded."""
        try:
            await page.wait_for_load_state("domcontentloaded", timeout=timeout_ms)
        except PlaywrightTimeout:
            pass
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout_ms / 1000
        last, stable_since = page.url, loop.time()
        while loop.time() < deadline:
            await asyncio.sleep(0.25)
            if page.url != last:
                last, stable_since = page.url, loop.time()
            elif (loop.time() - stable_since) * 1000 >= stable_ms and page.url not in ("about:blank", ""):
                break
        try:
            await page.wait_for_load_state("networkidle", timeout=5000)
        except PlaywrightTimeout:
            pass
