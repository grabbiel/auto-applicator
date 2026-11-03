"""ATS handlers and routing from an application URL to the right handler."""

from __future__ import annotations

import logging
import re
from urllib.parse import urlparse

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Page

from ..db import ATSType
from .ashby import AshbyHandler
from .base import ApplyContext, ApplyResult, BaseHandler, GenericAXTreeHandler
from .easy_apply import EasyApplyHandler
from .greenhouse import GreenhouseHandler
from .lever import LeverHandler
from .workday import WorkdayHandler

log = logging.getLogger(__name__)

__all__ = [
    "ApplyContext", "ApplyResult", "BaseHandler", "EasyApplyHandler", "GenericAXTreeHandler",
    "GreenhouseHandler", "LeverHandler", "AshbyHandler", "WorkdayHandler", "detect_ats", "handler_for",
    "resolve_embedded",
]  # fmt: skip

HANDLERS: dict[ATSType, type[BaseHandler]] = {
    ATSType.GREENHOUSE: GreenhouseHandler,
    ATSType.LEVER: LeverHandler,
    ATSType.ASHBY: AshbyHandler,
    ATSType.WORKDAY: WorkdayHandler,
    ATSType.GENERIC_EXTERNAL: GenericAXTreeHandler,
}


def detect_ats(url: str) -> ATSType:
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    if host.endswith("greenhouse.io") or "gh_jid=" in parsed.query:
        return ATSType.GREENHOUSE
    if host.endswith("lever.co"):
        return ATSType.LEVER
    if host.endswith("ashbyhq.com"):
        return ATSType.ASHBY
    if re.search(r"(myworkdayjobs|myworkdaysite)\.com$|\.workday\.com$", host):
        return ATSType.WORKDAY
    return ATSType.GENERIC_EXTERNAL


def handler_for(ats: ATSType) -> type[BaseHandler]:
    return HANDLERS.get(ats, GenericAXTreeHandler)


async def resolve_embedded(page: Page) -> ATSType:
    """Company career pages often embed Greenhouse/Lever/Ashby in an iframe; open the iframe directly."""
    for frame in page.frames:
        if frame == page.main_frame or not frame.url.startswith("http"):
            continue
        ats = detect_ats(frame.url)
        if ats in (ATSType.GREENHOUSE, ATSType.LEVER, ATSType.ASHBY):
            log.info("Found embedded %s form; opening %s", ats.value, frame.url)
            try:
                await page.goto(frame.url, wait_until="domcontentloaded")
                return ats
            except PlaywrightError:
                return ATSType.GENERIC_EXTERNAL
    if "gh_jid=" in page.url:
        return ATSType.GENERIC_EXTERNAL  # Greenhouse id in the URL but no iframe yet: let the generic handler try
    return detect_ats(page.url)
