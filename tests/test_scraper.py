from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import pytest

from src.config import Filters, SearchQuery
from src.db import JobStatus
from src.scraper import _CARDS_JS, _SCROLL_JS, JobCard, build_search_url, filter_reason

from .conftest import fixture_url


def q(**kw) -> SearchQuery:
    return SearchQuery.model_validate({"keywords": "Data Engineer", "location": "Austin, TX", **kw})


def test_build_search_url_easy_apply_only():
    url = build_search_url(q(workplace_type=["Remote", "Hybrid"], experience_level=["Associate", "Mid-Senior level"],
                             date_posted="past_24h"), start=25)
    params = {k: v[0] for k, v in parse_qs(urlparse(url).query).items()}
    assert url.startswith("https://www.linkedin.com/jobs/search/?")
    assert params == {"keywords": "Data Engineer", "location": "Austin, TX", "f_WT": "2,3", "f_E": "3,4",
                      "f_TPR": "r86400", "f_AL": "true", "sortBy": "DD", "start": "25"}


def test_build_search_url_include_external_omits_easy_apply_filter():
    params = parse_qs(urlparse(build_search_url(q(include_external=True, date_posted="any"))).query)
    assert "f_AL" not in params and "f_TPR" not in params and "start" not in params


def test_filters():
    f = Filters(blacklist_companies=["BadCorp"], title_must_contain=["engineer"], title_exclude=["Manager"])
    card = lambda title, company="Good": JobCard("1", title, company, "Remote")  # noqa: E731
    assert filter_reason(card("Data Engineer", "badcorp"), f) == JobStatus.SKIPPED_BLACKLIST
    assert filter_reason(card("Engineering Manager"), f) == JobStatus.SKIPPED_TITLE_FILTER
    assert filter_reason(card("Data Scientist"), f) == JobStatus.SKIPPED_TITLE_FILTER
    assert filter_reason(card("Senior Data Engineer"), f) is None


@pytest.mark.browser
async def test_virtual_list_hydrates_all_cards(page):
    await page.goto(fixture_url("search.html"))
    before = await page.evaluate(_CARDS_JS)
    assert len([c for c in before if c["title"]]) < 25  # most cards are still empty placeholders
    await page.evaluate(_SCROLL_JS, 300)
    cards = [JobCard(**c) for c in await page.evaluate(_CARDS_JS)]
    assert len(cards) == 25 and all(c.title and c.company for c in cards)
    assert cards[3].company == "BadCorp" and cards[5].applied and not cards[4].applied
    assert cards[0].url == "https://www.linkedin.com/jobs/view/4000000000/"
