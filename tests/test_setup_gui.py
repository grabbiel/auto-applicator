from __future__ import annotations

import os

import pytest

from src import setup_gui
from src.config import PROFILE_TEMPLATE, AppConfig, Paths, load_config, load_profile, load_secrets, read_yaml
from src.llm import ResumeEducation, ResumeExtraction, ResumeRole, SkillYears
from src.setup_gui import (
    SetupApp,
    blank_profile,
    check_required,
    config_to_search,
    form_to_profile,
    merge_extraction,
    profile_to_form,
    search_to_config,
)


@pytest.fixture(autouse=True)
def no_launchd(monkeypatch):
    """Never touch the real ~/Library/LaunchAgents from tests."""
    calls: list[str] = []
    monkeypatch.setattr(setup_gui.schedule, "is_installed", lambda: False)
    monkeypatch.setattr(setup_gui.schedule, "install", lambda settings: calls.append("install"))
    monkeypatch.setattr(setup_gui.schedule, "uninstall", lambda: calls.append("uninstall"))
    return calls


@pytest.fixture
def fresh(tmp_path, monkeypatch) -> SetupApp:
    monkeypatch.setenv("AA_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("AA_DEFAULT_MODEL", "qwen2.5:7b")
    for var in ("IMAP_HOST", "IMAP_PORT", "IMAP_USER", "IMAP_APP_PASSWORD", "ATS_DEFAULT_PASSWORD"):
        monkeypatch.delenv(var, raising=False)
    return SetupApp(Paths(tmp_path / "home"))


def extraction() -> ResumeExtraction:
    return ResumeExtraction(
        first_name="Jordan", last_name="Rivera", email="jordan@example.com", phone="303-555-0142", city="Denver",
        state="CO", country="USA", summary="Data analyst.", total_years_experience=6, skills=["SQL", "Excel"],
        experience_years=[SkillYears(skill="SQL", years=6)],
        work_history=[ResumeRole(company="Summit", title="Senior Data Analyst", start_date="2021-03")],
        education=[ResumeEducation(school="CU Boulder", degree="BS")],
    )


def test_profile_form_round_trip():
    profile = read_yaml(PROFILE_TEMPLATE)
    form = profile_to_form(profile)
    assert "experience_years" not in form and form["years_total"] != ""
    assert {"skill": "Python", "years": "6"} in form["years_rows"]
    back = form_to_profile(form)
    assert back["experience_years"] == {k: float(v) for k, v in profile["experience_years"].items()}
    assert back["personal"] == {**profile["personal"], **{k: v.strip() for k, v in profile["personal"].items() if isinstance(v, str)}}


def test_form_to_profile_cleans_user_input():
    form = profile_to_form(blank_profile())
    form["personal"] |= {"first_name": " Ana ", "last_name": "Lopez", "email": "ana@example.com", "phone": "555"}
    form["personal"]["address"]["city"] = "Denver"
    form["personal"]["address"]["state"] = "CO"
    form["compensation"]["desired_base"] = "$85,000"
    form["years_total"] = "4"
    form["years_rows"] = [{"skill": "Excel", "years": "3"}, {"skill": "", "years": "2"}, {"skill": "SQL", "years": ""}]
    form["work_history"] = [{"company": "Acme", "title": "Analyst"}, {"company": "", "title": ""}]
    p = form_to_profile(form)
    assert p["personal"]["first_name"] == "Ana" and p["personal"]["location"] == "Denver, CO"
    assert p["compensation"]["desired_base"] == 85000
    assert p["experience_years"] == {"total": 4.0, "Excel": 3.0}
    assert [r["company"] for r in p["work_history"]] == ["Acme"]


def test_merge_extraction_fills_only_blanks():
    draft = {"profile": profile_to_form(blank_profile()), "search": {"keywords": []}, "email": {"address": ""}}
    draft["profile"]["personal"]["first_name"] = "Jordy"  # typed by the user: must survive
    merged = merge_extraction(draft, extraction())
    pe = merged["profile"]["personal"]
    assert pe["first_name"] == "Jordy" and pe["last_name"] == "Rivera" and pe["address"]["city"] == "Denver"
    assert pe["address"]["country"] == "United States"  # "USA" is the same country: keep the default spelling
    assert merged["profile"]["years_total"] == "6" and merged["profile"]["years_rows"] == [{"skill": "SQL", "years": "6"}]
    assert merged["profile"]["work_history"][0]["end_date"] == "Present"
    assert merged["profile"]["education"][0]["gpa"] == ""
    assert merged["search"]["keywords"] == ["Senior Data Analyst"]
    assert merged["email"]["address"] == "jordan@example.com"
    assert draft["profile"]["personal"]["last_name"] == ""  # the input draft is not modified


def test_search_config_round_trip():
    cfg = load_config(Paths(PROFILE_TEMPLATE.parent).config_file)  # the template
    search = config_to_search(cfg, None)
    assert search["keywords"] == []  # the template's placeholder search isn't offered as the user's choice
    search |= {"keywords": ["Data Analyst", " BI Analyst ", "Data Analyst"], "workplace_type": ["Remote", "Hybrid"],
               "title_exclude": ["Senior", ""], "max_applies_per_run": "10", "dry_run": False, "schedule_time": "07:05"}
    new = search_to_config(search, cfg)
    assert isinstance(new, AppConfig)
    assert [q.keywords for q in new.search_queries] == ["Data Analyst", "BI Analyst"]
    assert new.search_queries[1].workplace_type == ["Remote", "Hybrid"]
    assert new.filters.title_exclude == ["Senior"] and new.limits.max_applies_per_run == 10
    assert new.dry_run is False and (new.schedule.hour, new.schedule.minute) == (7, 5)
    assert config_to_search(new, None)["keywords"] == ["Data Analyst", "BI Analyst"]


def test_check_required_reports_each_step():
    draft = {"profile": profile_to_form(blank_profile()), "search": {"keywords": []},
             "email": {"enabled": True, "address": "x@example.com", "password": "", "configured": False}}
    errors = check_required(draft, resume_present=False)
    steps = {e["step"] for e in errors}
    assert steps == {"resume", "about", "jobs", "email"}
    assert any(e["field"] == "profile.personal.first_name" for e in errors)
    draft["email"]["enabled"] = False
    assert "email" not in {e["step"] for e in check_required(draft, resume_present=False)}


def test_save_writes_profile_config_and_secrets(fresh, no_launchd):
    app = fresh
    assert app.mode == "first" and app.config.llm.text_model == "qwen2.5:7b"
    assert app.upload_resume(b"%PDF-1.4 fake", "My Resume.pdf", read_it=False)["ok"]
    assert not app.upload_resume(b"not a pdf", "x.docx", read_it=False)["ok"]
    draft = merge_extraction(app.draft, extraction())
    draft["search"] |= {"keywords": ["Data Analyst"], "schedule_enabled": True}
    draft["email"] |= {"enabled": True, "address": "jordan@gmail.com", "password": "abcd efgh ijkl mnop"}
    result = app.save(draft)
    assert result == {"ok": True, "warnings": []}
    assert no_launchd == ["install"] and app.mode == "edit"

    home = app.paths.home
    profile = load_profile(home / "profile.yaml")
    assert profile.personal.full_name == "Jordan Rivera" and profile.files.resume_pdf == "files/resume.pdf"
    assert profile.experience_years == {"total": 6.0, "SQL": 6.0}
    assert load_config(home / "config.yaml").search_queries[0].keywords == "Data Analyst"
    secrets = load_secrets(home / ".env")
    assert secrets.imap_host == "imap.gmail.com" and secrets.imap_app_password.get_secret_value() == "abcdefghijklmnop"
    assert len(secrets.ats_default_password.get_secret_value()) >= 16
    assert oct(os.stat(home / ".env").st_mode & 0o777) == "0o600"

    # Editing later keeps the saved email password when the field is left empty.
    again = SetupApp(app.paths)
    assert again.mode == "edit" and again.draft["email"]["configured"] is True
    again.draft["profile"]["personal"]["phone"] = "303-555-0199"
    assert again.save(again.draft)["ok"]
    assert load_secrets(home / ".env").imap_app_password.get_secret_value() == "abcdefghijklmnop"
    assert load_profile(home / "profile.yaml").personal.phone == "303-555-0199"


def test_save_rejects_incomplete_draft(fresh):
    result = fresh.save(fresh.draft)
    assert result["ok"] is False and result["errors"][0]["step"] == "resume"
    assert not fresh.paths.profile_file.exists()


def test_email_later_is_remembered(fresh):
    assert fresh.draft["email"]["enabled"] is True  # first time: "Set it up now" is suggested
    assert fresh.upload_resume(b"%PDF-1.4 fake", "resume.pdf", read_it=False)["ok"]
    draft = merge_extraction(fresh.draft, extraction())
    draft["search"]["keywords"] = ["Data Analyst"]
    draft["email"]["enabled"] = False
    assert fresh.save(draft)["ok"]
    again = SetupApp(fresh.paths)
    assert again.draft["email"]["enabled"] is False and again.draft["email"]["configured"] is False
