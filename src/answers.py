"""Answer resolution for form fields: QA cache -> deterministic profile rules -> local LLM.

Policy: an answer the LLM marks "low" confidence is never submitted. If such a field is required, the
application is abandoned (SKIPPED_NEEDS_ANSWER) and the question is saved for the user to answer once.
"""

from __future__ import annotations

import difflib
import logging
import re
from collections.abc import Callable
from dataclasses import dataclass, field

from .config import DECLINE, Profile
from .db import Database, normalize_question, question_hash
from .llm import FieldSpec, JobContext, LLMClient, LLMError, profile_prompt_text

log = logging.getLogger(__name__)

OPTION_TYPES = {"select", "radio", "combobox", "checkbox_group"}
DECLINE_MARKERS = (
    "decline", "prefer not", "not wish", "don't wish", "do not wish", "not to answer", "not to disclose",
    "choose not", "rather not", "not specified", "i don't want", "i do not want",
)  # fmt: skip
_NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?")


def norm(text: str) -> str:
    return normalize_question(text).replace("’", "'")


_PLACEHOLDER = re.compile(r"^(-+\s*)?((please )?(select|choose|pick)\b.*|none selected|-+|\.\.\.)?(\s*-+)?$")


def is_placeholder_option(opt: str) -> bool:
    return bool(_PLACEHOLDER.fullmatch(norm(opt)))


def match_option(answer: str, options: list[str]) -> str | None:
    """Map a free answer onto one of the options (verbatim), or None."""
    opts = [o for o in options if not is_placeholder_option(o)]
    if not opts or not answer.strip():
        return None
    if answer in opts:
        return answer
    a = norm(answer)
    by_norm = {norm(o): o for o in opts}
    if a in by_norm:
        return by_norm[a]
    # Yes/No style: "Yes" -> "Yes, I am authorized to work..."
    first = a.split(" ")[0].strip(",.")
    if first in ("yes", "no"):
        hits = [o for o in opts if norm(o).split(" ")[0].strip(",.") == first]
        if len(hits) == 1:
            return hits[0]
    if any(m in a for m in DECLINE_MARKERS):
        hits = [o for o in opts if any(m in norm(o) for m in DECLINE_MARKERS)]
        if hits:
            return hits[0]
    close = difflib.get_close_matches(a, list(by_norm), n=1, cutoff=0.85)
    if close:
        return by_norm[close[0]]
    contains = [o for n, o in by_norm.items() if len(a) >= 3 and (a in n or n in a)]
    if len(contains) == 1:
        return contains[0]
    return None


_RANGE = re.compile(r"(\d+(?:\.\d+)?)\s*(?:-|–|to)\s*(\d+(?:\.\d+)?)")
_PLUS = re.compile(r"(\d+(?:\.\d+)?)\s*\+|(?:more than|over|at least)\s*(\d+(?:\.\d+)?)")
_LESS = re.compile(r"(?:less than|under|fewer than|<)\s*(\d+(?:\.\d+)?)")


def match_numeric_range(answer: str, options: list[str]) -> str | None:
    """'6' -> '5+ years' / '5-7 years'; only when the answer is a bare number."""
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(years?)?\s*", answer.lower())
    if not m:
        return None
    v = float(m.group(1))
    for opt in options:
        o = opt.lower().replace(",", "")
        if (r := _RANGE.search(o)) and float(r.group(1)) <= v <= float(r.group(2)):
            return opt
        if (lt := _LESS.search(o)) and v < float(lt.group(1)):
            return opt
        if (pl := _PLUS.search(o)) and v >= float(pl.group(1) or pl.group(2)):
            return opt
    exact = [o for o in options if re.fullmatch(rf"\s*{re.escape(m.group(1))}\s*(years?)?\s*", o.lower())]
    return exact[0] if exact else None


def coerce_answer(f: FieldSpec, answer: str | None) -> str | None:
    """Validate/normalize an answer for a field. None means unusable."""
    if answer is None:
        return None
    answer = str(answer).strip()
    if not answer:
        return None
    t = f.field_type
    if t == "checkbox_group" and f.options:
        parts = [match_option(p, f.options) for p in re.split(r"\s*;\s*", answer) if p.strip()]
        parts = [p for p in parts if p]
        return " ; ".join(dict.fromkeys(parts)) or None
    if t in OPTION_TYPES and f.options:
        return match_option(answer, f.options) or match_numeric_range(answer, f.options)
    if t == "number":
        m = _NUM.search(answer)
        return m.group(0).replace(",", "") if m else None
    if t == "checkbox":
        a = norm(answer)
        if a in ("yes", "true", "checked", "agree", "i agree", "1", "on"):
            return "Yes"
        if a in ("no", "false", "unchecked", "0", "off"):
            return "No"
        return None
    if t == "email" and "@" not in answer:
        return None
    if f.max_length and len(answer) > f.max_length:
        answer = answer[: f.max_length].rsplit(" ", 1)[0]
    return answer


# --------------------------------------------------------------------------- deterministic rules


def _yn(value: bool) -> str:
    return "Yes" if value else "No"


def _years_for(profile: Profile, label: str) -> str | None:
    n = norm(label)
    best: tuple[int, float] | None = None
    for skill, years in profile.experience_years.items():
        key = norm(skill)
        if key in ("total", "overall", "professional"):
            continue
        if re.search(rf"(?<![a-z0-9]){re.escape(key)}(?![a-z0-9])", n):
            if best is None or len(key) > best[0]:
                best = (len(key), years)
    if best is not None:
        return str(round(best[1]))
    # Only a question about overall experience (no specific skill named) gets the total.
    generic = re.fullmatch(
        r"(how many |total )?(years of )?(total |professional |work |relevant |industry |overall )?(work )?"
        r"(years of )?experience( do you have)?( in total)?( \(years\))?",
        n,
    )
    if generic and "years" in n and profile.total_years is not None:
        return str(round(profile.total_years))
    return None


def _is_us_citizen(p: Profile) -> bool:
    status = f"{p.work_authorization.visa_status} {p.work_authorization.citizenship}".lower()
    return ("citizen" in status and "non" not in status) or "united states" in p.work_authorization.citizenship.lower()


def _eeo(value: str) -> str:
    return value or DECLINE


Rule = tuple[re.Pattern[str], Callable[[Profile, FieldSpec], str | None]]


def _rules() -> list[Rule]:
    def r(pattern: str, fn: Callable[[Profile, FieldSpec], str | None]) -> Rule:
        return (re.compile(pattern), fn)

    def edu(p: Profile) -> object | None:
        return p.education[0] if p.education else None

    return [
        # Order matters: more specific patterns first.
        r(r"phone (device )?type|type of phone", lambda p, f: "Mobile"),
        r(r"country (phone )?code|phone (country )?code|dialing code", lambda p, f: p.personal.phone_country_code),
        r(r"\bpreferred (first )?name\b|\bnickname\b", lambda p, f: p.personal.preferred_name or p.personal.first_name),
        r(r"\bfirst name\b|\bgiven name\b", lambda p, f: p.personal.first_name),
        r(r"\blast name\b|\bfamily name\b|\bsurname\b", lambda p, f: p.personal.last_name),
        r(r"^(your )?(full |legal |full legal )?name$|^candidate name$", lambda p, f: p.personal.full_name),
        r(r"e-?mail", lambda p, f: p.personal.email),
        r(r"\b(phone|mobile|cell)( number)?\b", lambda p, f: p.personal.phone),
        r(r"linkedin", lambda p, f: p.personal.linkedin or None),
        r(r"github", lambda p, f: p.personal.github or None),
        r(r"portfolio|personal (web)?site|^website$|^other website", lambda p, f: p.personal.portfolio or p.personal.github or None),
        r(r"(street|address line 1|^address$|mailing address)", lambda p, f: p.personal.address.street or None),
        r(r"^city$|\bcity\b(?!.*(willing|relocat))", lambda p, f: p.personal.address.city or None),
        r(r"^state$|state/province|^province$|state or province", lambda p, f: p.personal.address.state or None),
        r(r"zip|postal", lambda p, f: p.personal.address.postal_code or None),
        r(r"^country$|country of residence|country/region", lambda p, f: p.personal.address.country or None),
        r(r"^(current )?location$|where are you (currently )?(located|based)|^location \(city\)", lambda p, f: p.personal.location or None),
        r(r"(legally )?authori[sz]ed to work|eligible to work|right to work|work authori[sz]ation",
          lambda p, f: _yn(p.work_authorization.authorized_to_work_us)),
        r(r"sponsor", lambda p, f: _yn(p.work_authorization.requires_sponsorship)),
        r(r"are you (a )?(u\.?s\.?|united states) citizen", lambda p, f: _yn(_is_us_citizen(p))),
        r(r"security clearance|active clearance", lambda p, f: p.work_authorization.security_clearance or None),
        r(r"relocat", lambda p, f: _yn(p.preferences.willing_to_relocate)),
        r(r"notice period", lambda p, f: p.preferences.notice_period or None),
        r(r"earliest.*start|when can you start|available to start|availability to start|desired start date", lambda p, f: p.preferences.earliest_start_date or None),
        r(r"(18|eighteen) years|at least 18|over the age of", lambda p, f: _yn(p.preferences.over_18)),
        r(r"how did you (hear|find|learn)|where did you (hear|find|see|learn)|referral source|^source$",
          lambda p, f: p.preferences.how_did_you_hear or None),
        r(r"(desired|expected|target) (salary|compensation|pay)|salary expectation|compensation expectation|^salary$",
          lambda p, f: str(p.compensation.desired_base) if p.compensation.desired_base else None),
        r(r"(current|most recent) (company|employer)|^company$|^employer$", lambda p, f: p.current_role.company if p.current_role else None),
        r(r"(current|most recent) (job )?(title|position|role)", lambda p, f: p.current_role.title if p.current_role else None),
        r(r"^(school|university|college|institution)( name)?$", lambda p, f: edu(p).school if edu(p) else None),  # type: ignore[union-attr]
        r(r"field of study|^major$|discipline", lambda p, f: edu(p).field_of_study if edu(p) else None),  # type: ignore[union-attr]
        r(r"\bgender\b", lambda p, f: _eeo(p.eeo.gender)),
        r(r"hispanic|latino", lambda p, f: _eeo(p.eeo.hispanic_or_latino)),
        r(r"\brace\b|ethnicit", lambda p, f: _eeo(p.eeo.ethnicity)),
        r(r"veteran", lambda p, f: _eeo(p.eeo.veteran_status)),
        r(r"disabilit", lambda p, f: _eeo(p.eeo.disability_status)),
        r(r"sexual orientation", lambda p, f: _eeo(p.eeo.sexual_orientation)),
        r(r"pronoun", lambda p, f: p.eeo.pronouns or None),
        r(r"years|how many|how long", lambda p, f: _years_for(p, f.label) if f.field_type != "textarea" else None),
    ]


RULES = _rules()


def rule_answer(profile: Profile, f: FieldSpec) -> str | None:
    label = norm(f.label)
    if not label:
        return None
    # Exact/near-exact match against the user's own extra answers first.
    if profile.extra_answers:
        keys = {norm(k): v for k, v in profile.extra_answers.items()}
        if label in keys:
            return keys[label]
        close = difflib.get_close_matches(label, list(keys), n=1, cutoff=0.9)
        if close:
            return keys[close[0]]
    for pattern, fn in RULES:
        if pattern.search(label):
            try:
                value = fn(profile, f)
            except (AttributeError, IndexError):
                value = None
            if value:
                return value
            # A matching rule that has no data stops here: don't let a broader rule answer it.
            return None
    return None


# --------------------------------------------------------------------------- grounding checks

_STOP = {"the", "and", "for", "with", "you", "your", "are", "this", "that", "from", "have", "has", "not", "yes", "profile",
         "candidate", "job", "none", "true", "false", "years", "year"}
_YEARS_Q = re.compile(r"\byears?\b|how (many|long)")


def _tokens(text: str) -> set[str]:
    return {t for t in re.findall(r"[a-z0-9+#]+", text.lower()) if len(t) > 2 and t not in _STOP}


def is_grounded(f: FieldSpec, answer: str, evidence: str, corpus: set[str]) -> bool:
    """The LLM must cite words that really occur in the profile/job; numbers must come from that citation."""
    ev = _tokens(evidence)
    if not ev or len(ev & corpus) / len(ev) < 0.6:
        return False
    if f.field_type == "number" and not re.search(rf"(?<![\d.]){re.escape(answer)}(?![\d])", evidence):
        return False
    return True


# Questions the model must never answer on its own: they need the user's own word (answer once, then cached).
NEVER_GUESS = re.compile(
    r"\brate (your|yourself)|on a scale|scale of|\b1 ?(-|to) ?(5|10)\b|proficiency level|"
    r"convicted|felony|criminal|misdemeanor|background check|drug (test|screen)|"
    r"current (salary|compensation|base)|salary history|previous salary|"
    r"references?\b|referred by|employee referral|"
    r"non-?compete|been terminated|fired from|disciplinary"
)


def asks_years_of_skill(f: FieldSpec) -> bool:
    return f.field_type != "textarea" and bool(_YEARS_Q.search(norm(f.label))) and "experience" in norm(f.label) + " experience"


# --------------------------------------------------------------------------- resolver


@dataclass
class Resolution:
    answers: dict[str, str] = field(default_factory=dict)
    unresolved: list[FieldSpec] = field(default_factory=list)  # required, no confident answer
    left_blank: list[FieldSpec] = field(default_factory=list)  # optional, no confident answer
    sources: dict[str, str] = field(default_factory=dict)

    @property
    def blocked(self) -> bool:
        return bool(self.unresolved)


class Answerer:
    def __init__(self, profile: Profile, db: Database, llm: LLMClient, *, batch_size: int = 8):
        self.profile = profile
        self.db = db
        self.llm = llm
        self.batch_size = batch_size
        self.profile_text = profile_prompt_text(profile)
        self._profile_tokens = _tokens(self.profile_text)

    def _cacheable(self, f: FieldSpec, job: JobContext) -> bool:
        if f.field_type in ("textarea", "file"):
            return False
        label = norm(f.label)
        return not (job.company and norm(job.company) in label)

    async def resolve(
        self, fields: list[FieldSpec], job: JobContext, feedback: dict[str, str] | None = None
    ) -> Resolution:
        res = Resolution()
        feedback = feedback or {}
        todo: list[FieldSpec] = []
        for f in fields:
            if f.field_type == "file":
                continue
            fb = feedback.get(f.field_id)
            if not fb and f.current_value and not f.error:
                continue  # already filled (e.g. pre-populated by LinkedIn or a resume parser)
            qh = question_hash(f.label, f.field_type, f.options)
            if fb and f.current_value:
                # The form rejected the value we entered: forget it and ask the LLM with the error message.
                if self.db.cache_source(qh) not in (None, "user"):
                    self.db.cache_delete(qh)
                todo.append(f)
                continue
            cached = coerce_answer(f, self.db.cache_get(qh))
            if cached is not None:
                res.answers[f.field_id], res.sources[f.field_id] = cached, "cache"
                continue
            ruled = coerce_answer(f, rule_answer(self.profile, f))
            if ruled is not None:
                res.answers[f.field_id], res.sources[f.field_id] = ruled, "profile"
                continue
            if NEVER_GUESS.search(norm(f.label)):
                (res.unresolved if f.required else res.left_blank).append(f)
                continue
            if f.field_type in ("number", "text", "select", "radio", "combobox") and asks_years_of_skill(f) \
                    and re.search(r"\b(with|in|using|of)\b", norm(f.label)):
                # "Years of X" with X missing from experience_years: never let the model guess a number.
                (res.unresolved if f.required else res.left_blank).append(f)
                continue
            todo.append(f)

        for i in range(0, len(todo), self.batch_size):
            batch = todo[i : i + self.batch_size]
            try:
                resp = await self.llm.answer_fields(
                    batch, self.profile_text, job, {k: v for k, v in feedback.items() if any(b.field_id == k for b in batch)}
                )
                by_id = {a.field_id: a for a in resp.answers}
            except LLMError as e:
                log.warning("LLM failed on a batch of %d fields: %s", len(batch), e)
                by_id = {}
            corpus = self._profile_tokens | _tokens(job.description) | _tokens(job.title) | _tokens(job.company)
            for f in batch:
                a = by_id.get(f.field_id)
                value = coerce_answer(f, a.answer) if a else None
                if a is not None and value is not None and a.confidence != "low" and not is_grounded(f, value, a.evidence, corpus):
                    log.info("Ungrounded answer for %r (evidence %r) treated as low confidence", f.label, a.evidence)
                    a = a.model_copy(update={"confidence": "low"})
                if a is None or value is None or a.confidence == "low":
                    (res.unresolved if f.required else res.left_blank).append(f)
                    log.info("No confident answer for %r (%s)", f.label, a.confidence if a else "missing")
                    continue
                res.answers[f.field_id], res.sources[f.field_id] = value, f"llm:{a.confidence}"
                if self._cacheable(f, job):
                    qh = question_hash(f.label, f.field_type, f.options)
                    self.db.cache_put(qh, f.label, f.field_type, f.options, value, f"llm:{a.confidence}")
        return res

    def flag_unresolved(self, res: Resolution, job_id: str, company: str) -> None:
        for f in res.unresolved:
            qh = question_hash(f.label, f.field_type, f.options)
            self.db.add_pending(qh, f.label, f.field_type, [o for o in f.options if not is_placeholder_option(o)], job_id, company)
