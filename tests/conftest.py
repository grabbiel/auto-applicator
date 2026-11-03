from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from src.config import ENV_TEMPLATE, PROFILE_TEMPLATE, Profile, load_settings, read_yaml
from src.db import Database
from src.llm import FieldAnswer, FieldSpec, FormStepResponse, JobContext

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    h = tmp_path / "aa_home"
    h.mkdir()
    shutil.copyfile(PROFILE_TEMPLATE, h / "profile.yaml")
    shutil.copyfile(ENV_TEMPLATE, h / ".env")
    (h / "files").mkdir()
    (h / "files" / "resume.pdf").write_bytes(b"%PDF-1.4\n%fake resume\n")
    monkeypatch.setenv("AA_HOME", str(h))
    for var in ("IMAP_HOST", "IMAP_PORT", "IMAP_USER", "IMAP_APP_PASSWORD", "ATS_DEFAULT_PASSWORD"):
        monkeypatch.delenv(var, raising=False)
    return h


@pytest.fixture
def settings(home: Path):
    return load_settings(home)


@pytest.fixture
def profile() -> Profile:
    return Profile.model_validate(read_yaml(PROFILE_TEMPLATE))


@pytest.fixture
def db() -> Database:
    d = Database(":memory:")
    yield d
    d.close()


class FakeLLM:
    """Stands in for LLMClient: answers from a label->(answer, confidence) table."""

    def __init__(self, table: dict[str, tuple[str, str]] | None = None, default=("", "low"),
                 feedback_table: dict[str, tuple[str, str]] | None = None):
        self.table = table or {}
        self.feedback_table = feedback_table or {}
        self.evidence = "Backend engineer building Python services"  # words that occur in the example profile
        self.default = default
        self.calls: list[list[FieldSpec]] = []
        self.feedback: list[dict[str, str] | None] = []
        self.cover_letters = 0

    async def answer_fields(self, fields, profile_text, job, feedback=None):
        self.calls.append(list(fields))
        self.feedback.append(feedback)
        out = []
        for f in fields:
            ans, conf = self.default
            table = self.feedback_table if feedback and f.field_id in feedback else self.table
            for key, val in table.items():
                if key.lower() in f.label.lower():
                    ans, conf = val
                    break
            out.append(FieldAnswer(field_id=f.field_id, evidence=self.evidence, answer=ans, confidence=conf))
        return FormStepResponse(answers=out)

    async def cover_letter(self, profile_text, job):
        self.cover_letters += 1
        return f"Dear {job.company} team, I am excited to apply."

    async def check_submission(self, page_text):
        from src.llm import SubmissionCheck

        return SubmissionCheck(submitted="thank" in page_text.lower(), evidence="fake")

    async def extract_verification(self, text):
        from src.llm import EmailVerificationSchema

        return EmailVerificationSchema()


@pytest.fixture
def fake_llm() -> FakeLLM:
    return FakeLLM()


@pytest.fixture
def job() -> JobContext:
    return JobContext(title="Backend Engineer", company="Initech", location="Remote", description="Python, AWS")


def _chromium_available() -> bool:
    try:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            return Path(p.chromium.executable_path).exists()
    except Exception:
        return False


CHROMIUM = _chromium_available()


@pytest.fixture
async def page():
    if not CHROMIUM:
        pytest.skip("Playwright Chromium not installed")
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        pg = await browser.new_page(viewport={"width": 1280, "height": 900})
        pg.set_default_timeout(5000)
        yield pg
        await browser.close()


def fixture_url(name: str) -> str:
    return (FIXTURES / name).resolve().as_uri()
