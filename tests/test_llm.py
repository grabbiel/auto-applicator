from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from src.config import LLMSettings
from src.llm import FieldSpec, FormStepResponse, JobContext, LLMClient, LLMError, profile_prompt_text


class FakeCompletions:
    def __init__(self, replies: list[str]):
        self.replies = list(replies)
        self.requests: list[dict] = []

    async def create(self, **kwargs):
        self.requests.append(kwargs)
        content = self.replies.pop(0)
        return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=content))])


def make_client(replies: list[str]) -> tuple[LLMClient, FakeCompletions]:
    comp = FakeCompletions(replies)
    fake = SimpleNamespace(chat=SimpleNamespace(completions=comp))
    return LLMClient(LLMSettings(), client=fake), comp  # type: ignore[arg-type]


async def test_structured_sends_json_schema_and_parses():
    good = json.dumps({"answers": [{"field_id": "field_1", "evidence": "Python: 3", "answer": "3", "confidence": "high"}]})
    client, comp = make_client([good])
    out = await client.answer_fields(
        [FieldSpec(field_id="field_1", label="Years of Python", field_type="number", required=True)],
        "personal: {}",
        JobContext(title="Eng"),
    )
    assert isinstance(out, FormStepResponse) and out.answers[0].answer == "3"
    req = comp.requests[0]
    assert req["temperature"] == 0.0
    assert req["model"] == "qwen2.5:7b-ctx8192"
    assert req["response_format"]["type"] == "json_schema"
    assert req["response_format"]["json_schema"]["name"] == "FormStepResponse"
    assert "digits only" in req["messages"][0]["content"]


async def test_structured_retries_on_invalid_json_then_fails():
    bad = '{"answers": [{"field_id": "f", "evidence": "", "answer": "x", "confidence": "certain"}]}'
    good = "```json\n" + json.dumps({"answers": [{"field_id": "f", "evidence": "", "answer": "x", "confidence": "high"}]}) + "\n```"
    client, comp = make_client([bad, good])
    out = await client.structured(FormStepResponse, [{"role": "user", "content": "hi"}])
    assert out.answers[0].confidence == "high"
    assert "did not match the schema" in comp.requests[1]["messages"][-1]["content"]

    client, _ = make_client([bad, bad, bad])
    with pytest.raises(LLMError):
        await client.structured(FormStepResponse, [{"role": "user", "content": "hi"}])


async def test_feedback_is_included_in_prompt():
    good = json.dumps({"answers": [{"field_id": "field_1", "evidence": "SQL: 5", "answer": "5", "confidence": "high"}]})
    client, comp = make_client([good])
    await client.answer_fields(
        [FieldSpec(field_id="field_1", label="Years", field_type="number")], "x", JobContext(), {"field_1": "Enter a whole number"}
    )
    assert "Enter a whole number" in comp.requests[0]["messages"][1]["content"]


def test_profile_prompt_excludes_files(profile):
    text = profile_prompt_text(profile)
    assert "resume_pdf" not in text and "Jane" in text and "requires_sponsorship" in text


def _resume_reply(**contact) -> str:
    blank = dict.fromkeys(("full_name", "first_name", "last_name", "email", "phone", "city", "state", "country",
                           "linkedin", "github", "portfolio"), "")
    return json.dumps({
        "contact": blank | contact, "summary": "  ", "total_years_experience": 0, "certifications": [" ", "PMP"],
        "skills": ["SQL (6 years)", "Excel [3 yrs]", "SQL", ""],
        "experience_years": [{"skill": "SQL", "years": 6}, {"skill": "", "years": 2}, {"skill": "R", "years": 0}],
        "work_history": [{"company": "Summit", "title": "Analyst"}, {"company": " ", "title": ""}],
        "education": [{"school": "CU Boulder", "degree": "BS"}, {"school": ""}],
    })


async def test_extract_resume_turns_blanks_into_missing_values():
    client, comp = make_client([_resume_reply(full_name="Jordan Lee Rivera", email=" j@example.com ")])
    ex = await client.extract_resume("Jordan Lee Rivera\nj@example.com")
    assert comp.requests[0]["response_format"]["json_schema"]["schema"]["required"]  # nothing optional for the model
    assert (ex.first_name, ex.last_name, ex.email, ex.phone) == ("Jordan", "Lee Rivera", "j@example.com", None)
    assert ex.summary is None and ex.total_years_experience is None and ex.certifications == ["PMP"]
    assert ex.skills == ["SQL", "Excel"]
    assert [(s.skill, s.years) for s in ex.experience_years] == [("SQL", 6)]
    assert [r.company for r in ex.work_history] == ["Summit"] and [e.school for e in ex.education] == ["CU Boulder"]


async def test_extract_resume_prefers_split_names():
    client, _ = make_client([_resume_reply(full_name="J. Rivera", first_name="Jordan", last_name="Rivera")])
    ex = await client.extract_resume("x")
    assert (ex.first_name, ex.last_name) == ("Jordan", "Rivera")
