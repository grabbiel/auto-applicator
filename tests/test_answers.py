from __future__ import annotations

from src.answers import Answerer, coerce_answer, match_numeric_range, match_option, rule_answer
from src.db import question_hash
from src.llm import FieldSpec

from .conftest import FakeLLM


def F(label, field_type="text", options=(), required=True, fid="field_1", **kw):
    return FieldSpec(field_id=fid, label=label, field_type=field_type, options=list(options), required=required, **kw)


def test_match_option_variants():
    assert match_option("Yes", ["Yes, I am authorized to work in the US", "No, I am not"]) == "Yes, I am authorized to work in the US"
    assert match_option("decline to self-identify", ["Male", "Female", "I don't wish to answer"]) == "I don't wish to answer"
    assert match_option("united states", ["Canada", "United States", "Mexico"]) == "United States"
    assert match_option("Purple", ["Red", "Blue"]) is None
    assert match_option("No", ["Select...", "Yes", "No"]) == "No"


def test_numeric_range_matching():
    opts = ["0-1 years", "2-4 years", "5-7 years", "8+ years"]
    assert match_numeric_range("6", opts) == "5-7 years"
    assert match_numeric_range("9", opts) == "8+ years"
    assert match_numeric_range("0", ["Less than 1 year", "1-3 years"]) == "Less than 1 year"
    assert match_numeric_range("six", opts) is None


def test_coerce_answer():
    assert coerce_answer(F("Years", "number"), "About 3 years") == "3"
    assert coerce_answer(F("Years", "number"), "none") is None
    assert coerce_answer(F("Agree", "checkbox"), "I agree") == "Yes"
    assert coerce_answer(F("Langs", "checkbox_group", ["Python", "Go", "Rust"]), "python ; Rust ; COBOL") == "Python ; Rust"
    assert coerce_answer(F("Why", "textarea", max_length=12), "Because I love building things") == "Because I"
    assert coerce_answer(F("Email", "email"), "not-an-email") is None


def test_profile_rules(profile):
    assert rule_answer(profile, F("First Name")) == "Jane"
    assert rule_answer(profile, F("Legal last name *")) == "Doe"
    assert rule_answer(profile, F("Email address")) == "jane.doe@example.com"
    assert rule_answer(profile, F("Will you now or in the future require visa sponsorship?", "radio", ["Yes", "No"])) == "No"
    assert rule_answer(profile, F("Are you legally authorized to work in the United States?")) == "Yes"
    assert rule_answer(profile, F("How many years of experience do you have with Python?", "number")) == "6"
    assert rule_answer(profile, F("How many years of work experience do you have with Kubernetes?", "number")) == "2"
    assert rule_answer(profile, F("How many years of professional experience do you have?", "number")) == "6"
    assert rule_answer(profile, F("How many years of experience do you have with Rust?", "number")) is None
    assert rule_answer(profile, F("Gender", "select", ["Male", "Female", "Decline"])) == "Decline to self-identify"
    assert rule_answer(profile, F("Phone device type", "select", ["Mobile", "Home"])) == "Mobile"
    assert rule_answer(profile, F("Describe your Python experience", "textarea")) is None
    assert rule_answer(profile, F("Are you comfortable working in a fast-paced environment?")) == "Yes"
    # A rule that matches but has no data must not fall through to a broader rule
    assert rule_answer(profile, F("Portfolio URL")) == "https://github.com/janedoe"


async def test_resolver_order_and_policy(profile, db, job):
    llm = FakeLLM({"rust": ("1", "low"), "favorite color": ("Blue", "medium"), "hobbies": ("", "low")})
    answerer = Answerer(profile, db, llm)  # type: ignore[arg-type]
    cached_q = F("Do you have a driver's license?", "radio", ["Yes", "No"], fid="f_cache")
    db.cache_put(question_hash(cached_q.label, "radio", cached_q.options), cached_q.label, "radio", ["Yes", "No"], "Yes", "user")

    fields = [
        F("First name", fid="f_name"),
        F("Email", fid="f_prefilled", current_value="already@there.com"),
        cached_q,
        F("Years of experience with Rust", "number", fid="f_rust"),
        F("Favorite color", "select", ["Red", "Blue"], fid="f_color"),
        F("Hobbies", required=False, fid="f_hobby"),
        F("Resume", "file", fid="f_file"),
    ]
    res = await answerer.resolve(fields, job)
    assert res.answers == {"f_name": "Jane", "f_cache": "Yes", "f_color": "Blue"}
    assert res.sources == {"f_name": "profile", "f_cache": "cache", "f_color": "llm:medium"}
    assert [f.field_id for f in res.unresolved] == ["f_rust"]
    assert [f.field_id for f in res.left_blank] == ["f_hobby"]
    assert res.blocked
    # "years of Rust" is never guessed by the model; only the two other unknown fields went to the LLM
    assert [f.field_id for f in llm.calls[0]] == ["f_color", "f_hobby"]
    # medium-confidence LLM answers are cached for next time
    assert db.cache_get(question_hash("Favorite color", "select", ["Red", "Blue"])) == "Blue"

    answerer.flag_unresolved(res, "job-1", "Initech")
    assert db.list_pending()[0]["question_text"] == "Years of experience with Rust"


async def test_resolver_feedback_bypasses_cache(profile, db, job):
    llm = FakeLLM(feedback_table={"start": ("2026-12-01", "high")})
    answerer = Answerer(profile, db, llm)  # type: ignore[arg-type]
    f = F("Desired start", fid="f1", current_value="next week")  # the value the form just rejected
    qh = question_hash(f.label, f.field_type, [])
    db.cache_put(qh, f.label, "text", [], "next week", "llm:medium")
    res = await answerer.resolve([f], job, feedback={"f1": "Use YYYY-MM-DD"})
    assert res.answers == {"f1": "2026-12-01"}
    assert llm.feedback[0] == {"f1": "Use YYYY-MM-DD"}
    assert db.cache_get(qh) == "2026-12-01"  # bad cached answer replaced

    # A still-empty required field that the form flagged is answered from the profile first.
    blank = F("First name", fid="f2")
    res = await answerer.resolve([blank], job, feedback={"f2": "This field is required"})
    assert res.answers == {"f2": "Jane"} and res.sources == {"f2": "profile"}


async def test_company_specific_questions_not_cached(profile, db, job):
    llm = FakeLLM({"initech": ("Yes", "high")})
    answerer = Answerer(profile, db, llm)  # type: ignore[arg-type]
    f = F("Have you worked at Initech before?", "radio", ["Yes", "No"])
    await answerer.resolve([f], job)
    assert db.cache_entries() == []


def test_grounding_check():
    from src.answers import _tokens, is_grounded

    corpus = _tokens("experience_years:\n  Python: 6\nwork_authorization:\n  requires_sponsorship: false\n")
    assert is_grounded(F("Sponsorship?", "radio", ["Yes", "No"]), "No", "requires_sponsorship: false", corpus)
    assert not is_grounded(F("Felony?", "radio", ["Yes", "No"]), "No", "", corpus)
    assert not is_grounded(F("Felony?", "radio", ["Yes", "No"]), "No", "No criminal record mentioned", corpus)
    assert is_grounded(F("Python years", "number"), "6", "Python: 6", corpus)
    assert not is_grounded(F("Rate Python 1-10", "number"), "9", "Python: 6", corpus)


async def test_ungrounded_llm_answers_are_flagged(profile, db, job):
    llm = FakeLLM({"felony": ("No", "high")})
    llm.evidence = "No criminal history mentioned"
    res = await Answerer(profile, db, llm).resolve([F("Have you ever been convicted of a felony?", "radio", ["Yes", "No"])], job)  # type: ignore[arg-type]
    assert res.blocked and res.answers == {}


async def test_sensitive_questions_never_guessed(profile, db, job):
    llm = FakeLLM(default=("No", "high"))
    fields = [F("Have you ever been convicted of a felony?", "radio", ["Yes", "No"], fid="a"),
              F("Rate your Python proficiency (1-10)", "number", fid="b"),
              F("What is your current salary?", required=False, fid="c")]
    res = await Answerer(profile, db, llm).resolve(fields, job)  # type: ignore[arg-type]
    assert [f.field_id for f in res.unresolved] == ["a", "b"] and [f.field_id for f in res.left_blank] == ["c"]
    assert llm.calls == []
    # once the user answers, the cached answer is used
    qh = question_hash(fields[0].label, "radio", ["Yes", "No"])
    db.cache_put(qh, fields[0].label, "radio", ["Yes", "No"], "No", "user")
    res = await Answerer(profile, db, llm).resolve(fields[:1], job)  # type: ignore[arg-type]
    assert res.answers == {"a": "No"}
