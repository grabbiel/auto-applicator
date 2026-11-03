"""Interactive setup wizard: builds profile.yaml, config.yaml and .env for a new user.

Optionally pre-fills the profile from the user's resume PDF using the local model, then asks the user to
confirm or correct every section. Re-running it keeps existing values as defaults.
"""

from __future__ import annotations

import asyncio
import re
import secrets as pysecrets
import shutil
import string
from pathlib import Path
from typing import Any

from pydantic import ValidationError
from rich.console import Console
from rich.panel import Panel
from rich.prompt import Confirm, IntPrompt, Prompt
from rich.table import Table

from .config import (
    CONFIG_TEMPLATE,
    DECLINE,
    AppConfig,
    Paths,
    Profile,
    Secrets,
    load_config,
    load_profile,
    load_secrets,
    write_env,
    write_yaml,
)
from .email_verifier import EmailVerifier
from .installer import recommended_model
from .llm import LLMClient, LLMError, ResumeExtraction

WORKPLACE = ["Remote", "Hybrid", "On-site"]
LEVELS = ["Internship", "Entry level", "Associate", "Mid-Senior level", "Director", "Executive"]
DATES = ["past_24h", "past_week", "past_month", "any"]
EEO_CHOICES = {
    "gender": ["Male", "Female", "Non-binary", DECLINE],
    "hispanic_or_latino": ["Yes", "No", DECLINE],
    "ethnicity": [
        "American Indian or Alaska Native", "Asian", "Black or African American", "Hispanic or Latino",
        "Native Hawaiian or Other Pacific Islander", "White", "Two or More Races", DECLINE,
    ],
    "veteran_status": ["I am not a protected veteran", "I identify as one or more of the classifications of protected veteran", DECLINE],
    "disability_status": ["No, I do not have a disability", "Yes, I have a disability (or previously had a disability)", DECLINE],
}  # fmt: skip
IMAP_HOSTS = {
    "gmail.com": "imap.gmail.com", "googlemail.com": "imap.gmail.com", "outlook.com": "outlook.office365.com",
    "hotmail.com": "outlook.office365.com", "live.com": "outlook.office365.com", "icloud.com": "imap.mail.me.com",
    "me.com": "imap.mail.me.com", "yahoo.com": "imap.mail.yahoo.com", "fastmail.com": "imap.fastmail.com",
}  # fmt: skip


# --------------------------------------------------------------------------- prompt helpers


class Wizard:
    def __init__(self, console: Console, paths: Paths):
        self.c = console
        self.paths = paths

    def ask(self, label: str, default: Any = "", *, required: bool = False) -> str:
        default = "" if default is None else str(default)
        while True:
            value = Prompt.ask(f"  {label}", default=default, show_default=bool(default)).strip()
            if value or not required:
                return value
            self.c.print("  [red]This one is required.[/]")

    def yes(self, label: str, default: bool) -> bool:
        return Confirm.ask(f"  {label}", default=default)

    def number(self, label: str, default: int | None) -> int | None:
        raw = self.ask(f"{label} (digits, blank to skip)", default if default is not None else "")
        digits = re.sub(r"[^\d]", "", raw)
        return int(digits) if digits else None

    def choose(self, label: str, options: list[str], default: str) -> str:
        self.c.print(f"  {label}")
        for i, o in enumerate(options, 1):
            self.c.print(f"    {i}. {o}")
        idx = options.index(default) + 1 if default in options else len(options)
        while True:
            raw = self.ask(f"{label} – choose a number, or type your own answer", idx)
            if raw.isdigit() and 1 <= int(raw) <= len(options):
                return options[int(raw) - 1]
            if raw:
                return raw

    def choose_many(self, label: str, options: list[str], defaults: list[str]) -> list[str]:
        self.c.print(f"  {label}")
        for i, o in enumerate(options, 1):
            self.c.print(f"    {i}. {o}")
        default = ",".join(str(options.index(d) + 1) for d in defaults if d in options)
        raw = self.ask(f"{label} – numbers separated by commas (blank = any)", default)
        picked = [options[int(x) - 1] for x in re.findall(r"\d+", raw) if 1 <= int(x) <= len(options)]
        return list(dict.fromkeys(picked))

    def section(self, title: str, note: str = "") -> None:
        self.c.print()
        self.c.rule(f"[bold cyan]{title}")
        if note:
            self.c.print(f"[dim]{note}[/]")


def clean_dropped_path(raw: str) -> Path:
    """Paths dragged into Terminal come quoted or with backslash-escaped spaces."""
    raw = raw.strip().strip("'\"")
    raw = re.sub(r"\\(.)", r"\1", raw)
    return Path(raw).expanduser()


def resume_text(pdf: Path) -> str:
    from pypdf import PdfReader

    reader = PdfReader(str(pdf))
    return "\n".join((page.extract_text() or "") for page in reader.pages).strip()


def generate_portal_password() -> str:
    alphabet = string.ascii_letters + string.digits
    core = "".join(pysecrets.choice(alphabet) for _ in range(14))
    return f"{core[:7]}!{core[7:]}9aZ"  # always satisfies upper/lower/digit/symbol rules


def _csv(items: list[str]) -> str:
    return ", ".join(items)


def _split_csv(raw: str) -> list[str]:
    return [x.strip() for x in raw.split(",") if x.strip()]


# --------------------------------------------------------------------------- the flow


def run_wizard(console: Console) -> int:
    paths = Paths.default().ensure()
    w = Wizard(console, paths)
    try:
        existing = load_profile(paths.profile_file)
    except Exception:  # noqa: BLE001 – a broken profile is simply rebuilt
        existing = None
    config = load_config(paths.config_file)
    secrets = load_secrets(paths.env_file)

    console.print(Panel(
        "This sets up Auto Applicator for [bold]you[/]. It asks about your resume, profile, the jobs you want and "
        "your email.\nPress [bold]Enter[/] to keep the value shown in (parentheses). You can re-run setup any time.\n\n"
        f"Your information stays on this Mac, in:\n[cyan]{paths.home}[/]",
        title="Auto Applicator setup", border_style="cyan",
    ))
    sections = ["Everything", "Profile only", "Job search only", "Email only"]
    what = w.choose("What would you like to set up?", sections, "Everything") if existing else "Everything"

    if what in ("Everything", "Profile only"):
        profile_data = profile_flow(w, existing, config)
        write_yaml(paths.profile_file, profile_data, "# Auto Applicator profile – edit freely, or re-run setup.")
        console.print(f"[green]✓ Saved profile → {paths.profile_file}[/]")
        existing = Profile.model_validate(profile_data)
    if what in ("Everything", "Job search only"):
        config = search_flow(w, config, existing)
        write_yaml(paths.config_file, config.model_dump(mode="json"),
                   f"# Auto Applicator settings. Commented reference: {CONFIG_TEMPLATE}")
        console.print(f"[green]✓ Saved settings → {paths.config_file}[/]")
    if what in ("Everything", "Email only"):
        email_flow(w, secrets, existing)

    console.print(Panel(
        "Next steps (in the Auto Applicator app):\n"
        "  1. [bold]Sign in to LinkedIn[/] – once.\n"
        "  2. [bold]Practice run[/] – fills applications without submitting; review the screenshots in logs/screenshots.\n"
        "  3. [bold]Questions[/] – answer anything your profile didn't cover.\n"
        "  4. [bold]Apply now[/] when you're happy with the dry-run results.",
        title="All set", border_style="green",
    ))
    return 0


def profile_flow(w: Wizard, existing: Profile | None, config: AppConfig) -> dict:
    c, paths = w.c, w.paths
    e = existing.model_dump(mode="json") if existing else {}
    pe = e.get("personal", {})

    # ---- resume
    w.section("1. Resume", "Drag your resume PDF into this window (or type its path), then press Enter.")
    current_resume = paths.resolve_user_path(existing.files.resume_pdf) if existing else None
    while True:
        raw = w.ask("Resume PDF", current_resume if current_resume and current_resume.exists() else "", required=True)
        src = clean_dropped_path(raw)
        if src.exists() and src.suffix.lower() == ".pdf":
            break
        c.print(f"  [red]Couldn't find a PDF at {src}[/]")
    dest = paths.files_dir / "resume.pdf"
    if src.resolve() != dest.resolve():
        shutil.copyfile(src, dest)
    c.print(f"  [green]✓ Resume copied to {dest}[/]")

    extracted: ResumeExtraction | None = None
    if w.yes("Pre-fill your profile from the resume using the local AI model?", existing is None):
        extracted = import_resume(w, dest, config)

    def pick(key: str, section: dict, attr: str | None = None) -> Any:
        if section.get(key):
            return section[key]
        if extracted is not None:
            return getattr(extracted, attr or key, None)
        return None

    # ---- personal
    w.section("2. Contact details")
    addr = pe.get("address", {})
    personal = {
        "first_name": w.ask("First name", pick("first_name", pe), required=True),
        "last_name": w.ask("Last name", pick("last_name", pe), required=True),
        "preferred_name": w.ask("Preferred first name (blank if same)", pe.get("preferred_name", "")),
        "email": w.ask("Email used on applications", pick("email", pe), required=True),
        "phone": w.ask("Phone", pick("phone", pe), required=True),
        "phone_country_code": w.ask("Phone country code", pe.get("phone_country_code", "+1")),
    }
    address = {
        "street": w.ask("Street address (blank to skip)", addr.get("street", "")),
        "city": w.ask("City", addr.get("city") or (extracted.city if extracted else ""), required=True),
        "state": w.ask("State / province", addr.get("state") or (extracted.state if extracted else "")),
        "postal_code": w.ask("ZIP / postal code", addr.get("postal_code", "")),
        "country": w.ask("Country", addr.get("country") or (extracted.country if extracted and extracted.country else "United States")),
    }
    personal["address"] = address
    default_loc = pe.get("location") or ", ".join(x for x in (address["city"], address["state"]) if x)
    personal["location"] = w.ask("Location as shown on applications", default_loc)
    personal["linkedin"] = w.ask("LinkedIn profile URL", pick("linkedin", pe))
    personal["github"] = w.ask("GitHub URL (blank to skip)", pick("github", pe))
    personal["portfolio"] = w.ask("Portfolio / website (blank to skip)", pick("portfolio", pe))

    # ---- authorization & preferences
    w.section("3. Work authorization")
    wa = e.get("work_authorization", {})
    authorized = w.yes("Are you legally authorized to work in the country you're applying in?", wa.get("authorized_to_work_us", True))
    sponsorship = w.yes("Will you now or in the future need visa sponsorship?", wa.get("requires_sponsorship", False))
    work_auth = {
        "authorized_to_work_us": authorized,
        "requires_sponsorship": sponsorship,
        "visa_status": w.ask("Citizenship / visa status (e.g. US Citizen, Green Card, H-1B, F-1 OPT)", wa.get("visa_status", "US Citizen")),
        "citizenship": w.ask("Country of citizenship", wa.get("citizenship", "")),
        "security_clearance": w.ask("Security clearance", wa.get("security_clearance", "None")),
    }

    w.section("4. Compensation & availability")
    comp = e.get("compensation", {})
    compensation = {
        "desired_base": w.number("Desired base salary", comp.get("desired_base")),
        "range_min": w.number("Lowest base salary you'd accept", comp.get("range_min")),
        "range_max": w.number("Top of your range", comp.get("range_max")),
        "currency": w.ask("Currency", comp.get("currency", "USD")),
    }
    pr = e.get("preferences", {})
    preferences = {
        "willing_to_relocate": w.yes("Willing to relocate?", pr.get("willing_to_relocate", False)),
        "open_to_remote": True,
        "open_to_hybrid": w.yes("Open to hybrid roles?", pr.get("open_to_hybrid", True)),
        "open_to_onsite": w.yes("Open to on-site roles?", pr.get("open_to_onsite", True)),
        "notice_period": w.ask("Notice period", pr.get("notice_period", "2 weeks")),
        "earliest_start_date": w.ask("Earliest start date", pr.get("earliest_start_date", "2 weeks after offer")),
        "over_18": w.yes("Are you 18 or older?", pr.get("over_18", True)),
        "how_did_you_hear": pr.get("how_did_you_hear", "LinkedIn"),
    }

    # ---- experience
    w.section("5. Experience", "Used for questions like 'How many years of Python do you have?'")
    years: dict[str, float] = dict(e.get("experience_years") or {})
    if not years and extracted:
        years = {sy.skill: sy.years for sy in extracted.experience_years if sy.skill}
        if extracted.total_years_experience:
            years = {"total": extracted.total_years_experience, **years}
    total = w.number("Total years of professional experience", int(years.get("total", 0)) or None)
    if total is not None:
        years["total"] = total
    shown = ", ".join(f"{k}={v:g}" for k, v in years.items() if k != "total")
    raw = w.ask("Years per skill, like 'Python=6, SQL=4' (edit or Enter to keep)", shown)
    years = {"total": years.get("total", total or 0)} | {
        k.strip(): float(v) for k, v in re.findall(r"([^=,]+)=\s*(\d+(?:\.\d+)?)", raw) if k.strip()
    }
    skills = _split_csv(w.ask("Key skills (comma separated)", _csv(e.get("skills") or (extracted.skills if extracted else []))))

    w.section("6. Work history & education")
    work_history = e.get("work_history") or ([r.model_dump() for r in extracted.work_history] if extracted else [])
    education = e.get("education") or ([ed.model_dump() for ed in extracted.education] if extracted else [])
    show_history(w, work_history, education)
    if not work_history or not w.yes("Does this look right?", True):
        work_history, education = edit_history(w, work_history, education)
    for ed in education:
        ed.setdefault("start_date", "")
        ed.setdefault("gpa", "")
    summary = w.ask("One-sentence professional summary", e.get("summary") or (extracted.summary if extracted else ""))

    # ---- EEO
    w.section("7. Voluntary self-identification (EEO)",
              "Used only for optional diversity questions. 'Decline to self-identify' is always fine.")
    eeo_prev = e.get("eeo", {})
    eeo = {key: w.choose(key.replace("_", " ").capitalize(), opts, eeo_prev.get(key, DECLINE)) for key, opts in EEO_CHOICES.items()}
    eeo["sexual_orientation"] = eeo_prev.get("sexual_orientation", DECLINE)
    eeo["pronouns"] = w.ask("Pronouns (blank to skip)", eeo_prev.get("pronouns", ""))

    data = {
        "personal": personal,
        "work_authorization": work_auth,
        "compensation": compensation,
        "preferences": preferences,
        "summary": summary,
        "skills": skills,
        "experience_years": years,
        "work_history": work_history,
        "education": education,
        "certifications": e.get("certifications") or (extracted.certifications if extracted else []),
        "languages": e.get("languages") or ["English"],
        "eeo": eeo,
        "extra_answers": e.get("extra_answers") or {},
        "files": {"resume_pdf": "files/resume.pdf", "cover_letter_pdf": (e.get("files") or {}).get("cover_letter_pdf")},
    }
    try:
        Profile.model_validate(data)
    except ValidationError as err:
        w.c.print(f"[red]Profile has a problem: {err}[/]")
        raise
    return data


def import_resume(w: Wizard, pdf: Path, config: AppConfig) -> ResumeExtraction | None:
    try:
        text = resume_text(pdf)
    except Exception as e:  # noqa: BLE001 – pypdf raises many types
        w.c.print(f"  [yellow]Couldn't read the PDF ({e}); you'll type your details instead.[/]")
        return None
    if len(text) < 200:
        w.c.print("  [yellow]The PDF has little selectable text (scanned image?); you'll type your details instead.[/]")
        return None
    llm = LLMClient(config.llm)

    async def go() -> ResumeExtraction:
        await llm.ensure_ready()
        return await llm.extract_resume(text)

    try:
        with w.c.status("Reading your resume with the local AI model (about a minute)…"):
            result = asyncio.run(go())
    except LLMError as e:
        w.c.print(f"  [yellow]AI import unavailable: {e}[/]")
        return None
    w.c.print(f"  [green]✓ Found {len(result.work_history)} role(s), {len(result.education)} school(s), "
              f"{len(result.skills)} skill(s). Please check each value below.[/]")
    return result


def show_history(w: Wizard, roles: list[dict], education: list[dict]) -> None:
    if roles:
        t = Table(title="Work history", show_lines=False)
        for col in ("#", "Title", "Company", "From", "To"):
            t.add_column(col)
        for i, r in enumerate(roles, 1):
            t.add_row(str(i), r.get("title", ""), r.get("company", ""), r.get("start_date", ""), r.get("end_date", "") or "Present")
        w.c.print(t)
    if education:
        t = Table(title="Education")
        for col in ("#", "School", "Degree", "Field", "Graduated"):
            t.add_column(col)
        for i, ed in enumerate(education, 1):
            t.add_row(str(i), ed.get("school", ""), ed.get("degree", ""), ed.get("field_of_study", ""), ed.get("graduation_date", ""))
        w.c.print(t)


def edit_history(w: Wizard, roles: list[dict], education: list[dict]) -> tuple[list[dict], list[dict]]:
    w.c.print("  Enter your roles, most recent first. Leave the company blank to finish.")
    new_roles: list[dict] = []
    for i in range(10):
        prev = roles[i] if i < len(roles) else {}
        company = w.ask(f"Role {i + 1} – company", prev.get("company", ""))
        if not company:
            break
        new_roles.append({
            "company": company,
            "title": w.ask("  title", prev.get("title", ""), required=True),
            "location": w.ask("  location", prev.get("location", "")),
            "start_date": w.ask("  start (YYYY-MM)", prev.get("start_date", "")),
            "end_date": w.ask("  end (YYYY-MM or Present)", prev.get("end_date", "") or "Present"),
            "bullets": prev.get("bullets", []),
        })
    w.c.print("  Now education. Leave the school blank to finish.")
    new_edu: list[dict] = []
    for i in range(5):
        prev = education[i] if i < len(education) else {}
        school = w.ask(f"School {i + 1}", prev.get("school", ""))
        if not school:
            break
        new_edu.append({
            "school": school,
            "degree": w.ask("  degree (e.g. Bachelor of Science)", prev.get("degree", "")),
            "field_of_study": w.ask("  field of study", prev.get("field_of_study", "")),
            "start_date": prev.get("start_date", ""),
            "graduation_date": w.ask("  graduation (YYYY-MM)", prev.get("graduation_date", "")),
            "gpa": prev.get("gpa", ""),
        })
    return new_roles, new_edu


def search_flow(w: Wizard, config: AppConfig, profile: Profile | None) -> AppConfig:
    w.section("8. Jobs to search for")
    data = config.model_dump(mode="json")
    first = data["search_queries"][0] if data["search_queries"] else {}
    template_default = first.get("keywords") == "Software Engineer" and not data["filters"]["title_exclude"]
    prev_keywords = [q["keywords"] for q in data["search_queries"]] if not template_default else []
    suggestion = prev_keywords or ([profile.current_role.title] if profile and profile.current_role else [])
    keywords = _split_csv(w.ask("Job titles / keywords to search (comma separated: one search each)", _csv(suggestion), required=True))
    location = w.ask("Location", first.get("location") or (profile.personal.address.country if profile else "United States"))
    workplace = w.choose_many("Workplace types", WORKPLACE, first.get("workplace_type", ["Remote"]))
    levels = w.choose_many("Experience levels", LEVELS, first.get("experience_level", []))
    date_posted = w.choose("Posted within", DATES, first.get("date_posted", "past_week"))
    external = w.yes("Also apply on company sites (Greenhouse, Lever, Ashby, Workday, others)? "
                     "No = LinkedIn Easy Apply only", first.get("include_external", False))
    pages = IntPrompt.ask("  Result pages per search (25 jobs each)", default=first.get("max_pages", 3))
    data["search_queries"] = [
        {"keywords": k, "location": location, "workplace_type": workplace, "experience_level": levels,
         "date_posted": date_posted, "include_external": external, "max_pages": max(1, pages)}
        for k in keywords
    ]
    f = data["filters"]
    f["blacklist_companies"] = _split_csv(w.ask("Companies to never apply to (comma separated)", _csv(f["blacklist_companies"])))
    f["title_must_contain"] = _split_csv(w.ask("Titles must contain one of (blank = no rule)", _csv(f["title_must_contain"])))
    f["title_exclude"] = _split_csv(w.ask("Skip titles containing (e.g. Senior, Manager, Intern)", _csv(f["title_exclude"])))

    w.section("9. Pace & safety")
    lim = data["limits"]
    lim["max_applies_per_run"] = IntPrompt.ask("  Max applications per run", default=lim["max_applies_per_run"])
    data["dry_run"] = w.yes("Keep scheduled runs in dry-run mode (fill but never submit)? Recommended at first", data["dry_run"])
    model = data["llm"]["text_model"]
    if model == "qwen2.5:7b" and recommended_model() != model:
        model = recommended_model()
    data["llm"]["text_model"] = w.ask("Local AI model (16 GB Macs: qwen2.5:7b, 32 GB+: qwen2.5:14b)", model)
    if data["llm"]["text_model"] != config.llm.text_model:
        w.c.print(f"  [yellow]Make sure it's downloaded: ollama pull {data['llm']['text_model']}[/]")
    sch = data["schedule"]
    if w.yes("Change the daily schedule time (used only if you install the schedule)?", False):
        sch["hour"] = IntPrompt.ask("  Hour (0-23)", default=sch["hour"])
        sch["minute"] = IntPrompt.ask("  Minute (0-59)", default=sch["minute"])
        sch["weekdays_only"] = w.yes("Weekdays only?", sch["weekdays_only"])
    return AppConfig.model_validate(data)


def email_flow(w: Wizard, secrets: Secrets, profile: Profile | None) -> None:
    w.section("10. Email for verification codes",
              "Some sites (Greenhouse, Workday) email you a code or link while applying. The app can read it from your\n"
              "inbox (read-only search for those emails). Use the inbox that receives mail for your application email.")
    values: dict[str, str] = {}
    if w.yes("Set up email access now?", not secrets.imap_configured):
        default_user = secrets.imap_user if "@" in secrets.imap_user and "your_email" not in secrets.imap_user else (
            profile.personal.email if profile else "")
        user = w.ask("Email address", default_user, required=True)
        domain = user.split("@")[-1].lower()
        host = w.ask("IMAP server", IMAP_HOSTS.get(domain, secrets.imap_host))
        if "gmail" in host:
            w.c.print("  [dim]Gmail needs an App Password: turn on 2-Step Verification, then create one at\n"
                      "  https://myaccount.google.com/apppasswords (16 letters). Your normal password won't work.[/]")
        password = Prompt.ask("  App password (input hidden)", password=True).replace(" ", "")
        values |= {"IMAP_HOST": host, "IMAP_PORT": str(secrets.imap_port or 993), "IMAP_USER": user, "IMAP_APP_PASSWORD": password}
        test = Secrets(imap_host=host, imap_port=secrets.imap_port or 993, imap_user=user, imap_app_password=password)  # type: ignore[arg-type]
        try:
            with w.c.status("Testing the connection…"):
                n = asyncio.run(EmailVerifier(test).test_connection())
            w.c.print(f"  [green]✓ Connected ({n} unread).[/]")
        except Exception as e:  # noqa: BLE001
            w.c.print(f"  [red]✗ Login failed: {e}. Saved anyway – fix it later with setup → 'Email only'.[/]")

    current = secrets.ats_default_password.get_secret_value()
    if not current or current == "StrongPortalPassword123!":
        pw = generate_portal_password()
        values["ATS_DEFAULT_PASSWORD"] = pw
        w.c.print(Panel(
            f"Some company sites (e.g. Workday) require a candidate account. The app creates them with your\n"
            f"application email and this generated password:\n\n    [bold]{pw}[/]\n\n"
            f"It's stored in {w.paths.env_file}. Save it in your password manager if you'd like to sign in yourself.",
            title="Portal password", border_style="cyan",
        ))
    if values:
        write_env(w.paths.env_file, values)
        w.c.print(f"[green]✓ Saved secrets → {w.paths.env_file} (only you can read it)[/]")

