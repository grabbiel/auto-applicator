"""Form-control discovery and filling shared by every handler.

`extract_fields` walks the visible controls of a page/frame (inputs, textareas, selects, radio and
checkbox groups, ARIA comboboxes, Yes/No button pairs and file inputs), tags each one with
`data-auto-id="field_N"`, and returns its accessible label, options, required flag, current value and
validation error. `fill_field` then writes an answer back using the right interaction for that control.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

from playwright.async_api import Error as PlaywrightError
from playwright.async_api import Frame, Locator, Page

from .answers import is_placeholder_option, match_option
from .llm import FieldSpec

log = logging.getLogger(__name__)

Scope = Page | Frame

_EXTRACT_JS = r"""
(opts) => {
  const root = opts.root ? document.querySelector(opts.root) : document.body;
  if (!root) return [];
  const exclude = opts.exclude || [];
  const excluded = el => exclude.some(sel => { try { return !!el.closest(sel); } catch (e) { return false; } });
  window.__aaCounter = window.__aaCounter || 0;
  const newId = () => `field_${++window.__aaCounter}`;
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const dedupe = s => { const m = s.match(/^(.{3,}?)\s*\1$/); return m ? m[1] : s; };
  const text = el => el ? dedupe(clean(el.innerText || el.textContent)) : '';
  const shown = el => {
    if (!el || !el.isConnected || el.nodeType !== 1) return false;
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const CONTAINER = '[data-test-form-element], .fb-dash-form-element, .jobs-easy-apply-form-section__grouping, ' +
    '[data-automation-id^="formField"], .application-question, .application-field, .field, .form-field, ' +
    '.form-group, fieldset, [role=group], [role=radiogroup]';
  const containerOf = el => el.closest(CONTAINER) || el.parentElement;
  const looseVisible = el => shown(el) || shown(el.parentElement) || (el.labels && [...el.labels].some(shown));
  const byIds = ids => clean((ids || '').split(/\s+/).filter(Boolean).map(id => text(document.getElementById(id))).join(' '));
  const isOptionLabel = c => c.tagName === 'LABEL' && c.control && ['radio', 'checkbox'].includes(c.control.type);
  const nearbyText = (start, skip) => {
    let node = start;
    for (let d = 0; d < 4 && node && node !== root.parentElement; d++) {
      node = node.parentElement; if (!node) break;
      const cands = node.querySelectorAll('legend, label, [class*="label" i], [class*="question" i], [class*="title" i], h3, h4, p');
      for (const c of cands) {
        if (c.contains(start) || skip(c) || c.querySelector('input, select, textarea, button')) continue;
        const t = text(c); if (t) return t;
      }
    }
    return '';
  };
  const questionText = el => {
    let t = byIds(el.getAttribute('aria-labelledby'));
    if (!t && el.labels && el.labels.length) t = text(el.labels[0]);
    if (!t) t = clean(el.getAttribute('aria-label'));
    if (!t) { const fs = el.closest('fieldset'); const lg = fs && fs.querySelector('legend'); if (lg) t = text(lg); }
    if (!t) t = nearbyText(el, () => false);
    if (!t) t = clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || '');
    return t.slice(0, 400);
  };
  const groupQuestion = first => {
    const g = first.closest('fieldset, [role=radiogroup], [role=group]');
    if (g) {
      const lg = g.querySelector('legend');
      const t = lg ? text(lg) : (byIds(g.getAttribute('aria-labelledby')) || clean(g.getAttribute('aria-label')));
      if (t) return t.slice(0, 400);
    }
    return nearbyText(g || first.parentElement, isOptionLabel).slice(0, 400);
  };
  const optionLabel = el => clean((el.labels && el.labels[0] && text(el.labels[0])) || el.getAttribute('aria-label') ||
                                  (el.closest('label') && text(el.closest('label'))) || el.value);
  const errorText = el => {
    const ids = `${el.getAttribute('aria-describedby') || ''} ${el.getAttribute('aria-errormessage') || ''}`;
    for (const id of ids.split(/\s+/).filter(Boolean)) {
      const e = document.getElementById(id);
      if (e && shown(e) && /error|invalid/i.test(e.className + ' ' + (e.getAttribute('role') || '')) && text(e)) return text(e).slice(0, 300);
    }
    const c = containerOf(el);
    if (!c) return '';
    for (const e of c.querySelectorAll('.artdeco-inline-feedback--error, [data-automation-id="errorMessage"], [role=alert], [class*="error" i]')) {
      if (e.contains(el) || e.querySelector('input, select, textarea') || !shown(e)) continue;
      const t = text(e); if (t && t.length < 300) return t;
    }
    return '';
  };
  const isRequired = (el, label, group) => el.required || el.getAttribute('aria-required') === 'true' ||
    !!(group && group.getAttribute && group.getAttribute('aria-required') === 'true') || /\*|✱|\(required\)/i.test(label);
  const tagId = el => { let id = el.getAttribute('data-auto-id'); if (!id) { id = newId(); el.setAttribute('data-auto-id', id); } return id; };

  const out = [];
  const seenGroups = new Set();
  const controls = root.querySelectorAll('input, textarea, select, [role=combobox], button[aria-haspopup=listbox]');
  for (const el of controls) {
    if (excluded(el) || el.disabled) continue;
    const tag = el.tagName.toLowerCase();
    const type = (el.getAttribute('type') || (tag === 'input' ? 'text' : '')).toLowerCase();
    if (tag === 'input' && ['hidden', 'submit', 'button', 'reset', 'image', 'password', 'search'].includes(type)) continue;
    if (tag === 'input' && type !== 'file' && el.getAttribute('aria-hidden') === 'true') continue;
    if (el.readOnly && el.getAttribute('role') !== 'combobox') continue;

    if (type === 'radio' || type === 'checkbox') {
      if (!looseVisible(el)) continue;
      let group = el.name ? [...root.querySelectorAll(`input[type="${type}"][name="${CSS.escape(el.name)}"]`)] : [];
      let groupEl = el.closest('fieldset, [role=radiogroup], [role=group]');
      if (group.length <= 1 && groupEl) group = [...groupEl.querySelectorAll(`input[type="${type}"]`)];
      if (group.length <= 1) group = [el];
      if (type === 'checkbox' && group.length === 1) {
        const id = tagId(el);
        const lbl = questionText(el) || optionLabel(el);
        out.push({field_id: id, kind: 'checkbox', field_type: 'checkbox', label: lbl, options: [],
                  required: isRequired(el, lbl, null), current_value: el.checked ? 'Yes' : '', error: errorText(el)});
        continue;
      }
      if (group.some(g => seenGroups.has(g))) continue;
      group.forEach(g => seenGroups.add(g));
      const id = group[0].getAttribute('data-auto-id') || newId();
      const options = group.map((g, i) => { g.setAttribute('data-auto-id', id); g.setAttribute('data-auto-opt', String(i)); return optionLabel(g); });
      const lbl = groupQuestion(group[0]);
      const kind = type === 'radio' ? 'radio' : 'checkbox_group';
      out.push({field_id: id, kind, field_type: kind, label: lbl, options,
                required: group.some(g => isRequired(g, lbl, groupEl)) || isRequired(group[0], lbl, groupEl),
                current_value: group.filter(g => g.checked).map(optionLabel).join(' ; '), error: errorText(group[0])});
      continue;
    }

    if (type === 'file') {
      const c = containerOf(el);
      if (!(looseVisible(el) || shown(c))) continue;
      const id = tagId(el);
      out.push({field_id: id, kind: 'file', field_type: 'file', label: questionText(el), options: [],
                required: isRequired(el, questionText(el), null), current_value: (el.files && el.files.length) ? el.files[0].name : '',
                error: errorText(el), name: el.name || '', html_id: el.id || '', accept: el.accept || ''});
      continue;
    }

    if (!shown(el)) continue;
    const id = tagId(el);
    const lbl = questionText(el);
    const isCombo = el.getAttribute('role') === 'combobox' || el.getAttribute('aria-haspopup') === 'listbox';
    if (tag === 'select') {
      const options = [...el.options].map(o => clean(o.text)).filter(Boolean);
      const cur = el.selectedIndex >= 0 ? clean(el.options[el.selectedIndex].text) : '';
      out.push({field_id: id, kind: 'select', field_type: 'select', label: lbl, options, required: isRequired(el, lbl, null),
                current_value: cur, error: errorText(el)});
    } else if (isCombo) {
      let cur = tag === 'input' ? el.value : text(el);
      const c = containerOf(el);
      const sv = c && c.querySelector('[class*="single-value" i], [class*="singleValue" i], [class*="selected-value" i]');
      if (sv && text(sv)) cur = text(sv);
      if (/^(select|select one|select\.\.\.|choose|please select)$/i.test(cur)) cur = '';
      out.push({field_id: id, kind: 'combobox', field_type: 'combobox', label: lbl, options: [], required: isRequired(el, lbl, null),
                current_value: cur, error: errorText(el), is_input: tag === 'input'});
    } else {
      let ft = tag === 'textarea' ? 'textarea' : ({number: 'number', email: 'email', tel: 'tel', url: 'url', date: 'date'}[type] || 'text');
      if (ft === 'text' && /numeric/i.test(`${el.id} ${el.className} ${el.getAttribute('inputmode') || ''}`)) ft = 'number';
      out.push({field_id: id, kind: 'text', field_type: ft, label: lbl, options: [], required: isRequired(el, lbl, null),
                current_value: el.value || '', placeholder: clean(el.placeholder), error: errorText(el),
                max_length: el.maxLength > 0 ? el.maxLength : null});
    }
  }

  // Yes/No toggle-button pairs (e.g. Ashby) behave like radios.
  const parents = new Set([...root.querySelectorAll('button')].map(b => b.parentElement));
  for (const p of parents) {
    if (!p || excluded(p)) continue;
    const btns = [...p.children].filter(c => c.tagName === 'BUTTON' && shown(c));
    if (btns.length !== 2) continue;
    const labels = btns.map(b => text(b).toLowerCase());
    if (!(labels.includes('yes') && labels.includes('no'))) continue;
    const id = btns[0].getAttribute('data-auto-id') || newId();
    btns.forEach((b, i) => { b.setAttribute('data-auto-id', id); b.setAttribute('data-auto-opt', String(i)); });
    const lbl = nearbyText(p, c => btns.includes(c));
    const active = btns.find(b => b.getAttribute('aria-pressed') === 'true' || /active|selected/i.test(b.className));
    out.push({field_id: id, kind: 'buttons', field_type: 'radio', label: lbl, options: btns.map(text),
              required: /\*|✱/.test(lbl), current_value: active ? text(active) : '', error: errorText(btns[0])});
  }
  return out;
}
"""

_OPTIONS_JS = r"""
(el) => {
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const shown = e => { const cs = getComputedStyle(e); const r = e.getBoundingClientRect();
                       return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0; };
  document.querySelectorAll('[data-auto-choice]').forEach(o => o.removeAttribute('data-auto-choice'));
  let boxes = [];
  for (const attr of ['aria-controls', 'aria-owns']) {
    for (const id of (el.getAttribute(attr) || '').split(/\s+/).filter(Boolean)) {
      const b = document.getElementById(id); if (b) boxes.push(b);
    }
  }
  if (!boxes.length) boxes = [...document.querySelectorAll('[role=listbox]')].filter(shown);
  let opts = [];
  for (const b of boxes) opts.push(...b.querySelectorAll('[role=option], [data-automation-id="promptOption"]'));
  if (!opts.length) opts = [...document.querySelectorAll('[class*="select__option"], [class*="-option"][id*="option"]')];
  opts = opts.filter(shown);
  return opts.slice(0, 300).map((o, i) => { o.setAttribute('data-auto-choice', String(i)); return clean(o.innerText || o.textContent); });
}
"""

_ERRORS_JS = r"""
(rootSel) => {
  const root = rootSel ? document.querySelector(rootSel) : document.body;
  if (!root) return {};
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const shown = e => { const cs = getComputedStyle(e); const r = e.getBoundingClientRect();
                       return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0; };
  const CONTAINER = '[data-test-form-element], .fb-dash-form-element, .jobs-easy-apply-form-section__grouping, ' +
    '[data-automation-id^="formField"], .application-question, .application-field, .field, .form-field, ' +
    '.form-group, fieldset, [role=group], [role=radiogroup]';
  const out = {};
  const seen = new Set();
  for (const el of root.querySelectorAll('[data-auto-id]')) {
    const id = el.getAttribute('data-auto-id');
    if (seen.has(id)) continue; seen.add(id);
    const c = el.closest(CONTAINER) || el.parentElement;
    if (!c) continue;
    let msg = '';
    for (const e of c.querySelectorAll('.artdeco-inline-feedback--error, [data-automation-id="errorMessage"], [role=alert], [class*="error" i]')) {
      if (e.contains(el) || e.querySelector('input, select, textarea') || !shown(e)) continue;
      const t = clean(e.innerText); if (t && t.length < 300) { msg = t; break; }
    }
    if (!msg && el.willValidate && el.validity && !el.validity.valid) msg = el.validationMessage || 'Invalid value.';
    if (!msg && el.getAttribute('aria-invalid') === 'true') msg = 'This field is invalid or required.';
    if (msg) out[id] = msg;
  }
  return out;
}
"""

_BUTTON_JS = r"""
({rootSel, pattern, flags}) => {
  const root = rootSel ? document.querySelector(rootSel) : document.body;
  if (!root) return null;
  const re = new RegExp(pattern, flags);
  const shown = e => { const cs = getComputedStyle(e); const r = e.getBoundingClientRect();
                       return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0; };
  const name = e => (e.getAttribute('aria-label') || e.innerText || e.value || '').replace(/\s+/g, ' ').trim();
  document.querySelectorAll('[data-auto-btn]').forEach(b => b.removeAttribute('data-auto-btn'));
  const cands = [...root.querySelectorAll('button, [role=button], input[type=submit], a')]
    .filter(e => shown(e) && !e.disabled && e.getAttribute('aria-disabled') !== 'true' && re.test(name(e)));
  if (!cands.length) return null;
  const pick = cands[cands.length - 1];  // footer buttons come last in DOM order
  pick.setAttribute('data-auto-btn', '1');
  return name(pick);
}
"""


@dataclass
class FormField:
    spec: FieldSpec
    kind: str  # text | select | radio | checkbox | checkbox_group | combobox | buttons | file
    frame: Scope
    attrs: dict = field(default_factory=dict)

    @property
    def field_id(self) -> str:
        return self.spec.field_id

    @property
    def locator(self) -> Locator:
        return self.frame.locator(f'[data-auto-id="{self.field_id}"]').first

    def option_locator(self, index: int) -> Locator:
        return self.frame.locator(f'[data-auto-id="{self.field_id}"][data-auto-opt="{index}"]').first

    def describe(self) -> str:
        return f"{self.spec.label!r} ({self.spec.field_type})"


async def extract_fields(
    scope: Scope,
    root: str | None = None,
    *,
    exclude: list[str] | tuple[str, ...] = (),
    read_options: bool = True,
) -> list[FormField]:
    raw = await scope.evaluate(_EXTRACT_JS, {"root": root, "exclude": list(exclude)})
    fields: list[FormField] = []
    for r in raw:
        options = [o for o in r.get("options", []) if o]
        current = r.get("current_value", "") or ""
        if r["kind"] == "select" and is_placeholder_option(current):
            current = ""
        spec = FieldSpec(
            field_id=r["field_id"],
            label=r.get("label", "") or "",
            field_type=r["field_type"],
            options=options,
            required=bool(r.get("required")),
            current_value=current,
            placeholder=r.get("placeholder", "") or "",
            error=r.get("error", "") or "",
            max_length=r.get("max_length"),
        )
        attrs = {k: r[k] for k in ("name", "html_id", "accept", "is_input") if k in r}
        fields.append(FormField(spec=spec, kind=r["kind"], frame=scope, attrs=attrs))
    if read_options:
        for f in fields:
            if f.kind == "combobox" and not f.spec.current_value:
                await _load_combobox_options(f)
    return fields


async def _visible_options(f: FormField) -> list[str]:
    try:
        return await f.locator.evaluate(_OPTIONS_JS)
    except PlaywrightError:
        return []


async def _load_combobox_options(f: FormField) -> None:
    """Open a dropdown to read its options; huge/async lists are treated as free-text typeaheads."""
    try:
        await f.locator.scroll_into_view_if_needed(timeout=3000)
        await f.locator.click(timeout=3000)
        await f.frame.wait_for_timeout(500)
        options = await _visible_options(f)
        await f.locator.press("Escape")
    except PlaywrightError as e:
        log.debug("Could not open combobox %s: %s", f.describe(), e)
        options = []
    options = [o for o in options if o and not is_placeholder_option(o) and o.lower() not in ("no options", "loading...")]
    if 0 < len(options) <= 80:
        f.spec.options = options
    else:
        f.attrs["typeahead"] = True
        f.spec.field_type = "text"


async def fill_field(f: FormField, answer: str) -> bool:
    """Write `answer` into the control. Returns False if the control could not take the value."""
    try:
        if f.kind == "text":
            loc = f.locator
            await loc.scroll_into_view_if_needed(timeout=3000)
            await loc.fill(answer, timeout=5000)
            return True
        if f.kind == "select":
            try:
                await f.locator.select_option(label=answer, timeout=5000)
            except PlaywrightError:
                await f.locator.select_option(value=answer, timeout=5000)
            return True
        if f.kind in ("radio", "buttons"):
            choice = match_option(answer, f.spec.options)
            if choice is None:
                return False
            return await _click_option(f, f.spec.options.index(choice), check=f.kind == "radio")
        if f.kind == "checkbox":
            want = answer.strip().lower() == "yes"
            loc = f.locator
            if await loc.is_checked() != want:
                await _toggle(loc)
            return await loc.is_checked() == want
        if f.kind == "checkbox_group":
            ok = True
            for part in [p.strip() for p in answer.split(";") if p.strip()]:
                choice = match_option(part, f.spec.options)
                if choice is None:
                    ok = False
                    continue
                opt = f.option_locator(f.spec.options.index(choice))
                if not await opt.is_checked():
                    await _toggle(opt)
            return ok
        if f.kind == "combobox":
            return await _choose_combobox(f, answer)
    except PlaywrightError as e:
        log.warning("Could not fill %s: %s", f.describe(), str(e).splitlines()[0])
    return False


async def _toggle(loc: Locator) -> None:
    try:
        await loc.click(timeout=2500)
    except PlaywrightError:
        label = loc.locator("xpath=ancestor::label[1]")
        if await label.count():
            await label.first.click(timeout=2500)
        else:
            await loc.evaluate("el => (el.labels && el.labels[0] ? el.labels[0] : el).click()")


async def _click_option(f: FormField, index: int, *, check: bool) -> bool:
    opt = f.option_locator(index)
    await opt.scroll_into_view_if_needed(timeout=3000)
    if check:
        if await opt.is_checked():
            return True
        await _toggle(opt)
        return await opt.is_checked()
    await opt.click(timeout=3000)
    return True


async def _choose_combobox(f: FormField, answer: str) -> bool:
    loc = f.locator
    await loc.scroll_into_view_if_needed(timeout=3000)
    await loc.click(timeout=3000)
    is_input = bool(f.attrs.get("is_input"))
    queries = [answer]
    if is_input:
        short = re.split(r"[,(]", answer)[0].strip()
        if short and short != answer:
            queries.append(short)
    for q in queries:
        if is_input:
            await loc.fill(q, timeout=3000)
        await f.frame.wait_for_timeout(900)
        options = await _visible_options(f)
        if not options:
            continue
        choice = match_option(answer, options) or match_option(q, options)
        if choice is None and f.attrs.get("typeahead"):
            choice = options[0]
        if choice is None:
            continue
        await f.frame.locator(f'[data-auto-choice="{options.index(choice)}"]').first.click(timeout=3000)
        return True
    try:
        await loc.press("Escape")
    except PlaywrightError:
        pass
    return False


async def upload_file(f: FormField, path: Path) -> bool:
    try:
        await f.locator.set_input_files(str(path), timeout=10000)
        return True
    except PlaywrightError as e:
        log.warning("Upload to %s failed: %s", f.describe(), str(e).splitlines()[0])
        return False


def classify_file_field(f: FormField) -> str | None:
    """'resume' | 'cover_letter' | None based on label/name/id."""
    hay = f"{f.spec.label} {f.attrs.get('name', '')} {f.attrs.get('html_id', '')}".lower()
    if re.search(r"cover[\s_-]*letter", hay):
        return "cover_letter"
    if re.search(r"resume|résumé|\bcv\b|curriculum", hay):
        return "resume"
    return None


async def collect_errors(scope: Scope, root: str | None = None) -> dict[str, str]:
    try:
        return await scope.evaluate(_ERRORS_JS, root)
    except PlaywrightError:
        return {}


async def find_button(scope: Scope, pattern: str, root: str | None = None, flags: str = "i") -> Locator | None:
    """Locate the last visible, enabled button/link whose accessible name matches `pattern`."""
    try:
        name = await scope.evaluate(_BUTTON_JS, {"rootSel": root, "pattern": pattern, "flags": flags})
    except PlaywrightError:
        return None
    if not name:
        return None
    return scope.locator('[data-auto-btn="1"]').first


async def visible_text(scope: Scope, max_chars: int = 6000) -> str:
    try:
        return (await scope.evaluate("() => document.body ? document.body.innerText : ''"))[:max_chars]
    except PlaywrightError:
        return ""
