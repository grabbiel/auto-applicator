"""LinkedIn job search: URL builder, virtual-scroll job collector, filters and job-detail inspection."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Literal
from urllib.parse import urlencode

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Locator, Page

from .config import Filters, SearchQuery
from .db import JobStatus

log = logging.getLogger(__name__)

SEARCH_BASE = "https://www.linkedin.com/jobs/search/"
WORKPLACE = {"On-site": "1", "Remote": "2", "Hybrid": "3"}
EXPERIENCE = {"Internship": "1", "Entry level": "2", "Associate": "3", "Mid-Senior level": "4", "Director": "5", "Executive": "6"}
DATE_POSTED = {"any": None, "past_month": "r2592000", "past_week": "r604800", "past_24h": "r86400"}
PAGE_SIZE = 25


@dataclass
class JobCard:
    job_id: str
    title: str
    company: str
    location: str
    applied: bool = False

    @property
    def url(self) -> str:
        return f"https://www.linkedin.com/jobs/view/{self.job_id}/"


ApplyKind = Literal["easy_apply", "external", "applied", "closed", "unknown"]


@dataclass
class JobDetails:
    kind: ApplyKind
    description: str
    apply_button: Locator | None


def build_search_url(q: SearchQuery, start: int = 0) -> str:
    params: dict[str, str] = {"keywords": q.keywords, "location": q.location}
    if q.workplace_type:
        params["f_WT"] = ",".join(WORKPLACE[w] for w in q.workplace_type)
    if q.experience_level:
        params["f_E"] = ",".join(EXPERIENCE[e] for e in q.experience_level)
    if tpr := DATE_POSTED[q.date_posted]:
        params["f_TPR"] = tpr
    if not q.include_external:
        params["f_AL"] = "true"
    params["sortBy"] = "DD"
    if start:
        params["start"] = str(start)
    return f"{SEARCH_BASE}?{urlencode(params)}"


def filter_reason(card: JobCard, filters: Filters) -> JobStatus | None:
    company = card.company.strip().casefold()
    if company and company in {c.strip().casefold() for c in filters.blacklist_companies}:
        return JobStatus.SKIPPED_BLACKLIST
    title = card.title.casefold()
    if any(x.casefold() in title for x in filters.title_exclude if x.strip()):
        return JobStatus.SKIPPED_TITLE_FILTER
    must = [x.casefold() for x in filters.title_must_contain if x.strip()]
    if must and not any(x in title for x in must):
        return JobStatus.SKIPPED_TITLE_FILTER
    return None


_SCROLL_JS = r"""
async (step) => {
  const first = document.querySelector('[data-occludable-job-id], [data-job-id]');
  if (!first) return 0;
  let box = first.parentElement;
  while (box && box !== document.body) {
    const oy = getComputedStyle(box).overflowY;
    if ((oy === 'auto' || oy === 'scroll') && box.scrollHeight > box.clientHeight + 10) break;
    box = box.parentElement;
  }
  if (!box || box === document.body) box = document.scrollingElement;
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  let guard = 0;
  while (box.scrollTop + box.clientHeight < box.scrollHeight - 5 && guard++ < 80) {
    box.scrollTop += step;
    await sleep(220);
  }
  await sleep(400);
  box.scrollTop = 0;
  return document.querySelectorAll('[data-occludable-job-id], [data-job-id]').length;
}
"""

_CARDS_JS = r"""
() => {
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const dedupe = s => { const m = s.match(/^(.{3,}?)\s*\1$/); return m ? m[1] : s; };
  const txt = (root, sels) => { for (const s of sels) { const e = root.querySelector(s); if (e && clean(e.innerText)) return dedupe(clean(e.innerText)); } return ''; };
  const out = []; const seen = new Set();
  const nodes = document.querySelectorAll('[data-occludable-job-id], [data-job-id]');
  for (const n of nodes) {
    let id = n.getAttribute('data-occludable-job-id') || n.getAttribute('data-job-id');
    const link = n.querySelector('a[href*="/jobs/view/"]');
    if ((!id || !/^\d+$/.test(id)) && link) { const m = link.href.match(/\/jobs\/view\/(\d+)/); if (m) id = m[1]; }
    if (!id || seen.has(id)) continue; seen.add(id);
    const title = link ? dedupe(clean(link.getAttribute('aria-label') || link.innerText)).replace(/ with verification$/i, '') :
      txt(n, ['.job-card-list__title', '.job-card-container__link', 'strong']);
    const company = txt(n, ['.artdeco-entity-lockup__subtitle', '.job-card-container__primary-description', '.job-card-container__company-name']);
    const location = txt(n, ['.artdeco-entity-lockup__caption', '.job-card-container__metadata-wrapper', '.job-card-container__metadata-item']);
    const footer = clean(n.innerText);
    out.push({job_id: id, title, company, location, applied: /\bApplied\b/.test(footer)});
  }
  return out;
}
"""

_DESCRIPTION_SELECTORS = ["#job-details", ".jobs-description__content", ".jobs-box__html-content", "article", "main"]


class LinkedInScraper:
    def __init__(self, scroll_step: int = 300):
        self.scroll_step = scroll_step

    async def collect_page(self, page: Page, query: SearchQuery, page_no: int) -> list[JobCard]:
        """Load one search-results page (25 jobs), scroll it so every card hydrates, and parse the cards."""
        await page.goto(build_search_url(query, page_no * PAGE_SIZE), wait_until="domcontentloaded")
        try:
            await page.wait_for_selector("[data-occludable-job-id], [data-job-id]", timeout=15000)
        except PlaywrightError:
            log.info("No job cards on page %d for %r", page_no + 1, query.keywords)
            return []
        await page.evaluate(_SCROLL_JS, self.scroll_step)
        raw = await page.evaluate(_CARDS_JS)
        return [JobCard(**r) for r in raw]

    async def open_job(self, page: Page, card: JobCard) -> JobDetails:
        await page.goto(card.url, wait_until="domcontentloaded")
        try:
            await page.wait_for_selector("main", timeout=15000)
            await page.wait_for_timeout(1500)
        except PlaywrightError:
            pass
        description = ""
        for sel in _DESCRIPTION_SELECTORS:
            loc = page.locator(sel).first
            try:
                if await loc.count():
                    description = (await loc.inner_text(timeout=3000)).strip()
                    if len(description) > 200:
                        break
            except PlaywrightError:
                continue

        main = page.locator("main").first
        easy = main.get_by_role("button", name=re.compile(r"easy apply", re.I))
        if await _first_visible(easy):
            return JobDetails("easy_apply", description, await _first_visible(easy))
        external = main.get_by_role("button", name=re.compile(r"^apply\b", re.I)).or_(
            main.get_by_role("link", name=re.compile(r"^apply\b", re.I))
        )
        if btn := await _first_visible(external):
            return JobDetails("external", description, btn)
        top = (await main.inner_text())[:3000] if await main.count() else ""
        if re.search(r"\bApplied\b.{0,40}\bago\b|Application submitted", top):
            return JobDetails("applied", description, None)
        if re.search(r"No longer accepting applications", top, re.I):
            return JobDetails("closed", description, None)
        return JobDetails("unknown", description, None)


async def _first_visible(loc: Locator) -> Locator | None:
    try:
        n = await loc.count()
    except PlaywrightError:
        return None
    for i in range(min(n, 5)):
        item = loc.nth(i)
        try:
            if await item.is_visible():
                return item
        except PlaywrightError:
            continue
    return None
