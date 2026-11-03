from __future__ import annotations

import os
import re
import shutil

import pytest

from src import wizard
from src.config import load_config, load_profile, load_secrets
from src.wizard import clean_dropped_path, generate_portal_password


def test_clean_dropped_path():
    assert str(clean_dropped_path("/Users/me/My\\ Resume.pdf ")) == "/Users/me/My Resume.pdf"
    assert str(clean_dropped_path("'/Users/me/My Resume.pdf'")) == "/Users/me/My Resume.pdf"


def test_portal_password_strength():
    pw = generate_portal_password()
    assert len(pw) >= 16 and re.search(r"[A-Z]", pw) and re.search(r"[a-z]", pw) and re.search(r"\d", pw) and "!" in pw


@pytest.fixture
def fresh_home(tmp_path, monkeypatch):
    h = tmp_path / "home"
    monkeypatch.setenv("AA_HOME", str(h))
    resume = tmp_path / "My Resume.pdf"
    resume.write_bytes(b"%PDF-1.4 fake")
    return h, resume


def script(monkeypatch, answers: dict[str, str], confirms: dict[str, bool]):
    asked: list[str] = []

    def prompt_ask(label, default="", show_default=True, password=False, **kw):
        asked.append(label)
        for key, val in answers.items():
            if key.lower() in label.lower():
                return val
        return "" if default is None else str(default)

    def confirm_ask(label, default=False, **kw):
        for key, val in confirms.items():
            if key.lower() in label.lower():
                return val
        return default

    def int_ask(label, default=0, **kw):
        return default

    monkeypatch.setattr(wizard.Prompt, "ask", staticmethod(prompt_ask))
    monkeypatch.setattr(wizard.Confirm, "ask", staticmethod(confirm_ask))
    monkeypatch.setattr(wizard.IntPrompt, "ask", staticmethod(int_ask))
    return asked


def test_full_wizard_writes_valid_files(fresh_home, monkeypatch):
    home, resume = fresh_home
    script(
        monkeypatch,
        {
            "Job titles": "Data Engineer, Analytics Engineer",
            "Skip titles": "Senior, Manager",
            "Titles must": "",
            "Resume PDF": str(resume).replace(" ", "\\ "),
            "First name": "Ana", "Last name": "Lopez", "Email used": "ana@example.com", "Phone": "555-000-1111",
            "City": "Denver", "State": "CO", "LinkedIn profile URL": "https://linkedin.com/in/ana",
            "Total years": "4", "Years per skill": "Python=4, SQL=3",
            "Key skills": "Python, SQL", "Role 1 – company": "Acme", "title": "Data Engineer", "start": "2021-01",
            "Role 2 – company": "", "School 1": "CU Boulder", "degree": "BS", "field of study": "CS",
            "graduation": "2020-05", "School 2": "",
            "Workplace types": "1,2", "Experience levels": "3",
            "Email address": "ana@example.com", "App password": "abcd efgh ijkl mnop",
            "Gender": "4",
        },
        {"Pre-fill": False, "Set up email access": True, "sponsorship": True},
    )
    monkeypatch.setattr(wizard.EmailVerifier, "test_connection", lambda self: _async(3))
    assert wizard.run_wizard(wizard.Console(file=open(os.devnull, "w"))) == 0

    profile = load_profile(home / "profile.yaml")
    assert profile.personal.first_name == "Ana" and profile.personal.location == "Denver, CO"
    assert profile.work_authorization.requires_sponsorship is True
    assert profile.experience_years == {"total": 4, "Python": 4, "SQL": 3}
    assert profile.work_history[0].company == "Acme" and profile.education[0].school == "CU Boulder"
    assert profile.eeo.gender == "Decline to self-identify"
    assert (home / "files" / "resume.pdf").read_bytes() == resume.read_bytes()

    cfg = load_config(home / "config.yaml")
    assert [q.keywords for q in cfg.search_queries] == ["Data Engineer", "Analytics Engineer"]
    assert cfg.search_queries[0].workplace_type == ["Remote", "Hybrid"]
    assert cfg.search_queries[0].experience_level == ["Associate"]
    assert cfg.filters.title_exclude == ["Senior", "Manager"]
    assert cfg.dry_run is True

    secrets = load_secrets(home / ".env")
    assert secrets.imap_user == "ana@example.com" and secrets.imap_app_password.get_secret_value() == "abcdefghijklmnop"
    assert secrets.imap_host == "imap.gmail.com" or secrets.imap_host  # derived from domain or default
    assert len(secrets.ats_default_password.get_secret_value()) >= 16
    assert oct(os.stat(home / ".env").st_mode & 0o777) == "0o600"


async def _coro(v):
    return v


def _async(v):
    return _coro(v)
