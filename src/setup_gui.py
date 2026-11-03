"""What's behind the app's setup screens (macos/App, reached through src/app_bridge.py).

The draft the screens edit is the profile as a dict (plus a few form-friendly fields), the job search and the email
settings. The screens walk the user through: install progress → resume (optionally read by the local AI) → about
you → work & pay → experience → jobs → email → LinkedIn sign-in. Saving writes the same profile.yaml / config.yaml /
.env as the terminal wizard.
"""

from __future__ import annotations

import asyncio
import copy
import imaplib
import logging
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from . import __version__, schedule
from .config import (
    CONFIG_TEMPLATE,
    EEO,
    PROJECT_ROOT,
    AppConfig,
    Compensation,
    ConfigError,
    Paths,
    Preferences,
    Profile,
    Secrets,
    WorkAuthorization,
    load_config,
    load_profile,
    load_secrets,
    write_env,
    write_yaml,
)
from .email_verifier import EmailVerifier
from .installer import Installer, recommended_model
from .llm import LLMClient, LLMError, ResumeExtraction
from .wizard import DATES, EEO_CHOICES, IMAP_HOSTS, LEVELS, WORKPLACE, generate_portal_password, resume_text

log = logging.getLogger(__name__)

MAX_RESUME_BYTES = 25 * 2**20
US_ALIASES = {"us", "usa", "u.s.", "u.s.a.", "united states", "united states of america", "america"}
DEFAULT_PORTAL_PASSWORD = "StrongPortalPassword123!"
DATE_LABELS = {"past_24h": "The last 24 hours", "past_week": "The last week", "past_month": "The last month", "any": "Any time"}


# --------------------------------------------------------------------------- form <-> files


def blank_profile() -> dict[str, Any]:
    return {
        "personal": {
            "first_name": "", "last_name": "", "preferred_name": "", "email": "", "phone": "", "phone_country_code": "+1",
            "address": {"street": "", "city": "", "state": "", "postal_code": "", "country": "United States"},
            "location": "", "linkedin": "", "github": "", "portfolio": "",
        },
        "work_authorization": WorkAuthorization(visa_status="").model_dump(),
        "compensation": Compensation().model_dump(),
        "preferences": Preferences().model_dump(),
        "summary": "",
        "skills": [],
        "experience_years": {},
        "work_history": [],
        "education": [],
        "certifications": [],
        "languages": ["English"],
        "eeo": EEO().model_dump(),
        "extra_answers": {},
        "files": {"resume_pdf": "files/resume.pdf", "cover_letter_pdf": None},
    }  # fmt: skip


def profile_to_form(profile: dict[str, Any]) -> dict[str, Any]:
    """The page edits the profile dict as-is, except years of experience become a total plus editable rows."""
    form = copy.deepcopy(profile)
    years = dict(form.pop("experience_years", None) or {})
    total = years.pop("total", None)
    form["years_total"] = "" if total is None else _fmt_num(total)
    form["years_rows"] = [{"skill": k, "years": _fmt_num(v)} for k, v in years.items()]
    for role in form.get("work_history") or []:
        role["end_date"] = role.get("end_date") or "Present"
    return form


def form_to_profile(form: dict[str, Any]) -> dict[str, Any]:
    p = copy.deepcopy(form)
    years: dict[str, float] = {}
    total = _num(p.pop("years_total", None))
    if total is not None:
        years["total"] = total
    for row in p.pop("years_rows", None) or []:
        skill, value = str(row.get("skill") or "").strip(), _num(row.get("years"))
        if skill and value is not None:
            years[skill] = value
    p["experience_years"] = years
    for key in ("desired_base", "range_min", "range_max"):
        value = _num(p["compensation"].get(key))
        p["compensation"][key] = int(value) if value is not None else None
    pe = p["personal"]
    for key, value in list(pe.items()):
        if isinstance(value, str):
            pe[key] = value.strip()
    addr = pe["address"]
    for key, value in list(addr.items()):
        addr[key] = (value or "").strip()
    if not pe.get("location"):
        pe["location"] = ", ".join(x for x in (addr.get("city"), addr.get("state")) if x)
    p["work_history"] = [_strip(r) for r in p.get("work_history") or [] if _has_text(r, "company", "title")]
    p["education"] = [_strip(e) for e in p.get("education") or [] if _has_text(e, "school", "degree")]
    for key in ("skills", "certifications", "languages"):
        p[key] = [str(x).strip() for x in p.get(key) or [] if str(x).strip()]
    p.setdefault("files", {})["resume_pdf"] = "files/resume.pdf"
    return p


def config_to_search(cfg: AppConfig, profile: Profile | None) -> dict[str, Any]:
    data = cfg.model_dump(mode="json")
    first = data["search_queries"][0] if data["search_queries"] else {}
    template_default = first.get("keywords") == "Software Engineer" and not data["filters"]["title_exclude"]
    keywords = [q["keywords"] for q in data["search_queries"]] if not template_default else []
    if not keywords and profile and profile.current_role:
        keywords = [profile.current_role.title]
    sch = data["schedule"]
    return {
        "keywords": keywords,
        "location": first.get("location") or "United States",
        "workplace_type": first.get("workplace_type", ["Remote"]),
        "experience_level": first.get("experience_level", []),
        "date_posted": first.get("date_posted", "past_week"),
        "include_external": first.get("include_external", False),
        "blacklist_companies": data["filters"]["blacklist_companies"],
        "title_must_contain": data["filters"]["title_must_contain"],
        "title_exclude": data["filters"]["title_exclude"],
        "max_applies_per_run": data["limits"]["max_applies_per_run"],
        "dry_run": data["dry_run"],
        "schedule_enabled": schedule.is_installed(),
        "schedule_time": f"{sch['hour']:02d}:{sch['minute']:02d}",
        "weekdays_only": sch["weekdays_only"],
    }


def search_to_config(search: dict[str, Any], cfg: AppConfig) -> AppConfig:
    data = cfg.model_dump(mode="json")
    first = data["search_queries"][0] if data["search_queries"] else {}
    common = {
        "location": str(search.get("location") or "").strip() or "United States",
        "workplace_type": list(search.get("workplace_type") or []),
        "experience_level": list(search.get("experience_level") or []),
        "date_posted": search.get("date_posted") or "past_week",
        "include_external": bool(search.get("include_external")),
        "max_pages": first.get("max_pages", 3),
    }
    keywords = dict.fromkeys(k.strip() for k in search.get("keywords") or [] if k.strip())
    data["search_queries"] = [{"keywords": k, **common} for k in keywords]
    data["filters"] = {key: _clean_list(search.get(key)) for key in ("blacklist_companies", "title_must_contain", "title_exclude")}
    data["limits"]["max_applies_per_run"] = max(1, int(_num(search.get("max_applies_per_run")) or 20))
    data["dry_run"] = bool(search.get("dry_run", True))
    hour, minute = _parse_time(str(search.get("schedule_time") or ""), data["schedule"])
    data["schedule"] = {"hour": hour, "minute": minute, "weekdays_only": bool(search.get("weekdays_only", True))}
    return AppConfig.model_validate(data)


def merge_extraction(draft: dict[str, Any], ex: ResumeExtraction) -> dict[str, Any]:
    """Fill the empty parts of the draft from what the AI read in the resume (never overwrites the user's input)."""
    d = copy.deepcopy(draft)
    form, search = d["profile"], d["search"]
    pe, addr = form["personal"], form["personal"]["address"]
    for key in ("first_name", "last_name", "email", "phone", "linkedin", "github", "portfolio"):
        value = (getattr(ex, key) or "").strip()
        if value and not pe.get(key):
            pe[key] = value
    for key in ("city", "state"):
        value = (getattr(ex, key) or "").strip()
        if value and not addr.get(key):
            addr[key] = value
    country = (ex.country or "").strip()
    if country and addr.get("country", "") in ("", "United States") and country.lower() not in US_ALIASES:
        addr["country"] = country
    if ex.summary and not form.get("summary"):
        form["summary"] = ex.summary.strip()
    for key in ("skills", "certifications"):
        if not form.get(key) and getattr(ex, key):
            form[key] = list(dict.fromkeys(s.strip() for s in getattr(ex, key) if s.strip()))
    if not form.get("years_rows"):
        form["years_rows"] = [{"skill": sy.skill, "years": _fmt_num(sy.years)} for sy in ex.experience_years if sy.skill]
    if form.get("years_total") in ("", None) and ex.total_years_experience:
        form["years_total"] = _fmt_num(ex.total_years_experience)
    if not form.get("work_history"):
        form["work_history"] = [r.model_dump() | {"end_date": r.end_date or "Present"} for r in ex.work_history]
    if not form.get("education"):
        form["education"] = [e.model_dump() | {"start_date": "", "gpa": ""} for e in ex.education]
    if not search.get("keywords") and ex.work_history:
        search["keywords"] = [ex.work_history[0].title]
    if not d["email"].get("address") and pe.get("email"):
        d["email"]["address"] = pe["email"]
    return d


def email_form(secrets: Secrets, profile: Profile | None) -> dict[str, Any]:
    user = secrets.imap_user if "@" in secrets.imap_user and "your_email" not in secrets.imap_user else ""
    return {
        "enabled": secrets.imap_configured or profile is None,  # remembers "Later" once set up
        "address": user or (profile.personal.email if profile else ""),
        "host": secrets.imap_host if user else "",
        "password": "",
        "configured": secrets.imap_configured,
    }


def imap_host_for(address: str) -> str | None:
    return IMAP_HOSTS.get(address.rpartition("@")[2].lower().strip())


def check_required(draft: dict[str, Any], resume_present: bool) -> list[dict[str, str]]:
    errors: list[dict[str, str]] = []

    def need(step: str, field: str, ok: Any, message: str) -> None:
        if not ok:
            errors.append({"step": step, "field": field, "message": message})

    pe = draft["profile"]["personal"]
    need("resume", "", resume_present, "Please add your resume (PDF).")
    need("about", "profile.personal.first_name", pe.get("first_name", "").strip(), "Please enter your first name.")
    need("about", "profile.personal.last_name", pe.get("last_name", "").strip(), "Please enter your last name.")
    need("about", "profile.personal.email", re.fullmatch(r"\S+@\S+\.\S+", pe.get("email", "").strip()),
         "Please enter the email address employers should use.")
    need("about", "profile.personal.phone", re.search(r"\d{3}", pe.get("phone", "")), "Please enter your phone number.")
    need("about", "profile.personal.address.city", pe["address"].get("city", "").strip(), "Please enter your city.")
    for i, role in enumerate(draft["profile"].get("work_history") or []):
        if _has_text(role, "company", "title") and not (str(role.get("company") or "").strip() and str(role.get("title") or "").strip()):
            need("experience", f"profile.work_history.{i}.title", False, "Each job needs both a job title and a company.")
    search = draft["search"]
    need("jobs", "search.keywords", any(k.strip() for k in search.get("keywords") or []), "Please enter at least one job title to search for.")
    email = draft["email"]
    if email.get("enabled"):
        need("email", "email.address", "@" in str(email.get("address") or ""), "Please enter your email address, or choose “Later”.")
        need("email", "email.password", email.get("password") or email.get("configured"),
             "Please enter the app password, or choose “Later”.")
    return errors


def _num(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = re.sub(r"[^\d.]", "", str(value).replace(",", ""))
    try:
        return float(cleaned) if cleaned else None
    except ValueError:
        return None


def _plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def _fmt_num(value: float | int | None) -> str:
    return "" if value is None else f"{float(value):g}"


def _strip(d: dict[str, Any]) -> dict[str, Any]:
    return {k: v.strip() if isinstance(v, str) else v for k, v in d.items()}


def _has_text(d: dict[str, Any], *keys: str) -> bool:
    return any(str(d.get(k) or "").strip() for k in keys)


def _clean_list(value: Any) -> list[str]:
    return list(dict.fromkeys(str(x).strip() for x in value or [] if str(x).strip()))


def _parse_time(raw: str, current: dict[str, Any]) -> tuple[int, int]:
    m = re.fullmatch(r"\s*(\d{1,2}):(\d{2})\s*", raw)
    if m and int(m.group(1)) < 24 and int(m.group(2)) < 60:
        return int(m.group(1)), int(m.group(2))
    return current["hour"], current["minute"]


def _error_step(loc: tuple[Any, ...]) -> str:
    head = str(loc[0]) if loc else ""
    if head == "personal":
        return "about"
    if head in ("work_authorization", "compensation", "preferences", "eeo"):
        return "work"
    return "experience"


# --------------------------------------------------------------------------- background jobs


class ImportJob:
    """Reads the resume with the local AI once the installer has the model ready."""

    def __init__(self, app: SetupApp):
        self.app = app
        self.status = "idle"  # idle | waiting | running | done | failed
        self.message = ""
        self.version = 0
        self.result: ResumeExtraction | None = None
        self._thread: threading.Thread | None = None

    @property
    def busy(self) -> bool:
        return self.status in ("waiting", "running")

    def snapshot(self) -> dict[str, Any]:
        return {"status": self.status, "message": self.message, "version": self.version}

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self.status, self.message = "waiting", "Waiting for the AI to finish installing…"
        self._thread = threading.Thread(target=self._run, name="resume-import", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        try:
            text = resume_text(self.app.resume_path)
        except Exception as e:  # noqa: BLE001 – pypdf raises many types
            self._fail(f"Couldn't read that PDF ({e}). Please type your details instead.")
            return
        if len(text) < 200:
            self._fail("This PDF has almost no selectable text (is it a scanned image?). Please type your details instead.")
            return
        while not self.app.installer.done.wait(1.0):
            self.message = ("The AI isn't installed yet – press Retry at the top, then this continues."
                            if self.app.installer.failed else "Waiting for the AI to finish installing…")
        self.status, self.message = "running", "Reading your resume… (about a minute)"
        try:
            self.result = asyncio.run(LLMClient(self.app.config.llm).extract_resume(text))
        except LLMError as e:
            self._fail(f"The AI couldn't read your resume ({e}). Please type your details instead.")
            return
        r = self.result
        found = [_plural(len(r.work_history), "job"), _plural(len(r.education), "school"), _plural(len(r.skills), "skill")]
        self.version += 1
        self.status = "done"
        self.message = (f"Done! We found {found[0]}, {found[1]} and {found[2]} in your resume and filled them in. "
                        "Please check them on the next pages.")

    def _fail(self, message: str) -> None:
        log.warning("Resume import: %s", message)
        self.status, self.message = "failed", message


class LoginJob:
    """Opens the app's browser on LinkedIn (a separate process) and waits until the user has signed in."""

    def __init__(self, app: SetupApp):
        self.app = app
        self.proc: subprocess.Popen | None = None
        self.status = "idle"  # idle | running | done | failed
        self.message = ""

    @property
    def busy(self) -> bool:
        self.snapshot()
        return self.status == "running"

    def start(self) -> None:
        if self.proc and self.proc.poll() is None:
            return
        out = open(self.app.paths.logs_dir / "linkedin-login.log", "ab")  # noqa: SIM115 – owned by the child
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "src.main", "--login", "--no-input"], cwd=PROJECT_ROOT, stdout=out, stderr=out,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        out.close()
        self.status, self.message = "running", "A browser window opened. Sign in there – this page updates when you're done."

    def snapshot(self) -> dict[str, Any]:
        if self.status == "running" and self.proc and (code := self.proc.poll()) is not None:
            if code == 0:
                self.status, self.message = "done", "You're signed in to LinkedIn."
            else:
                self.status, self.message = "failed", "Not signed in yet (the window was closed or it timed out). Try again."
        return {"status": self.status, "message": self.message}


# --------------------------------------------------------------------------- the app behind the page


class SetupApp:
    def __init__(self, paths: Paths):
        self.paths = paths.ensure()
        if not paths.config_file.exists():
            shutil.copyfile(CONFIG_TEMPLATE, paths.config_file)
        self.config = load_config(paths.config_file)
        self.notice = ""
        try:
            profile = load_profile(paths.profile_file)
        except ConfigError as e:
            profile, self.notice = None, f"Your saved profile couldn't be read, so you're starting fresh. ({e})"
        self.mode = "edit" if profile else "first"
        if self.mode == "first" and self.config.llm.text_model == "qwen2.5:7b" and recommended_model() != "qwen2.5:7b":
            self.config.llm.text_model = recommended_model()
            self._write_config(self.config)
        secrets = load_secrets(paths.env_file)
        self.draft: dict[str, Any] = {
            "profile": profile_to_form(profile.model_dump(mode="json") if profile else blank_profile()),
            "search": config_to_search(self.config, profile),
            "email": email_form(secrets, profile),
        }
        self.saved = profile is not None
        self.resume_name = "resume.pdf" if self.resume_path.exists() else ""
        self.installer = Installer(self.config.llm, self.config.browser.channel)
        self.imports = ImportJob(self)
        self.login = LoginJob(self)
        self.lock = threading.RLock()

    @property
    def resume_path(self) -> Path:
        return self.paths.files_dir / "resume.pdf"

    def state(self) -> dict[str, Any]:
        secrets = load_secrets(self.paths.env_file)
        portal = secrets.ats_default_password.get_secret_value()
        return {
            "mode": self.mode,
            "version": __version__,
            "home": str(self.paths.home),
            "notice": self.notice,
            "install": self.installer.snapshot(),
            "resume": {"present": self.resume_path.exists(), "name": self.resume_name},
            "import": self.imports.snapshot(),
            "linkedin": self.login.snapshot(),
            "saved": self.saved,
            "email_configured": secrets.imap_configured,
            "portal_password": portal if portal and portal != DEFAULT_PORTAL_PASSWORD else "",
            "schedule": schedule.describe(self.config.schedule) if schedule.is_installed() else "",
        }

    @staticmethod
    def options() -> dict[str, Any]:
        return {"workplace": WORKPLACE, "levels": LEVELS, "dates": [{"value": d, "label": DATE_LABELS.get(d, d)} for d in DATES],
                "eeo": EEO_CHOICES, "imap_domains": sorted(IMAP_HOSTS)}

    # ------------------------------------------------------------------ actions

    def upload_resume(self, data: bytes, filename: str, read_it: bool) -> dict[str, Any]:
        if not data.startswith(b"%PDF"):
            return {"ok": False, "message": "That file isn't a PDF. Please choose your resume as a PDF file."}
        tmp = self.resume_path.with_suffix(".part")
        tmp.write_bytes(data)
        os.replace(tmp, self.resume_path)
        self.resume_name = Path(filename).name or "resume.pdf"
        self.draft["profile"].setdefault("files", {})["resume_pdf"] = "files/resume.pdf"
        if read_it:
            self.imports.start()
        return {"ok": True}

    def test_email(self, address: str, password: str, host: str) -> dict[str, Any]:
        address, password = address.strip(), password.replace(" ", "").strip()
        if "@" not in address:
            return {"ok": False, "message": "Enter your full email address."}
        if not password:
            return {"ok": False, "message": "Enter the app password first."}
        host = host.strip() or imap_host_for(address) or ""
        if not host:
            return {"ok": False, "needs_host": True, "message": "We don't know this email provider's server. Enter its "
                    "IMAP server below (your provider's help pages list it, e.g. imap.example.com)."}
        test = Secrets(imap_host=host, imap_port=993, imap_user=address, imap_app_password=password)  # type: ignore[arg-type]

        async def go() -> int:
            return await asyncio.wait_for(EmailVerifier(test).test_connection(), 30)

        try:
            unread = asyncio.run(go())
        except imaplib.IMAP4.error:
            hint = " Gmail needs an App Password (16 letters), not your normal password." if "gmail" in host else (
                " Most providers need an app-specific password for this.")
            return {"ok": False, "host": host, "message": "The email address or password wasn't accepted." + hint}
        except (OSError, TimeoutError, socket.gaierror):
            return {"ok": False, "host": host, "needs_host": True,
                    "message": f"Couldn't reach the email server {host}. Check its name and your internet connection."}
        return {"ok": True, "host": host, "message": f"Connected! Your inbox has {unread} unread email(s)."}

    def save(self, draft: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            self.draft = draft
            errors = check_required(draft, self.resume_path.exists())
            if errors:
                return {"ok": False, "errors": errors}
            profile_data = form_to_profile(draft["profile"])
            try:
                # Written in the model's field order (the app's draft has no reliable key order).
                profile_data = Profile.model_validate(profile_data).model_dump(mode="json")
            except ValidationError as e:
                return {"ok": False, "errors": [
                    {"step": _error_step(err["loc"]), "field": "profile." + ".".join(map(str, err["loc"])), "message": err["msg"]}
                    for err in e.errors()[:6]
                ]}
            try:
                config = search_to_config(draft["search"], self.config)
            except ValidationError as e:
                return {"ok": False, "errors": [{"step": "jobs", "field": "", "message": err["msg"]} for err in e.errors()[:6]]}

            write_yaml(self.paths.profile_file, profile_data, "# Auto Applicator profile – edit freely, or use the app's My details page.")
            self._write_config(config)
            self.config = config
            self._save_secrets(draft["email"])
            warnings = self._apply_schedule(bool(draft["search"].get("schedule_enabled")))
            self.saved, self.mode = True, "edit"
            log.info("Setup saved (%d searches)", len(config.search_queries))
            return {"ok": True, "warnings": warnings}

    def _write_config(self, config: AppConfig) -> None:
        write_yaml(self.paths.config_file, config.model_dump(mode="json"),
                   f"# Auto Applicator settings. Commented reference: {CONFIG_TEMPLATE}")

    def _save_secrets(self, email: dict[str, Any]) -> None:
        secrets = load_secrets(self.paths.env_file)
        values: dict[str, str] = {}
        password = str(email.get("password") or "").replace(" ", "").strip()
        if email.get("enabled") and password:
            address = str(email.get("address") or "").strip()
            host = str(email.get("host") or "").strip() or imap_host_for(address) or secrets.imap_host
            values |= {"IMAP_HOST": host, "IMAP_PORT": str(secrets.imap_port or 993), "IMAP_USER": address,
                       "IMAP_APP_PASSWORD": password}
        portal = secrets.ats_default_password.get_secret_value()
        if not portal or portal == DEFAULT_PORTAL_PASSWORD:
            values["ATS_DEFAULT_PASSWORD"] = generate_portal_password()
        if values:
            write_env(self.paths.env_file, values)

    def _apply_schedule(self, enabled: bool) -> list[str]:
        try:
            if enabled:
                from .config import load_settings

                schedule.install(load_settings(self.paths.home))
            elif schedule.is_installed():
                schedule.uninstall()
        except (RuntimeError, ConfigError) as e:
            log.warning("Schedule: %s", e)
            return [f"The daily schedule couldn't be set up: {e}"]
        return []
