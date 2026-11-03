"""Configuration loading for config.yaml, profile.yaml and .env.

Personal files live in a per-user settings folder, not in the app folder, so the app can be zipped
and shared without leaking credentials, LinkedIn cookies or the candidate profile:

    ~/Library/Application Support/AutoApplicator/   (override with the AA_HOME environment variable)
        config.yaml  profile.yaml  .env  files/  data/{jobs.db,chrome_profile/}  logs/screenshots/
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, SecretStr, ValidationError, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

APP_NAME = "AutoApplicator"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONFIG_TEMPLATE = PROJECT_ROOT / "config.yaml"
PROFILE_TEMPLATE = PROJECT_ROOT / "profile.example.yaml"
ENV_TEMPLATE = PROJECT_ROOT / ".env.example"

DECLINE = "Decline to self-identify"


class ConfigError(RuntimeError):
    """A user-facing configuration problem (missing file, invalid value)."""


def default_home() -> Path:
    env = os.environ.get("AA_HOME")
    if env:
        return Path(env).expanduser().resolve()
    return Path.home() / "Library" / "Application Support" / APP_NAME


@dataclass(frozen=True)
class Paths:
    home: Path

    @classmethod
    def default(cls) -> Paths:
        return cls(default_home())

    @property
    def config_file(self) -> Path:
        return self.home / "config.yaml"

    @property
    def profile_file(self) -> Path:
        return self.home / "profile.yaml"

    @property
    def env_file(self) -> Path:
        return self.home / ".env"

    @property
    def files_dir(self) -> Path:
        return self.home / "files"

    @property
    def data_dir(self) -> Path:
        return self.home / "data"

    @property
    def db_file(self) -> Path:
        return self.data_dir / "jobs.db"

    @property
    def chrome_profile(self) -> Path:
        return self.data_dir / "chrome_profile"

    @property
    def logs_dir(self) -> Path:
        return self.home / "logs"

    @property
    def screenshots_dir(self) -> Path:
        return self.logs_dir / "screenshots"

    @property
    def cover_letters_dir(self) -> Path:
        return self.logs_dir / "cover_letters"

    def ensure(self) -> Paths:
        for d in (self.home, self.files_dir, self.data_dir, self.logs_dir, self.screenshots_dir, self.cover_letters_dir):
            d.mkdir(parents=True, exist_ok=True)
        os.chmod(self.home, 0o700)
        return self

    def resolve_user_path(self, value: str | Path) -> Path:
        p = Path(value).expanduser()
        return p if p.is_absolute() else (self.home / p)


# --------------------------------------------------------------------------- config.yaml


def _as_list(v: Any) -> Any:
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    return v


WorkplaceType = Literal["Remote", "Hybrid", "On-site"]
ExperienceLevel = Literal["Internship", "Entry level", "Associate", "Mid-Senior level", "Director", "Executive"]
DatePosted = Literal["any", "past_month", "past_week", "past_24h"]


class SearchQuery(BaseModel):
    model_config = ConfigDict(extra="forbid")

    keywords: str
    location: str = "United States"
    workplace_type: list[WorkplaceType] = Field(default_factory=list)
    experience_level: list[ExperienceLevel] = Field(default_factory=list)
    date_posted: DatePosted = "past_week"
    include_external: bool = False
    max_pages: int = Field(default=3, ge=1, le=40)

    _lists = field_validator("workplace_type", "experience_level", mode="before")(_as_list)


class Filters(BaseModel):
    model_config = ConfigDict(extra="forbid")

    blacklist_companies: list[str] = Field(default_factory=list)
    title_must_contain: list[str] = Field(default_factory=list)
    title_exclude: list[str] = Field(default_factory=list)

    _lists = field_validator("blacklist_companies", "title_must_contain", "title_exclude", mode="before")(_as_list)


class Limits(BaseModel):
    model_config = ConfigDict(extra="forbid")

    max_applies_per_run: int = Field(default=20, ge=1)
    min_delay_sec: float = Field(default=3.0, ge=0)
    max_delay_sec: float = Field(default=7.0, ge=0)
    otp_timeout_sec: int = Field(default=90, ge=10)
    max_form_steps: int = Field(default=12, ge=1)
    max_attempts_per_job: int = Field(default=2, ge=1)

    @field_validator("max_delay_sec")
    @classmethod
    def _delay_order(cls, v: float, info: Any) -> float:
        lo = info.data.get("min_delay_sec", 0)
        return max(v, lo)


class LLMSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")

    base_url: str = "http://localhost:11434/v1"
    api_key: str = "ollama"
    text_model: str = "qwen2.5:7b"
    temperature: float = 0.0
    num_ctx: int | None = 8192
    request_timeout_sec: int = 180

    @property
    def is_local_ollama(self) -> bool:
        return ":11434" in self.base_url

    @property
    def effective_text_model(self) -> str:
        """Ollama model name actually used: a variant with a larger context window when num_ctx is set."""
        if not (self.num_ctx and self.is_local_ollama):
            return self.text_model
        name, _, tag = self.text_model.partition(":")
        return f"{name}:{tag or 'latest'}-ctx{self.num_ctx}"


class BrowserSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")

    channel: Literal["chromium", "chrome"] = "chromium"
    viewport_width: int = 1440
    viewport_height: int = 900


class Schedule(BaseModel):
    model_config = ConfigDict(extra="forbid")

    hour: int = Field(default=9, ge=0, le=23)
    minute: int = Field(default=30, ge=0, le=59)
    weekdays_only: bool = True


class AppConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    search_queries: list[SearchQuery] = Field(default_factory=list)
    filters: Filters = Field(default_factory=Filters)
    limits: Limits = Field(default_factory=Limits)
    dry_run: bool = True
    llm: LLMSettings = Field(default_factory=LLMSettings)
    browser: BrowserSettings = Field(default_factory=BrowserSettings)
    schedule: Schedule = Field(default_factory=Schedule)


# --------------------------------------------------------------------------- profile.yaml


class Address(BaseModel):
    street: str = ""
    city: str = ""
    state: str = ""
    postal_code: str = ""
    country: str = "United States"


class Personal(BaseModel):
    first_name: str
    last_name: str
    preferred_name: str = ""
    email: str
    phone: str
    phone_country_code: str = "+1"
    address: Address = Field(default_factory=Address)
    location: str = ""
    linkedin: str = ""
    github: str = ""
    portfolio: str = ""

    @property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}".strip()


class WorkAuthorization(BaseModel):
    authorized_to_work_us: bool = True
    requires_sponsorship: bool = False
    visa_status: str = ""
    citizenship: str = ""
    security_clearance: str = "None"


class Compensation(BaseModel):
    desired_base: int | None = None
    range_min: int | None = None
    range_max: int | None = None
    currency: str = "USD"


class Preferences(BaseModel):
    willing_to_relocate: bool = False
    open_to_remote: bool = True
    open_to_hybrid: bool = True
    open_to_onsite: bool = True
    notice_period: str = "2 weeks"
    earliest_start_date: str = "2 weeks after offer"
    over_18: bool = True
    how_did_you_hear: str = "LinkedIn"


class Role(BaseModel):
    company: str
    title: str
    location: str = ""
    start_date: str = ""
    end_date: str = "Present"
    bullets: list[str] = Field(default_factory=list)

    @property
    def is_current(self) -> bool:
        return self.end_date.strip().lower() in ("", "present", "current", "now")


class Education(BaseModel):
    school: str
    degree: str = ""
    field_of_study: str = ""
    start_date: str = ""
    graduation_date: str = ""
    gpa: str = ""


class EEO(BaseModel):
    gender: str = DECLINE
    hispanic_or_latino: str = DECLINE
    ethnicity: str = DECLINE
    veteran_status: str = DECLINE
    disability_status: str = DECLINE
    sexual_orientation: str = DECLINE
    pronouns: str = ""


class Files(BaseModel):
    resume_pdf: str
    cover_letter_pdf: str | None = None


class Profile(BaseModel):
    personal: Personal
    work_authorization: WorkAuthorization = Field(default_factory=WorkAuthorization)
    compensation: Compensation = Field(default_factory=Compensation)
    preferences: Preferences = Field(default_factory=Preferences)
    summary: str = ""
    skills: list[str] = Field(default_factory=list)
    experience_years: dict[str, float] = Field(default_factory=dict)
    work_history: list[Role] = Field(default_factory=list)
    education: list[Education] = Field(default_factory=list)
    certifications: list[str] = Field(default_factory=list)
    languages: list[str] = Field(default_factory=list)
    eeo: EEO = Field(default_factory=EEO)
    extra_answers: dict[str, str] = Field(default_factory=dict)
    files: Files

    @field_validator("education", "work_history", mode="before")
    @classmethod
    def _single_to_list(cls, v: Any) -> Any:
        return [v] if isinstance(v, dict) else _as_list(v)

    @property
    def current_role(self) -> Role | None:
        for r in self.work_history:
            if r.is_current:
                return r
        return self.work_history[0] if self.work_history else None

    @property
    def total_years(self) -> float | None:
        for key in ("total", "overall", "professional"):
            if key in self.experience_years:
                return self.experience_years[key]
        return max(self.experience_years.values()) if self.experience_years else None


# --------------------------------------------------------------------------- .env


class Secrets(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", env_file_encoding="utf-8")

    imap_host: str = "imap.gmail.com"
    imap_port: int = 993
    imap_user: str = ""
    imap_app_password: SecretStr = SecretStr("")
    ats_default_password: SecretStr = SecretStr("")

    @property
    def imap_configured(self) -> bool:
        pw = self.imap_app_password.get_secret_value()
        return bool(self.imap_user and pw and "your_" not in pw and "@" in self.imap_user)


# --------------------------------------------------------------------------- loading


@dataclass
class Settings:
    paths: Paths
    config: AppConfig
    profile: Profile | None
    secrets: Secrets

    def require_profile(self) -> Profile:
        if self.profile is None:
            raise ConfigError(
                f"No profile found at {self.paths.profile_file}. Open Auto Applicator and finish setting up first."
            )
        return self.profile

    @property
    def resume_path(self) -> Path:
        return self.paths.resolve_user_path(self.require_profile().files.resume_pdf)

    @property
    def cover_letter_path(self) -> Path | None:
        cl = self.require_profile().files.cover_letter_pdf
        return self.paths.resolve_user_path(cl) if cl else None


def read_yaml(path: Path) -> dict[str, Any]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as e:
        raise ConfigError(f"{path.name} is not valid YAML: {e}") from e
    if not isinstance(data, dict):
        raise ConfigError(f"{path.name} must contain a YAML mapping at the top level.")
    return data


def write_yaml(path: Path, data: dict[str, Any], header: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=110)
    path.write_text((header + "\n" if header else "") + body, encoding="utf-8")


def _format_validation(name: str, err: ValidationError) -> str:
    lines = [f"{name} has invalid values:"]
    for e in err.errors()[:8]:
        loc = ".".join(str(p) for p in e["loc"])
        lines.append(f"  - {loc}: {e['msg']}")
    return "\n".join(lines)


def load_config(path: Path) -> AppConfig:
    source = path if path.exists() else CONFIG_TEMPLATE
    try:
        return AppConfig.model_validate(read_yaml(source))
    except ValidationError as e:
        raise ConfigError(_format_validation(source.name, e)) from e


def load_profile(path: Path) -> Profile | None:
    if not path.exists():
        return None
    try:
        return Profile.model_validate(read_yaml(path))
    except ValidationError as e:
        raise ConfigError(_format_validation(path.name, e)) from e


def load_secrets(path: Path) -> Secrets:
    return Secrets(_env_file=path if path.exists() else None)  # type: ignore[call-arg]


def load_settings(home: Path | None = None) -> Settings:
    paths = Paths(home) if home else Paths.default()
    paths.ensure()
    if not paths.config_file.exists():
        shutil.copyfile(CONFIG_TEMPLATE, paths.config_file)
    return Settings(
        paths=paths,
        config=load_config(paths.config_file),
        profile=load_profile(paths.profile_file),
        secrets=load_secrets(paths.env_file),
    )


def write_env(path: Path, values: dict[str, str]) -> None:
    """Write/merge KEY=VALUE pairs into a .env file with 600 permissions."""
    existing: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, _, v = line.partition("=")
                existing[k.strip()] = v.strip()
    existing.update({k: v for k, v in values.items() if v is not None})
    lines = ["# Auto Applicator secrets – do not share this file."]
    lines += [f"{k}={_quote_env(v)}" for k, v in existing.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def _quote_env(v: str) -> str:
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v  # already quoted (value read back from an existing file)
    if not any(c in v for c in " #'\"$`\\="):
        return v
    if "'" not in v:
        return f"'{v}'"  # single quotes: literal, no escapes or ${} expansion
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
