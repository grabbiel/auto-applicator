"""Local LLM client (OpenAI-compatible, e.g. Ollama) with strict Pydantic structured outputs."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Literal, Optional, TypeVar

import yaml
from openai import APIConnectionError, APIError, AsyncOpenAI
from pydantic import BaseModel, Field, ValidationError

from .config import LLMSettings, Profile

log = logging.getLogger(__name__)

T = TypeVar("T", bound=BaseModel)

FieldType = Literal[
    "text", "textarea", "number", "email", "tel", "url", "date",
    "select", "radio", "checkbox", "checkbox_group", "combobox", "file",
]  # fmt: skip

Confidence = Literal["high", "medium", "low"]


class LLMError(RuntimeError):
    pass


# --------------------------------------------------------------------------- schemas


class FieldSpec(BaseModel):
    """A form control as seen by the answer engine."""

    field_id: str
    label: str
    field_type: FieldType = "text"
    options: list[str] = Field(default_factory=list)
    required: bool = False
    current_value: str = ""
    placeholder: str = ""
    error: str = ""
    max_length: int | None = None


class FieldAnswer(BaseModel):
    field_id: str
    evidence: str = Field(description="Exact words from the profile/job that support the answer; empty if none.")
    answer: str
    confidence: Confidence


class FormStepResponse(BaseModel):
    answers: list[FieldAnswer]


class CoverLetterResponse(BaseModel):
    cover_letter: str


class EmailVerificationSchema(BaseModel):
    code: Optional[str] = None
    verification_url: Optional[str] = None


class SubmissionCheck(BaseModel):
    submitted: bool
    evidence: str


class SkillYears(BaseModel):
    skill: str
    years: float


class ResumeRole(BaseModel):
    company: str
    title: str
    location: str = ""
    start_date: str = ""
    end_date: str = ""
    bullets: list[str] = Field(default_factory=list)


class ResumeEducation(BaseModel):
    school: str
    degree: str = ""
    field_of_study: str = ""
    graduation_date: str = ""


class ResumeExtraction(BaseModel):
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None
    city: Optional[str] = None
    state: Optional[str] = None
    country: Optional[str] = None
    linkedin: Optional[str] = None
    github: Optional[str] = None
    portfolio: Optional[str] = None
    summary: Optional[str] = None
    total_years_experience: Optional[float] = None
    skills: list[str] = Field(default_factory=list)
    experience_years: list[SkillYears] = Field(default_factory=list)
    work_history: list[ResumeRole] = Field(default_factory=list)
    education: list[ResumeEducation] = Field(default_factory=list)
    certifications: list[str] = Field(default_factory=list)


class ResumeContact(BaseModel):
    full_name: str
    first_name: str
    last_name: str
    email: str
    phone: str
    city: str
    state: str
    country: str
    linkedin: str
    github: str
    portfolio: str


class ResumeJSON(BaseModel):
    """The shape the model fills in for a resume.

    Every field is a required plain value ("" or [] when absent): with all-optional fields, small local models
    under constrained decoding tend to answer null for everything instead of copying the facts.
    """

    contact: ResumeContact
    summary: str
    work_history: list[ResumeRole]
    education: list[ResumeEducation]
    skills: list[str]
    experience_years: list[SkillYears]
    total_years_experience: float
    certifications: list[str]

    def to_extraction(self) -> ResumeExtraction:
        c = self.contact
        first, last = c.first_name.strip(), c.last_name.strip()
        if not (first and last) and c.full_name.strip():
            parts = c.full_name.split()
            first, last = first or parts[0], last or " ".join(parts[1:])
        skills = [_SKILL_YEARS.sub("", s).strip() for s in self.skills]
        return ResumeExtraction(
            first_name=first or None, last_name=last or None,
            **{k: (getattr(c, k).strip() or None) for k in ("email", "phone", "city", "state", "country", "linkedin", "github", "portfolio")},
            summary=self.summary.strip() or None,
            total_years_experience=self.total_years_experience or None,
            skills=list(dict.fromkeys(s for s in skills if s)),
            experience_years=[sy for sy in self.experience_years if sy.skill.strip() and sy.years > 0],
            work_history=[r for r in self.work_history if r.company.strip() or r.title.strip()],
            education=[e for e in self.education if e.school.strip()],
            certifications=[x.strip() for x in self.certifications if x.strip()],
        )


_SKILL_YEARS = re.compile(r"\s*[(\[]\s*\d+(?:\.\d+)?\+?\s*(?:years?|yrs?)\s*[)\]]", re.I)


class JobContext(BaseModel):
    title: str = ""
    company: str = ""
    location: str = ""
    description: str = ""

    def as_prompt(self, max_chars: int = 2500) -> str:
        desc = re.sub(r"\s+", " ", self.description).strip()[:max_chars]
        return f"Title: {self.title}\nCompany: {self.company}\nLocation: {self.location}\nDescription: {desc}"


# --------------------------------------------------------------------------- prompts

FORM_SYSTEM_PROMPT = """You fill out job-application form fields on behalf of a candidate.

Rules:
1. Ground every answer strictly in the CANDIDATE PROFILE and the JOB below. Never invent employers, degrees,
   dates, certifications, links, numbers or experience the profile does not state.
2. Numeric fields (field_type "number", or questions like "how many years"): answer with digits only, e.g. "3".
3. Fields with an "options" list (select, radio, combobox, checkbox_group): the answer MUST be copied verbatim
   from that field's options. For checkbox_group, join several chosen options with " ; ".
4. Single checkbox: answer "Yes" to check it or "No" to leave it unchecked. Agree to truthful attestations
   (e.g. "I certify the information is accurate") with "Yes".
5. Work authorization, sponsorship, relocation, start date and similar questions come from the profile's
   work_authorization and preferences sections.
6. Free-text motivation or fit questions (textarea): write 2-4 sentences in first person, specific to the job,
   using only facts from the profile. Respect max_length.
7. evidence: first copy the exact words from the CANDIDATE PROFILE (or JOB) that the answer is based on, e.g.
   "requires_sponsorship: false" or "Python: 6". Use "" when nothing in the profile supports the answer.
8. confidence: "high" = the profile states it directly; "medium" = a safe, reasonable inference from the profile;
   "low" = the profile does not contain this information. Always "low" (with empty evidence) for facts the profile
   does not state, even if a guess seems obvious: criminal history, self-ratings ("rate your skill 1-10"), years
   with a skill missing from experience_years, references, salary history, licenses, test scores.
9. Return exactly one answer for every field_id you are given."""

COVER_LETTER_PROMPT = """Write a concise, specific cover letter (150-220 words, 3 short paragraphs, no placeholders,
no address block) for the candidate below and the job below. Use only facts from the profile. Sign with the
candidate's full name."""

EMAIL_PROMPT = """Extract the verification code and/or verification link from this email sent by a job portal.
Return code=null and verification_url=null when absent. The code is the short token the user must type
(often 6 digits or 8 letters/digits). The URL is the link that verifies/confirms the email or account."""

RESUME_PROMPT = """You read resumes and return their facts as JSON.
Copy names, companies, titles, schools and dates exactly as written. Use "" for text that isn't in the resume
and [] for empty lists. Dates as YYYY-MM when possible; "Present" for a current role.
work_history: every job listed, most recent first, with its bullet points.
skills: the skills, tools and languages the resume lists.
experience_years: for each main skill, the years of hands-on experience (stated, or estimated from the roles that use it).
total_years_experience: years since the first professional job."""


def profile_prompt_text(profile: Profile) -> str:
    data = profile.model_dump(mode="json", exclude={"files"})
    return yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=120)


_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$", re.M)


def _strip_fences(text: str) -> str:
    return _FENCE.sub("", text.strip()).strip()


# --------------------------------------------------------------------------- client


class LLMClient:
    def __init__(self, settings: LLMSettings, client: AsyncOpenAI | None = None):
        self.s = settings
        self.client = client or AsyncOpenAI(
            base_url=settings.base_url, api_key=settings.api_key, timeout=settings.request_timeout_sec, max_retries=1
        )

    @property
    def text_model(self) -> str:
        return self.s.effective_text_model

    async def structured(
        self,
        schema: type[T],
        messages: list[dict],
        *,
        model: str | None = None,
        retries: int = 2,
        max_tokens: int | None = None,
    ) -> T:
        response_format = {
            "type": "json_schema",
            "json_schema": {"name": schema.__name__, "schema": schema.model_json_schema(), "strict": True},
        }
        msgs = list(messages)
        last_err: Exception | None = None
        for _ in range(retries + 1):
            try:
                resp = await self.client.chat.completions.create(
                    model=model or self.text_model,
                    messages=msgs,
                    temperature=self.s.temperature,
                    response_format=response_format,
                    **({"max_tokens": max_tokens} if max_tokens else {}),
                )
            except APIConnectionError as e:
                raise LLMError(f"Cannot reach the local model server at {self.s.base_url} ({e}).") from e
            except APIError as e:
                raise LLMError(f"Model server error: {e}") from e
            content = (resp.choices[0].message.content or "") if resp.choices else ""
            try:
                return schema.model_validate_json(_strip_fences(content))
            except ValidationError as e:
                last_err = e
                errors = "; ".join(f"{'.'.join(map(str, x['loc']))}: {x['msg']}" for x in e.errors()[:4])
                msgs = msgs + [
                    {"role": "assistant", "content": content[:4000]},
                    {"role": "user", "content": f"That JSON did not match the schema ({errors}). Return corrected JSON only."},
                ]
        raise LLMError(f"Model did not return valid {schema.__name__}: {last_err}")

    # ---------------------------------------------------------------- tasks

    async def answer_fields(
        self,
        fields: list[FieldSpec],
        profile_text: str,
        job: JobContext,
        feedback: dict[str, str] | None = None,
    ) -> FormStepResponse:
        payload = [f.model_dump(exclude_defaults=True, exclude={"current_value"}) for f in fields]
        for p, f in zip(payload, fields, strict=True):
            p.setdefault("field_type", f.field_type)
        user = (
            f"CANDIDATE PROFILE (YAML):\n{profile_text}\n\nJOB:\n{job.as_prompt()}\n\n"
            f"Today's date: {time.strftime('%Y-%m-%d')}\n\nFIELDS:\n{json.dumps(payload, ensure_ascii=False)}"
        )
        if feedback:
            lines = "\n".join(f"- {fid}: {msg}" for fid, msg in feedback.items())
            user += f"\n\nThe form rejected the previous answers with these validation errors – fix them:\n{lines}"
        return await self.structured(
            FormStepResponse,
            [{"role": "system", "content": FORM_SYSTEM_PROMPT}, {"role": "user", "content": user}],
        )

    async def cover_letter(self, profile_text: str, job: JobContext) -> str:
        resp = await self.structured(
            CoverLetterResponse,
            [
                {"role": "system", "content": COVER_LETTER_PROMPT},
                {"role": "user", "content": f"CANDIDATE PROFILE:\n{profile_text}\n\nJOB:\n{job.as_prompt(3500)}"},
            ],
        )
        return resp.cover_letter.strip()

    async def extract_verification(self, email_text: str) -> EmailVerificationSchema:
        return await self.structured(
            EmailVerificationSchema,
            [{"role": "system", "content": EMAIL_PROMPT}, {"role": "user", "content": email_text[:6000]}],
        )

    async def extract_resume(self, resume_text: str) -> ResumeExtraction:
        raw = await self.structured(
            ResumeJSON,
            [{"role": "system", "content": RESUME_PROMPT}, {"role": "user", "content": "Resume:\n\n" + resume_text[:14000]}],
            retries=1,
        )
        return raw.to_extraction()

    async def check_submission(self, page_text: str) -> SubmissionCheck:
        prompt = (
            "Below is the visible text of a web page shown right after a job application form was submitted. "
            "Decide whether the application was successfully submitted (a thank-you / confirmation message) "
            "or not (validation errors, the form is still shown, an error page)."
        )
        return await self.structured(
            SubmissionCheck,
            [{"role": "system", "content": prompt}, {"role": "user", "content": page_text[:5000]}],
        )

    # ---------------------------------------------------------------- server management

    async def list_models(self) -> list[str]:
        try:
            page = await self.client.models.list()
        except (APIConnectionError, APIError) as e:
            raise LLMError(f"Cannot reach the local model server at {self.s.base_url}.") from e
        return [m.id for m in page.data]

    async def ensure_ready(self) -> None:
        """Make sure the server is up and the models exist (starting Ollama / creating the ctx variant if needed)."""
        try:
            models = await self.list_models()
        except LLMError:
            if not (self.s.is_local_ollama and await asyncio.to_thread(start_ollama)):
                raise LLMError(
                    "The local AI server (Ollama) is not running. Open the Ollama app or run `ollama serve`."
                ) from None
            models = await self.list_models()

        def has(name: str) -> bool:
            return name in models or (":" not in name and f"{name}:latest" in models)

        if not has(self.s.text_model):
            raise LLMError(f"Model '{self.s.text_model}' is not installed. Run: ollama pull {self.s.text_model}")
        if self.text_model != self.s.text_model and not has(self.text_model):
            await asyncio.to_thread(create_ctx_variant, self.s.text_model, self.text_model, self.s.num_ctx or 8192)


def ollama_binary() -> str | None:
    from .installer import bundled_ollama

    found = shutil.which("ollama")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"):
        if Path(candidate).exists():
            return candidate
    bundled = bundled_ollama()  # downloaded by the app when Ollama wasn't installed
    return str(bundled) if bundled else None


def start_ollama(wait_sec: float = 25.0) -> bool:
    """Start Ollama in the background (app if installed, else `ollama serve`). Returns True once it answers."""
    import urllib.request

    if Path("/Applications/Ollama.app").exists():
        subprocess.run(["open", "-ga", "Ollama"], check=False)
    else:
        binary = ollama_binary()
        if not binary:
            return False
        # Flash attention + 8-bit KV cache roughly halve the context's memory use (matters on 16 GB Macs).
        env = {"OLLAMA_FLASH_ATTENTION": "1", "OLLAMA_KV_CACHE_TYPE": "q8_0", **os.environ}
        subprocess.Popen(
            [binary, "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, env=env
        )
    deadline = time.monotonic() + wait_sec
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen("http://127.0.0.1:11434/api/version", timeout=2):
                return True
        except OSError:
            time.sleep(1)
    return False


def create_ctx_variant(base: str, variant: str, num_ctx: int) -> None:
    """Create an Ollama model alias with a bigger context window (shares weights; no extra download)."""
    binary = ollama_binary()
    if not binary:
        raise LLMError("The `ollama` command was not found; cannot create the model variant.")
    log.info("Creating Ollama model %s (num_ctx=%s) from %s", variant, num_ctx, base)
    with tempfile.NamedTemporaryFile("w", suffix=".Modelfile", delete=False) as f:
        f.write(f"FROM {base}\nPARAMETER num_ctx {num_ctx}\nPARAMETER temperature 0\n")
        modelfile = f.name
    try:
        proc = subprocess.run([binary, "create", variant, "-f", modelfile], capture_output=True, text=True)
    finally:
        Path(modelfile).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise LLMError(f"ollama create failed: {proc.stderr.strip() or proc.stdout.strip()}")
