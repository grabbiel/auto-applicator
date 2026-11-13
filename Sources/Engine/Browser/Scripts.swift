/// The page scripts the automation runs (in its own isolated script world). Each is a function body; its arguments
/// arrive as variables.
enum Scripts {
    /// Small helpers every script can use.
    static let prelude = #"""
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
    """#

    /// Finds the visible form controls under `opts.root`, tags each with data-auto-id and describes it.
    static let extract = prelude + #"""
    const root = opts.root ? document.querySelector(opts.root) : document.body;
    if (!root) return [];
    const exclude = opts.exclude || [];
    const excluded = el => exclude.some(sel => { try { return !!el.closest(sel); } catch (e) { return false; } });
    window.__aaCounter = window.__aaCounter || 0;
    const newId = () => `field_${++window.__aaCounter}`;
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
    """#

    /// The options of an open dropdown (listbox) belonging to the element `sel`, tagged with data-auto-choice.
    static let options = prelude + #"""
    const el = document.querySelector(sel);
    if (!el) return [];
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
    """#

    /// Validation messages per tagged field.
    static let errors = prelude + #"""
    const root = rootSel ? document.querySelector(rootSel) : document.body;
    if (!root) return {};
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
      if (!msg && el.willValidate && el.validity && !el.validity.valid && shown(el)) msg = el.validationMessage || 'Invalid value.';
      if (!msg && el.getAttribute('aria-invalid') === 'true') msg = 'This field is invalid or required.';
      if (msg) out[id] = msg;
    }
    return out;
    """#

    /// Tags the last visible, enabled button whose name matches `pattern` (footer buttons come last) and returns its name.
    static let findButton = prelude + #"""
    const root = rootSel ? document.querySelector(rootSel) : document.body;
    if (!root) return null;
    const re = new RegExp(pattern, flags);
    const name = e => clean(e.getAttribute('aria-label') || e.innerText || e.value || '');
    document.querySelectorAll('[data-auto-btn]').forEach(b => b.removeAttribute('data-auto-btn'));
    const cands = [...root.querySelectorAll('button, [role=button], input[type=submit], a')]
      .filter(e => shown(e) && !e.disabled && e.getAttribute('aria-disabled') !== 'true' && re.test(name(e)));
    if (!cands.length) return null;
    const pick = cands[cands.length - 1];
    pick.setAttribute('data-auto-btn', '1');
    return name(pick);
    """#

    static let setValue = #"""
    let el = null; try { el = document.querySelector(sel); } catch (e) {}
    if (!el) return false;
    el.focus();
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) desc.set.call(el, value); else el.value = value;
    el.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: value}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    if (!keepFocus) el.blur();
    return el.value === value || (el.type === 'number' && Number(el.value) === Number(value)) || el.value.length > 0;
    """#

    static let selectOption = #"""
    let el = null; try { el = document.querySelector(sel); } catch (e) {}
    if (!el || el.tagName !== 'SELECT') return false;
    const norm = s => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const want = norm(label);
    const opts = [...el.options];
    const o = opts.find(o => norm(o.text) === want) || opts.find(o => norm(o.value) === want);
    if (!o) return false;
    el.focus();
    const desc = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value');
    if (desc && desc.set) desc.set.call(el, o.value); else el.value = o.value;
    o.selected = true;
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    el.blur();
    return el.selectedIndex === o.index;
    """#

    static let setFiles = #"""
    let el = null; try { el = document.querySelector(sel); } catch (e) {}
    if (!el || el.type !== 'file') return false;
    const dt = new DataTransfer();
    for (const f of files) {
      const bin = atob(f.data);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      dt.items.add(new File([bytes], f.name, {type: f.type, lastModified: Date.now()}));
    }
    el.files = dt.files;
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    return el.files.length === files.length;
    """#

    /// Number of visible form controls (to find the frame or page that holds the application form).
    static let countFields = prelude + #"""
    return [...document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]), textarea, select')].filter(shown).length;
    """#

    static let hasPassword = prelude + "return [...document.querySelectorAll('input[type=password]')].some(shown);"

    /// Iframes that may hold an application form: [{src, area}] largest first.
    static let frames = prelude + #"""
    return [...document.querySelectorAll('iframe')].filter(f => f.src && /^https?:/.test(f.src))
      .map(f => { const r = f.getBoundingClientRect(); return {src: f.src, area: Math.round(r.width * r.height), shown: shown(f)}; })
      .sort((a, b) => b.area - a.area);
    """#

    // MARK: LinkedIn

    /// Scrolls the job list so every card renders; returns how many cards there are.
    static let scrollJobList = #"""
    const first = document.querySelector('[data-occludable-job-id], [data-job-id]');
    if (!first) return 0;
    let box = first.parentElement;
    while (box && box !== document.body) {
      const oy = getComputedStyle(box).overflowY;
      if ((oy === 'auto' || oy === 'scroll') && box.scrollHeight > box.clientHeight + 10) break;
      box = box.parentElement;
    }
    if (!box || box === document.body) box = document.scrollingElement;
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    let guard = 0;
    while (box.scrollTop + box.clientHeight < box.scrollHeight - 5 && guard++ < 80) {
      box.scrollTop += step;
      await sleep(200);
    }
    await sleep(350);
    box.scrollTop = 0;
    return document.querySelectorAll('[data-occludable-job-id], [data-job-id]').length;
    """#

    static let jobCards = prelude + #"""
    const txt = (root, sels) => { for (const s of sels) { const e = root.querySelector(s); if (e && clean(e.innerText)) return dedupe(clean(e.innerText)); } return ''; };
    const out = []; const seen = new Set();
    for (const n of document.querySelectorAll('[data-occludable-job-id], [data-job-id]')) {
      let id = n.getAttribute('data-occludable-job-id') || n.getAttribute('data-job-id');
      const link = n.querySelector('a[href*="/jobs/view/"]');
      if ((!id || !/^\d+$/.test(id)) && link) { const m = link.href.match(/\/jobs\/view\/(\d+)/); if (m) id = m[1]; }
      if (!id || !/^\d+$/.test(id) || seen.has(id)) continue; seen.add(id);
      const title = link ? dedupe(clean(link.getAttribute('aria-label') || link.innerText)).replace(/ with verification$/i, '') :
        txt(n, ['.job-card-list__title', '.job-card-container__link', 'strong']);
      const company = txt(n, ['.artdeco-entity-lockup__subtitle', '.job-card-container__primary-description', '.job-card-container__company-name']);
      const location = txt(n, ['.artdeco-entity-lockup__caption', '.job-card-container__metadata-wrapper', '.job-card-container__metadata-item']);
      out.push({job_id: id, title, company, location, applied: /\bApplied\b/.test(clean(n.innerText))});
    }
    return out;
    """#

    /// On a job page: its description and how to apply. Tags the apply button with data-auto-apply.
    static let jobDetails = prelude + #"""
    let description = '';
    for (const s of ['#job-details', '.jobs-description__content', '.jobs-box__html-content', 'article', 'main']) {
      const e = document.querySelector(s);
      if (e) { description = (e.innerText || '').trim(); if (description.length > 200) break; }
    }
    document.querySelectorAll('[data-auto-apply]').forEach(b => b.removeAttribute('data-auto-apply'));
    const main = document.querySelector('main') || document.body;
    const name = e => clean(e.getAttribute('aria-label') || e.innerText);
    const buttons = [...main.querySelectorAll('button, a, [role=button]')].filter(shown);
    const easy = buttons.find(b => /easy apply/i.test(name(b)));
    if (easy) { easy.setAttribute('data-auto-apply', '1'); return {kind: 'easy_apply', description}; }
    const ext = buttons.find(b => /^apply\b/i.test(name(b)));
    if (ext) { ext.setAttribute('data-auto-apply', '1'); return {kind: 'external', description, href: ext.href || ''}; }
    const top = (main.innerText || '').slice(0, 3000);
    if (/\bApplied\b.{0,40}\bago\b|Application submitted/.test(top)) return {kind: 'applied', description};
    if (/No longer accepting applications/i.test(top)) return {kind: 'closed', description};
    return {kind: 'unknown', description};
    """#

    static let tagEasyApplyModal = #"""
    document.querySelectorAll('[data-auto-root="easy-apply"]').forEach(e => e.removeAttribute('data-auto-root'));
    const m = document.querySelector('.jobs-easy-apply-modal') ||
              [...document.querySelectorAll('[role=dialog]')].find(d => /apply to|easy apply|contact info/i.test(d.innerText));
    if (!m) return null;
    m.setAttribute('data-auto-root', 'easy-apply');
    const bar = m.querySelector('[role=progressbar], progress, .artdeco-completeness-meter-linear__progress-element');
    return bar ? (bar.getAttribute('aria-valuenow') || bar.getAttribute('value') || '') : '';
    """#

    static let easyApplyResumeSelected = #"""
    const root = document.querySelector('[data-auto-root="easy-apply"]');
    if (!root) return false;
    return !!root.querySelector('.jobs-document-upload-redesign-card__container--selected, ' +
      '[class*="document-upload"][aria-checked="true"], [class*="resume"] [aria-checked="true"], ' +
      '[class*="document-upload"] input[type=radio]:checked');
    """#

    /// Signed in to LinkedIn? (the page shows the global nav and isn't a login/checkpoint page)
    static let linkedInSignedIn = #"""
    const p = location.pathname;
    if (/\/(login|authwall|checkpoint|uas)\b/.test(p) || /signup/.test(p)) return false;
    return !!document.querySelector('#global-nav, .global-nav, [data-test-global-nav], header nav a[href*="/feed"]') ||
      /\/feed/.test(p);
    """#

    static let workdayFieldLabel = #"""
    const e = document.querySelector(sel); if (!e) return '';
    const f = e.closest('[data-automation-id^="formField"]') || e.closest('fieldset');
    const l = f && f.querySelector('label, legend'); return l ? l.innerText : '';
    """#
}
