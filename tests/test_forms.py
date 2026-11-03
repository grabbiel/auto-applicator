from __future__ import annotations

import pytest

from src.forms import classify_file_field, collect_errors, extract_fields, fill_field, find_button, upload_file

from .conftest import fixture_url

pytestmark = pytest.mark.browser


async def test_extract_generic_form(page):
    await page.goto(fixture_url("generic_form.html"))
    fields = await extract_fields(page, "#app-form")
    by_label = {f.spec.label: f for f in fields}
    for label in by_label:
        print(repr(label), by_label[label].kind, by_label[label].spec.options)

    fn = by_label["First Name *"]
    assert fn.kind == "text" and fn.spec.required
    assert by_label["Email *"].spec.current_value == "prefilled@example.com"
    yrs = by_label["How many years of experience do you have with Python?"]
    assert yrs.spec.field_type == "number" and yrs.spec.required
    assert by_label["Why do you want to work here?"].spec.max_length == 500
    auth = by_label["Are you legally authorized to work in the United States? *"]
    assert auth.kind == "select" and auth.spec.options == ["Select...", "Yes", "No"] and auth.spec.current_value == ""

    spons = by_label["Will you now or in the future require sponsorship?"]  # duplicated sr-only text collapsed
    assert spons.kind == "radio" and spons.spec.options == ["Yes", "No"] and spons.spec.required

    langs = by_label["Which languages do you use?"]
    assert langs.kind == "checkbox_group" and langs.spec.options == ["Python", "Go", "Rust"]

    gender = by_label["Gender"]
    assert gender.kind == "combobox" and gender.spec.options == ["Male", "Female", "Non-binary", "I don't wish to answer"]

    lic = by_label["Do you have a valid driver's license?"]
    assert lic.kind == "buttons" and lic.spec.options == ["Yes", "No"]

    resume = by_label["Resume/CV *"]
    assert resume.kind == "file" and classify_file_field(resume) == "resume"

    agree = by_label["I certify that the information provided is accurate *"]
    assert agree.kind == "checkbox" and agree.spec.required

    assert "Hidden question" not in by_label
    assert len(fields) == 12

    # re-extraction keeps the same ids
    again = await extract_fields(page, "#app-form", read_options=False)
    assert [f.field_id for f in again] == [f.field_id for f in fields]


async def test_fill_and_submit_with_error_feedback(page, tmp_path):
    await page.goto(fixture_url("generic_form.html"))
    fields = {f.spec.label: f for f in await extract_fields(page, "#app-form")}
    assert await fill_field(fields["First Name *"], "Jane")
    submit = await find_button(page, r"^submit", "#app-form")
    await submit.click()  # native validation blocks submit: required Last Name is empty
    native = await collect_errors(page, "#app-form")
    assert fields["Last Name *"].field_id in native and fields["First Name *"].field_id not in native
    assert await fill_field(fields["Last Name *"], "Doe")
    assert await fill_field(fields["How many years of experience do you have with Python?"], "six")
    assert await fill_field(fields["Are you legally authorized to work in the United States? *"], "Yes")
    assert await fill_field(fields["Will you now or in the future require sponsorship?"], "No")
    assert await fill_field(fields["Which languages do you use?"], "Python ; Rust")
    assert await fill_field(fields["Gender"], "I don't wish to answer")
    assert await fill_field(fields["Do you have a valid driver's license?"], "Yes")
    assert await fill_field(fields["I certify that the information provided is accurate *"], "Yes")
    resume = tmp_path / "resume.pdf"
    resume.write_bytes(b"%PDF-1.4")
    assert await upload_file(fields["Resume/CV *"], resume)

    assert await page.input_value("#fn") == "Jane"
    assert await page.input_value("#auth") == "Yes"
    assert await page.is_checked("#sp-n")
    assert await page.is_checked("input[name=lang1]") and await page.is_checked("input[name=lang3]")
    assert not await page.is_checked("input[name=lang2]")
    assert await page.input_value("#cmb") == "I don't wish to answer"
    assert await page.get_attribute(".yesno button >> nth=0", "aria-pressed") == "true"
    assert await page.is_checked("#agree")

    submit = await find_button(page, r"^submit", "#app-form")
    assert submit is not None
    await submit.click()
    errors = await collect_errors(page, "#app-form")
    yrs_id = fields["How many years of experience do you have with Python?"].field_id
    assert errors == {yrs_id: "Enter a whole number"}

    refreshed = {f.field_id: f for f in await extract_fields(page, "#app-form", read_options=False)}
    assert refreshed[yrs_id].spec.error == "Enter a whole number"
    assert await fill_field(refreshed[yrs_id], "6")
    await submit.click()
    assert "Thank you for applying" in await page.inner_text("body")
