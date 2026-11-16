/// The page scripts the automation runs (in its own isolated script world). Each is a function body; its arguments
/// arrive as variables.
enum Scripts {
    /// Small helpers every script can use.
    /// Put before every script: a `document` that also looks inside open shadow roots, which the page's own lookups
    /// don't reach. LinkedIn draws its Easy Apply window in one (under #interop-outlet); other sites draw parts of
    /// their forms in them too. Its querySelectorAll returns an array.
    static let deepDocument = #"""
    // A form that only works inside its frame (iCIMS turns the frame's own page, opened by itself, back into the page
    // around the frame): scripts work in the frame's document while the page holds it, tagged (Scripts.tagSelfFrame).
    const __aaFrame = (() => {
      try {
        const f = window.document.querySelector('iframe[data-aa-frame]');
        const d = f && f.contentDocument;
        return d && d.body && d.URL !== 'about:blank' ? f : null;
      } catch (e) { return null; }
    })();
    const document = (() => {
      const real = __aaFrame ? __aaFrame.contentDocument : window.document;
      let roots = null, at = 0;
      const shadows = () => {
        if (roots && Date.now() - at < 300) return roots;
        roots = []; at = Date.now();
        const walk = node => { for (const el of node.querySelectorAll('*')) if (el.shadowRoot) { roots.push(el.shadowRoot); walk(el.shadowRoot); } };
        walk(real);
        return roots;
      };
      const first = (how, arg) => { for (const r of shadows()) { const e = r[how](arg); if (e) return e; } return null; };
      const deep = {
        querySelector: sel => real.querySelector(sel) || first('querySelector', sel),
        querySelectorAll: sel => { const out = [...real.querySelectorAll(sel)]; for (const r of shadows()) out.push(...r.querySelectorAll(sel)); return out; },
        getElementById: id => real.getElementById(id) || first('getElementById', id),
        elementFromPoint: (x, y) => {
          let e = real.elementFromPoint(x, y);
          while (e && e.shadowRoot) { const inner = e.shadowRoot.elementFromPoint(x, y); if (!inner || inner === e) break; e = inner; }
          return e;
        },
      };
      return new Proxy(real, {
        get(t, k) {
          if (Object.prototype.hasOwnProperty.call(deep, k)) return deep[k];
          if (k === 'activeElement') { let a = t.activeElement; while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement; return a; }
          const v = Reflect.get(t, k);
          return typeof v === 'function' ? v.bind(t) : v;
        },
        set(t, k, v) { t[k] = v; return true; },
      });
    })();
    """#

    /// Tags (data-aa-frame) a frame the app has to work inside: one from the same site at the page's own address
    /// (iCIMS draws each step in a frame of the page it's on, and that page opened by itself turns back into the page
    /// with the frame), or one written into the page. Returns the frame's address when it tags one now.
    static let tagSelfFrame = #"""
    const top = window.document;
    if (top.querySelector('iframe[data-aa-frame]')) return '';
    const path = u => u.pathname.replace(/\/+$/, '');
    for (const f of top.querySelectorAll('iframe')) {
      try {
        const d = f.contentDocument;
        if (!d || !d.body || d.URL === 'about:blank') continue;
        const r = f.getBoundingClientRect();
        if (r.width * r.height < 40000) continue;
        const u = new URL(d.URL);
        const own = d.URL === 'about:srcdoc' ||
          (u.origin === location.origin && (path(u) === path(location) || /[?&]in_iframe=1\b/.test(u.search)));
        if (own) { f.setAttribute('data-aa-frame', '1'); return d.URL; }
      } catch (e) {}
    }
    return '';
    """#

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
    // Buttons that sign in with another company's account ("Continue with GitHub", "Apply with LinkedIn"): never pressed.
    const SOCIAL = /\b(with|using|via|through)\s+(your\s+)?(google|apple|github|microsoft|linkedin|facebook|twitter|x|amazon|yahoo|indeed|okta)\b|^(google|apple|github|microsoft|linkedin|facebook)$/i;
    const social = b => SOCIAL.test(clean(b.innerText || b.value || '')) || SOCIAL.test(clean(b.getAttribute('aria-label') || ''));
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
    const ROBOT_WORDS = /\b(robots?|bots?|spam ?bots?) only\b|\bfor (robots|bots)\b|if you('| a)re (a )?human|\bnot for humans\b|leave (this )?(field |box )?(blank|empty)\b|do not (fill|enter|type|change)( (in|anything|this))? ?(this|here)?\b.{0,30}human/i;
    const honeypot = (el, lbl) => {
      if (el.getAttribute('data-automation-id') === 'beecatcher') return true;
      const words = [lbl, el.getAttribute('aria-label'), el.placeholder, el.title].filter(Boolean).join(' ');
      if (ROBOT_WORDS.test(words)) return true;
      const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
      const clipped = /rect\(\s*[01]px,?\s*[01]px,?\s*[01]px,?\s*[01]px\s*\)/.test(cs.clip) || /polygon\((0(px)? 0(px)?,?\s*){3,}0(px)? 0(px)?\)/.test(cs.clipPath);
      if (clipped) return true;
      // Placed far off the page (left: -9999px).
      const page = document.documentElement;
      return r.right < -100 || r.bottom < -100 - window.scrollY || r.left > Math.max(page.scrollWidth, window.innerWidth) + 100;
    };
    const looseVisible = el => shown(el) || shown(el.parentElement) || (el.labels && [...el.labels].some(shown));
    const byIds = ids => clean((ids || '').split(/\s+/).filter(Boolean).map(id => text(document.getElementById(id))).join(' '));
    const isOptionLabel = c => c.tagName === 'LABEL' && c.control && ['radio', 'checkbox'].includes(c.control.type);
    const CONTROLS = 'input:not([type=hidden]), select, textarea, [role=combobox], [role=listbox], [role=radiogroup]';
    // Words in the blocks around `start`, up to `to` levels up. Past four (Rippling puts its question six levels up,
    // beside a "Select" list) only while the block holds no other box, so the words can't be another question's.
    const nearbyText = (start, skip, from = 0, to = 4) => {
      let node = start;
      for (let d = 0; d < to && node && node !== root.parentElement; d++) {
        node = node.parentElement; if (!node) break;
        if (d >= 4 && [...node.querySelectorAll(CONTROLS)].some(c => !start.contains(c) && !c.contains(start))) break;
        if (d < from) continue;
        const cands = node.querySelectorAll('legend, label, [class*="label" i], [class*="question" i], [class*="title" i], h3, h4, p');
        for (const c of cands) {
          // Not the box's own placeholder ("<p>Select</p>" inside a list button), nor a choice in its open menu.
          if (c.contains(start) || start.contains(c) || skip(c) || c.querySelector('input, select, textarea, button') ||
              c.closest('[role=listbox], [role=option], [role=menu]')) continue;
          const t = text(c); if (t) return t;
        }
      }
      return '';
    };
    // A box's name that says nothing of its question.
    const GENERIC = /^(please )?(select|choose|search)( one| an option)?( required)?$|^(textbox|combobox)$/i;
    // Screen-reader notes that aren't the question ("Total 0 file selected").
    const STATUS = /^(total )?\d+ files? selected$|^no file (chosen|selected)$/i;
    const namedBy = ids => clean((ids || '').split(/\s+/).filter(Boolean).map(id => text(document.getElementById(id))).filter(t => !STATUS.test(t)).join(' '));
    // A label wrapped around its box (Paylocity's "Country" around the list showing "United States"): its own words only.
    const labelText = (l, el) => {
      if (!l.contains(el)) return text(l);
      let w = el; while (w.parentElement && w.parentElement !== l) w = w.parentElement;
      const own = [...l.childNodes].filter(n => n !== w && !(n.nodeType === 1 && n.querySelector('input, select, textarea, [role=combobox], [aria-haspopup]')))
        .map(n => n.nodeType === 3 ? n.textContent : (n.nodeType === 1 ? n.innerText || n.textContent : '')).join(' ');
      return dedupe(clean(own)) || text(l);
    };
    const questionText = el => {
      let t = byIds(el.getAttribute('aria-labelledby'));
      // A label wrapped around a file box and a "Drop or select" button that names itself after the question
      // (Rippling's "Résumé").
      if (!t && el.labels && el.labels.length) t = namedBy(el.labels[0].getAttribute('aria-labelledby')) || labelText(el.labels[0], el);
      if (!t) t = clean(el.getAttribute('aria-label'));
      // A list button named only "Select One Required" (Workday's questions) or "Select" (Rippling's): the question is
      // in the words beside it.
      if (GENERIC.test(t)) t = '';
      if (!t) { const fs = el.closest('fieldset'); const lg = fs && fs.querySelector('legend'); if (lg) t = text(lg); }
      if (!t) t = nearbyText(el, () => false);
      if (!t) { const own = clean(el.getAttribute('placeholder') || el.getAttribute('title') || ''); if (!GENERIC.test(own)) t = own; }
      if (!t) t = nearbyText(el, () => false, 4, 8);
      if (!t) t = clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || '');
      return t.slice(0, 400);
    };
    const groupQuestion = first => {
      const g = first.closest('fieldset, [role=radiogroup], [role=group]');
      if (g) {
        const lg = g.querySelector('legend');
        const t = lg ? text(lg) : (byIds(g.getAttribute('aria-labelledby')) || clean(g.getAttribute('aria-label')));
        if (t) return t.slice(0, 400);
        // A label wrapped around the whole group (Paylocity's "How did you hear about us?").
        const wrap = g.parentElement && g.parentElement.closest('label');
        if (wrap) { const w = labelText(wrap, g); if (w) return w.slice(0, 400); }
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
    // The heading of the part of the form a field sits in ("Education", "Work experience"), so a question like "End
    // date month" says which end date it means.
    const HEAD = 'h1, h2, h3, h4, h5, h6, legend, [role=heading], [class*="section-title" i], [class*="sectiontitle" i], ' +
      '[class*="section-header" i], [class*="section-heading" i], [class*="group-title" i]';
    // A repeating group's numbered names say what it is: "custom[work][0][start_year]", "educations.1.school".
    const NAMED_EDU = /(^|[\[._-])(educations?|schools?)\]?[\[._-]\d/i;
    const NAMED_WORK = /(^|[\[._-])(work|works|employments?|experiences?|work_?experiences?|positions?|jobs?)\]?[\[._-]\d/i;
    const sectionOf = (el, label) => {
      const name = el.getAttribute('name') || '';
      if (NAMED_EDU.test(name)) return 'Education';
      if (NAMED_WORK.test(name)) return 'Work experience';
      let node = el;
      for (let d = 0; d < 12 && node && node !== document.body; d++) {
        const own = `${node.id || ''} ${typeof node.className === 'string' ? node.className : ''} ${node.getAttribute('data-automation-id') || ''}`;
        if (/educat/i.test(own)) return 'Education';
        if (/employment|work-?experience|workexperience|work_experience|job-?history|work-?history/i.test(own)) return 'Work experience';
        if (node.tagName === 'FIELDSET' && node !== el) { const lg = node.querySelector(':scope > legend'); if (lg && text(lg) && text(lg) !== label) return text(lg).slice(0, 80); }
        let sib = node.previousElementSibling;
        for (let k = 0; sib && k < 30; k++, sib = sib.previousElementSibling) {
          if (sib.querySelector('input, select, textarea')) { if (sib.matches(HEAD)) break; continue; }
          const h = sib.matches(HEAD) ? sib : [...sib.querySelectorAll(HEAD)].pop();
          if (h) { const t = text(h); if (t && t.length <= 80 && t !== label) return t; }
        }
        node = node.parentElement;
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
        if (group.length <= 1 && groupEl) {
          group = [...groupEl.querySelectorAll(`input[type="${type}"]`)];
          // Separate statements that only share a box (Adobe's consent boxes: each required on its own, or sentences
          // rather than choices) are separate checkboxes, not one "pick any" question.
          if (type === 'checkbox' && group.length > 1 &&
              (group.some(m => m.required || m.getAttribute('aria-required') === 'true') || group.some(m => optionLabel(m).length > 120))) group = [el];
        }
        if (group.length <= 1) group = [el];
        if (type === 'checkbox' && group.length === 1) {
          const id = tagId(el);
          const lbl = questionText(el) || optionLabel(el);
          out.push({field_id: id, kind: 'checkbox', field_type: 'checkbox', label: lbl, options: [],
                    required: isRequired(el, lbl, null), current_value: el.checked ? 'Yes' : '', error: errorText(el), section: sectionOf(el, lbl)});
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
                  current_value: group.filter(g => g.checked).map(optionLabel).join(' ; '), error: errorText(group[0]), section: sectionOf(group[0], lbl)});
        continue;
      }

      if (type === 'file') {
        const c = containerOf(el);
        if (!(looseVisible(el) || shown(c))) continue;
        const id = tagId(el);
        out.push({field_id: id, kind: 'file', field_type: 'file', label: questionText(el), options: [],
                  required: isRequired(el, questionText(el), null), current_value: (el.files && el.files.length) ? el.files[0].name : '',
                  error: errorText(el), name: el.name || '', html_id: el.id || '', accept: el.accept || '', section: sectionOf(el, questionText(el))});
        continue;
      }

      if (!shown(el)) continue;
      const id = tagId(el);
      const lbl = questionText(el);
      // Angular Material's search boxes say they're one only while focused (TCS's Skills): their class says it always.
      const isCombo = el.getAttribute('role') === 'combobox' || el.getAttribute('aria-haspopup') === 'listbox' ||
        (tag === 'input' && (/(^|\s)mat(-mdc)?-autocomplete-trigger(\s|$)/.test(el.className || '') || /^(list|both)$/.test(el.getAttribute('aria-autocomplete') || '')));
      // A trap for robots that people never see (Workday's "Enter website. This input is for robots only, do not enter if
      // you're human"): filling it marks the application as a bot's.
      if (!isCombo && tag !== 'select' && honeypot(el, lbl)) continue;
      if (tag === 'select') {
        const options = [...el.options].map(o => clean(o.text)).filter(Boolean);
        const cur = el.selectedIndex >= 0 ? clean(el.options[el.selectedIndex].text) : '';
        out.push({field_id: id, kind: 'select', field_type: 'select', label: lbl, options, required: isRequired(el, lbl, null),
                  current_value: cur, error: errorText(el), section: sectionOf(el, lbl), name: el.name || ''});
      } else if (isCombo) {
        let cur = tag === 'input' ? el.value : text(el);
        const c = containerOf(el);
        const SV = '[class*="single-value" i], [class*="singleValue" i], [class*="selected-value" i]';
        const sv = [c, el.closest('[aria-owns], [aria-controls], [aria-haspopup]'), el.labels && el.labels[0]].filter(Boolean)
          .map(x => x.querySelector(SV)).find(Boolean);
        if (sv && text(sv)) cur = text(sv);
        // An empty list shows its placeholder ("Select Title" in Angular Material's mat-select).
        const ph = el.querySelector('[class*="placeholder" i]');
        if (/(^|\s)mat(-mdc)?-select-empty(\s|$)/.test(el.className || '') || (ph && text(ph) === cur)) cur = '';
        if (/^(select|select one|select\.\.\.|choose|please select|please choose)$/i.test(cur) ||
            /^(please )?(select|choose)( an?| the| your)? [\w ]{1,40}$/i.test(cur) && cur.split(' ').length <= 6) cur = '';
        const placeholder = clean(el.placeholder || el.getAttribute('aria-placeholder') || '');
        // A box that takes several choices, each one a chip ("Skills… (Maximum 5)").
        const most = `${lbl} ${placeholder}`.match(/\b(?:max(?:imum)?\.?|up to)\s*(?:of\s*)?(\d+|two|three|four|five|six|seven|eight|nine|ten)\b/i);
        const words = {two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10};
        const chips = tag === 'input' && !!(el.closest('mat-chip-grid, [role=grid]') || (containerOf(el) && containerOf(el).querySelector('mat-chip-grid, mat-chip-set, [class*="chip-list" i]')));
        const maxChoices = most ? (Number(most[1]) || words[most[1].toLowerCase()] || 0) : 0;
        out.push({field_id: id, kind: 'combobox', field_type: 'combobox', label: lbl, options: [], required: isRequired(el, lbl, null),
                  current_value: cur, error: errorText(el), is_input: tag === 'input', section: sectionOf(el, lbl), name: el.name || '',
                  placeholder, max_choices: tag === 'input' && (maxChoices > 1 || chips) ? (maxChoices || 5) : 0});
      } else {
        let ft = tag === 'textarea' ? 'textarea' : ({number: 'number', email: 'email', tel: 'tel', url: 'url', date: 'date'}[type] || 'text');
        if (ft === 'text' && /numeric/i.test(`${el.id} ${el.className} ${el.getAttribute('inputmode') || ''}`)) ft = 'number';
        // A month picker takes "YYYY-MM"; say so, since the AI and the person only see the label.
        const placeholder = clean(el.placeholder) || (type === 'month' ? 'YYYY-MM' : '');
        out.push({field_id: id, kind: 'text', field_type: ft, label: lbl, options: [], required: isRequired(el, lbl, null),
                  current_value: el.value || '', placeholder, error: errorText(el),
                  max_length: el.maxLength > 0 ? el.maxLength : null, section: sectionOf(el, lbl), name: el.name || '',
                  autocomplete: el.getAttribute('autocomplete') || ''});
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
                required: /\*|✱/.test(lbl), current_value: active ? text(active) : '', error: errorText(btns[0]), section: sectionOf(p, lbl)});
    }
    return out;
    """#

    /// The options of an open dropdown (listbox) belonging to the element `sel`, tagged with data-auto-choice.
    static let options = prelude + #"""
    const el = document.querySelector(sel);
    if (!el) return [];
    document.querySelectorAll('[data-auto-choice]').forEach(o => o.removeAttribute('data-auto-choice'));
    let boxes = [];
    // The list may belong to the box or to the widget around it (Paylocity's aria-owns is on the wrapper).
    for (const owner of [el, el.closest('[aria-owns], [aria-controls]')].filter(Boolean)) {
      for (const attr of ['aria-controls', 'aria-owns']) {
        for (const id of (owner.getAttribute(attr) || '').split(/\s+/).filter(Boolean)) {
          const b = document.getElementById(id); if (b && !boxes.includes(b)) boxes.push(b);
        }
      }
    }
    if (!boxes.length) boxes = [...document.querySelectorAll('[role=listbox]')].filter(shown);
    let opts = [];
    for (const b of boxes) opts.push(...b.querySelectorAll('[role=option], [data-automation-id="promptOption"]'));
    if (!opts.length) for (const b of boxes) opts.push(...b.querySelectorAll('[role=listitem]'));
    if (!opts.length) opts = [...document.querySelectorAll('[class*="select__option"], [class*="-option"][id*="option"]')];
    opts = opts.filter(shown);
    return opts.slice(0, 1000).map((o, i) => { o.setAttribute('data-auto-choice', String(i)); return clean(o.innerText || o.textContent); });
    """#

    /// Scrolls an open list that draws only the rows in view and doesn't narrow as you type (Paylocity's 240
    /// countries) until a row reading one of `want` is drawn. True when it is.
    static let scrollToOption = prelude + #"""
    const el = document.querySelector(sel);
    if (!el) return false;
    const key = t => (t || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
    const wanted = want.map(key).filter(Boolean);
    let boxes = [];
    for (const owner of [el, el.closest('[aria-owns], [aria-controls]')].filter(Boolean)) {
      for (const attr of ['aria-controls', 'aria-owns']) {
        for (const id of (owner.getAttribute(attr) || '').split(/\s+/).filter(Boolean)) { const b = document.getElementById(id); if (b) boxes.push(b); }
      }
    }
    if (!boxes.length) boxes = [...document.querySelectorAll('[role=listbox]')].filter(shown);
    for (const b of boxes) {
      const sc = [b, ...b.querySelectorAll('*')].find(e => e.scrollHeight > e.clientHeight + 5 && /auto|scroll/.test(getComputedStyle(e).overflowY));
      if (!sc) continue;
      const has = () => [...b.querySelectorAll('[role=option], [role=listitem]')].some(o => wanted.includes(key(o.innerText || o.textContent)));
      // Waits for the list to redraw without timers, which a page out of sight runs at most once a second.
      const tick = () => new Promise(r => { const c = new MessageChannel(); c.port1.onmessage = () => r(); c.port2.postMessage(0); });
      const settle = async () => { for (let i = 0; i < 3; i++) await tick(); };
      sc.scrollTop = 0; sc.dispatchEvent(new Event('scroll'));
      await settle();
      for (let k = 0; k < 400; k++) {
        if (has()) return true;
        const before = sc.scrollTop;
        sc.scrollTop = before + Math.max(20, sc.clientHeight * 0.8);
        sc.dispatchEvent(new Event('scroll'));
        await settle();
        if (sc.scrollTop <= before) return has();
      }
    }
    return false;
    """#

    /// After a list opens: the search box it brought with it (select2's, a focused search box in its popup), tagged
    /// data-auto-search. False when there's none.
    static let popupSearch = prelude + #"""
    const el = document.querySelector(sel);
    document.querySelectorAll('[data-auto-search]').forEach(e => e.removeAttribute('data-auto-search'));
    const ok = e => !!e && e !== el && e.tagName === 'INPUT' && /^(text|search)$/.test(e.type) && shown(e) && !(el && el.contains(e));
    let box = document.activeElement;
    if (!ok(box)) box = [...document.querySelectorAll('.select2-container--open .select2-search__field, .select2-drop-active input, input[role=searchbox], [role=dialog] input[type=search], [role=listbox] input')].find(ok);
    if (!ok(box)) return false;
    box.setAttribute('data-auto-search', '1');
    return true;
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
        const t = clean(e.innerText);
        // Good news in an alert box (Workday's "resume.pdf successfully uploaded") isn't an error.
        if (/\b(success(ful(ly)?)?|uploaded|saved)\b/i.test(t) && !/\b(error|invalid|required|fail(ed)?|must|please|not|couldn'?t|unable)\b/i.test(t)) continue;
        if (t && t.length < 300) { msg = t; break; }
      }
      // A list box's own text box is empty while the list shows its choice beside it (Paylocity's Country and State,
      // whose box is marked required): the browser's "Fill out this field" for it is no error.
      const SV = '[class*="single-value" i], [class*="singleValue" i], [class*="selected-value" i]';
      const showsChoice = () => el.tagName === 'INPUT' && [el.closest('[aria-owns], [aria-controls], [aria-haspopup]'), el.labels && el.labels[0]]
        .filter(Boolean).some(x => { const v = x.querySelector(SV), t = v ? clean(v.innerText) : ''; return !!t && !/^(-+|(please )?(select|choose)\b.*)$/i.test(t); });
      if (!msg && el.willValidate && el.validity && !el.validity.valid && shown(el) && !(el.validity.valueMissing && showsChoice()))
        msg = el.validationMessage || 'Invalid value.';
      if (!msg && el.getAttribute('aria-invalid') === 'true') msg = 'This field is invalid or required.';
      if (msg) out[id] = msg;
    }
    return out;
    """#

    /// Tags the box for an email address (or user name) on a sign-in or password-reset page with data-auto-emailbox
    /// and returns what it holds; null when there's none.
    static let tagEmailBox = prelude + #"""
    document.querySelectorAll('[data-auto-emailbox]').forEach(b => b.removeAttribute('data-auto-emailbox'));
    const boxes = [...document.querySelectorAll('input')].filter(i => shown(i) && !i.disabled && !i.readOnly && /^(email|text)$/i.test(i.type || 'text'));
    const hay = i => [i.name, i.id, i.autocomplete, i.placeholder, i.getAttribute('aria-label'), i.labels && i.labels[0] ? i.labels[0].innerText : ''].join(' ');
    let box = boxes.find(i => i.type === 'email') || boxes.find(i => /e-?mail|user ?name|user ?id|login/i.test(hay(i)));
    if (!box && boxes.length === 1 && !/robot|website|url/i.test(hay(boxes[0]))) box = boxes[0];
    if (!box) return null;
    box.setAttribute('data-auto-emailbox', '1');
    return box.value || '';
    """#

    /// Tags the last visible, enabled button whose name matches `pattern` (footer buttons come last) and returns its name.
    static let findButton = prelude + #"""
    const root = rootSel ? document.querySelector(rootSel) : document.body;
    if (!root) return null;
    const re = new RegExp(pattern, flags);
    const name = e => clean(e.getAttribute('aria-label') || e.innerText || e.value || '');
    // The label or the visible text (they're worded differently in some languages: "Ir al siguiente paso" / "Siguiente").
    const named = e => re.test(name(e)) || re.test(clean(e.innerText || e.value || ''));
    document.querySelectorAll('[data-auto-btn]').forEach(b => b.removeAttribute('data-auto-btn'));
    const cands = [...root.querySelectorAll('button, [role=button], input[type=submit], a')]
      .filter(e => shown(e) && !e.disabled && e.getAttribute('aria-disabled') !== 'true' && named(e) && !social(e));
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

    /// Counts the controls that could belong to an application (not a site search box, a chat widget, a cookie
    /// banner or a "Save job" checkbox), in `doc` (a frame's document too).
    static let formFieldCounter = #"""
    const NOT_FORM = 'header, nav, footer, [role=search], form[role=search], form[action*="search" i], [id*=chat i], [class*=chat i], ' +
      '[id*=cookie i], [class*=cookie i], [id*=consent-sdk i], [aria-label*=cookie i]';
    const formFields = doc => [...doc.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=search]):not([type=image]):not([type=reset]), textarea, select')]
      .filter(e => {
        const r = e.getBoundingClientRect(), cs = doc.defaultView.getComputedStyle(e);
        if (!(r.width > 0 && r.height > 0 && cs.display !== 'none' && cs.visibility !== 'hidden')) return false;
        if (e.closest(NOT_FORM)) return false;
        if (/search|ask anything|keyword|type a message/i.test(e.placeholder || '')) return false;
        const lbl = (e.labels && e.labels[0] ? e.labels[0].innerText : '') + ' ' + (e.getAttribute('aria-label') || '') + ' ' + (e.id || '');
        if (e.type === 'checkbox' && /save|alert|subscribe|remember me|keep me signed|stay signed/i.test(lbl)) return false;
        return true;
      });
    """#

    /// Number of visible form controls that could be part of an application.
    static let countFields = prelude + formFieldCounter + "return formFields(document).length;"

    static let hasPassword = prelude + formFieldCounter + "return formFields(document).some(e => e.type === 'password');"

    /// Iframes that may hold an application form: [{src, area, shown, fields}] largest first; fields is -1 when the
    /// frame is from another site (its page can't be read from here).
    static let frames = prelude + formFieldCounter + #"""
    const local = location.protocol === 'file:';
    return [...document.querySelectorAll('iframe')].filter(f => f.src && (/^https?:/.test(f.src) || (local && /^file:/.test(f.src))))
      .map(f => {
        const r = f.getBoundingClientRect();
        let fields = -1;  // unknown: another site's frame, or one still loading
        let entry = false;  // it holds the job's Apply link (iCIMS: "Apply for this job online")
        try {
          const d = f.contentDocument;
          if (d && d.body && d.readyState === 'complete' && d.URL !== 'about:blank') {
            fields = formFields(d).length;
            entry = [...d.querySelectorAll('a[href], button, [role=button]')]
              .some(b => /^\s*apply\b/i.test(b.innerText || b.title || '') && b.getBoundingClientRect().width > 0);
          }
        } catch (e) {}
        return {src: f.src, area: Math.round(r.width * r.height), shown: shown(f), fields, entry};
      })
      .sort((a, b) => b.area - a.area);
    """#

    /// What kind of page this is, before looking for a form: a bot check that is still running, an error page, a
    /// closed posting, a page asking to click a link in an email, or the application itself.
    static let pageKind = prelude + formFieldCounter + #"""
    const body = clean(document.body ? document.body.innerText : '').slice(0, 4000);
    const fields = formFields(document);
    const head = body.slice(0, 1500);
    let kind = 'page';
    const puzzle = [...document.querySelectorAll('iframe')].some(f => {
      if (!shown(f) || !/hcaptcha\.com\/captcha|recaptcha\/(api2|enterprise)\/bframe|arkoselabs|funcaptcha|captcha-delivery\.com|challenges\.cloudflare\.com/i.test(f.src || '')) return false;
      const r = f.getBoundingClientRect(); return r.width >= 250 && r.height >= 250;
    });
    if (puzzle || /performing security verification|verif(y|ying) (that )?you are (a )?human|checking (if the site connection is secure|your browser)|just a moment\.\.\.|are you a robot|press (&|and) hold|ddos protection by/i.test(head)) kind = 'botcheck';
    else if (/no longer accepting applications|(job|position|posting|requisition) (is )?no longer (available|open|active)|(position|job) has been (filled|closed)|this job (has )?expired|job not found/i.test(body)) kind = 'closed';
    else if (fields.length === 0 && /we could not process your request|something went wrong|an (unexpected )?error (has )?occurred|please try again later|service (is )?(temporarily )?unavailable|page (you requested )?(could not be|was not|not) found|access denied/i.test(head)) kind = 'error';
    else if (/check your (e-?mail|inbox)|verify your (e-?mail|account)|we('ve| have)? (just )?sent (you )?(an? )?(e-?mail|link|verification)|confirm your e-?mail|activation (link|e-?mail)|click (on )?the link (in|we)/i.test(body) && !fields.some(e => e.type !== 'password')) kind = 'emaillink';
    // Nothing but the message: no menus, links or pictures of the site's own.
    const bare = body.length < 200 && document.querySelectorAll('a[href], img, nav, header').length < 3;
    // A resume box that is only a drop zone (its file input hidden) is still a form.
    const upload = [...document.querySelectorAll('input[type=file]')].some(f => !f.disabled && !f.closest(NOT_FORM) &&
      [f, f.parentElement, f.parentElement && f.parentElement.parentElement].some(e => e && shown(e)));
    return {kind, fields: fields.length, passwords: fields.filter(e => e.type === 'password').length, text: head.slice(0, 300), bare, puzzle, upload};
    """#

    /// A popup over the form offering to fill it from the resume (Infosys's "Extracting information from the Resume…
    /// If you prefer to … fill out the application fields, please close this popup window"). Tags its close button
    /// with data-auto-dialog-close and returns the button's name, or ''. Such popups also keep the keyboard to
    /// themselves, so lists that are searched by typing (select2) can't be used while one is open.
    static let tagResumeImportClose = prelude + formFieldCounter + #"""
    document.querySelectorAll('[data-auto-dialog-close]').forEach(e => e.removeAttribute('data-auto-dialog-close'));
    const ACT = '(extract\\w*|pars(e|es|ed|ing)|import\\w*|auto-?fill\\w*|auto fill\\w*)';
    const PARSE = new RegExp('\\b' + ACT + '\\b.{0,80}\\b(resume|résumé|cv)\\b|\\b(resume|résumé|cv)\\b.{0,80}\\b' + ACT + '\\b', 'i');
    const dialogs = [...document.querySelectorAll('[role=dialog], [aria-modal=true], .modal-dialog, .modal.show, .modal.in')]
      .filter(d => shown(d) && !d.closest(NOT_FORM) && PARSE.test(clean(d.innerText || '').slice(0, 1500)) && formFields(d).length === 0);
    const name = b => clean(b.getAttribute('aria-label') || b.innerText || b.value || b.title || '');
    for (const d of dialogs) {
      const btns = [...d.querySelectorAll('button, a, [role=button], [data-dismiss], [data-bs-dismiss]')];
      const close = btns.find(b => /^(close|×|✕|x|dismiss|no,? thanks|skip|cancel|fill (it )?in manually|enter (it )?manually|i'?ll fill (it )?(in|out) myself)$/i.test(name(b)))
        || btns.find(b => b.matches('[data-dismiss=modal], [data-bs-dismiss=modal], .close, .btn-close'));
      if (close) { close.setAttribute('data-auto-dialog-close', '1'); return name(close) || 'Close'; }
    }
    return '';
    """#

    /// An "I'm not a robot" box (reCAPTCHA or hCaptcha), which only a person may tick. The invisible kind doesn't count.
    static let robotBox = prelude + #"""
    return [...document.querySelectorAll('iframe')].some(f => shown(f) &&
      /recaptcha\/(api2|enterprise)\/anchor|hcaptcha\.com\/.*frame=checkbox/i.test(f.src || '') && !/size=invisible/i.test(f.src || ''));
    """#

    /// Finds a cookie or privacy banner and tags the button that closes it with data-auto-banner: the one that
    /// declines optional cookies if there is one, else a close button, else the only way to dismiss it (OK, Accept).
    /// Returns the button's name, or '' when there's no banner.
    static let tagBannerButton = prelude + #"""
    document.querySelectorAll('[data-auto-banner]').forEach(e => e.removeAttribute('data-auto-banner'));
    const HINT = /cookie|consent|gdpr|privacy (message|preferences|settings|choices|notice)|tracking technolog|opt[- ]out of sharing/i;
    const KNOWN = '#onetrust-banner-sdk, #onetrust-consent-sdk, #CybotCookiebotDialog, #truste-consent-track, .truste_box_overlay, ' +
      '#didomi-notice, .osano-cm-dialog, .cc-window, [aria-label*=cookie i], [id*=cookie i], [class*=cookie i], [id*=consent i], ' +
      '[class*=consent i], [data-automation-id*=legalNotice i], [data-automation-id*=cookie i]';
    const REJECT = /^(reject( all)?( cookies)?|reject (all )?(non-essential|optional|additional|unnecessary) cookies|decline( all)?( optional)?( cookies)?|deny( all)?|refuse( all)?|disagree|(use )?(strictly )?necessary (cookies )?only|only (strictly )?necessary( cookies)?|accept (only )?(strictly )?(necessary|required|essential)( cookies)?( only)?|continue without accepting|no,? thanks)$/i;
    const CLOSE = /^(close|dismiss|close (banner|notice|this|cookie (banner|notice))|×|x)$/i;
    const ACCEPT = /^(ok|okay|got it|i understand|understood|accept|i accept|accept (all )?cookies|accept all|allow( all)?( cookies)?|agree|i agree|agree (and|&) close|continue)$/i;
    const FORMISH = 'input[type=text], input[type=email], input[type=tel], input[type=file], input:not([type]), select, textarea';
    const name = b => clean(b.innerText || b.value || b.getAttribute('aria-label') || b.getAttribute('title') || '');
    const looksLikeBanner = el => {
      if (!shown(el) || el.querySelector(FORMISH)) return false;
      const t = clean(el.innerText);
      if (!t || t.length > 3000 || !HINT.test(t + ' ' + (el.id || '') + ' ' + (el.className || ''))) return false;
      return true;
    };
    const boxes = new Set([...document.querySelectorAll(KNOWN)].filter(looksLikeBanner));
    for (const el of document.querySelectorAll('div, section, aside, dialog, [role=dialog], [role=alertdialog], [role=region]')) {
      const pos = getComputedStyle(el).position;
      if ((pos === 'fixed' || pos === 'sticky' || /^(dialog|alertdialog|region)$/.test(el.getAttribute('role') || '') || el.tagName === 'DIALOG') && looksLikeBanner(el)) boxes.add(el);
    }
    // The smallest box first: the banner itself rather than the page section around it.
    const ordered = [...boxes].sort((a, b) => clean(a.innerText).length - clean(b.innerText).length);
    for (const want of [REJECT, CLOSE, ACCEPT]) {
      for (const box of ordered) {
        const btn = [...box.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]')]
          .filter(b => shown(b) && !b.disabled).find(b => want.test(name(b)) && !(b.tagName === 'A' && /^https?:/.test(b.getAttribute('href') || '') && want !== CLOSE));
        if (btn) { btn.setAttribute('data-auto-banner', '1'); return name(btn) || 'close'; }
      }
    }
    return '';
    """#

    /// On a careers page without a form, the button or link that leads on to the application ("Apply now", "I'm
    /// applying for the first time", and with `anyButton`, "Proceed" after a privacy notice). Tags it with
    /// data-auto-entry and returns {name, href} (href only for a link to another page), or null.
    static let tagEntryButton = prelude + #"""
    document.querySelectorAll('[data-auto-entry]').forEach(e => e.removeAttribute('data-auto-entry'));
    const tiers = [
      /^(apply( now| online| here| today)?|apply (for|to) (this|the) (job|position|role)( online| now| here)?|apply on (the )?company('s)? (site|website)|easy apply|quick apply)$/i,
      /^(i'?m applying for the first time|applying for the first time|first time (here|applying|applicant|user)\??|new (user|candidate|applicant)s?|start( my| your| an| the)? application|begin( my| your)? application|apply manually|apply without (an )?account|apply as (a )?guest|continue as (a )?guest|i'?m interested)$/i,
      /^(proceed|continue|next|i agree|agree|accept and continue|agree and continue|i acknowledge|acknowledge|i understand)$/i,
      // A page that only offers sign-in choices and a way to make an account (Microsoft): make one.
      /^(create (an |a new |your |my )?account|sign up|register( now)?)$/i,
    ];
    // Words for screen readers and icons aren't part of a button's name: "Apply (opens in new window)", "Apply →".
    const bare = s => clean((s || '').replace(/[(\[]?\s*(this link )?opens? in (a )?new (window|tab)\s*[)\]]?/ig, ' ')
      .replace(/\b(external link|new window)\b/ig, ' ').replace(/[→›»↗➔⟶]/g, ' '));
    const name = b => bare(b.getAttribute('aria-label') || b.innerText || b.value || '');
    const visibleText = b => bare(b.innerText || b.value || '');
    // A link straight to a job on an application site (Workday, Greenhouse, iCIMS…), whatever its words say.
    const ATS = /(myworkdayjobs\.com|myworkdaysite\.com|greenhouse\.io|lever\.co|ashbyhq\.com|icims\.com|smartrecruiters\.com|taleo\.net|successfactors\.(com|eu)|oraclecloud\.com\/hcmUI|avature\.net|jobvite\.com|workable\.com|eightfold\.ai|applytojob\.com|recruitee\.com|bamboohr\.com|paylocity\.com)/i;
    const atsLink = b => b.tagName === 'A' && ATS.test(b.href || '') && /(\/job\/|\/jobs\/\d|apply|requisition|jobid=|job_id=)/i.test(b.href || '') && !ATS.test(location.host);
    // The button that sends a form with a file upload is that form's Submit ("APPLY" under a resume box), not a way in.
    const sendsForm = b => b.tagName !== 'A' && !!(b.form || b.closest('form')) && !!(b.form || b.closest('form')).querySelector('input[type=file]');
    const cands = [...document.querySelectorAll('a, button, [role=button], input[type=submit], input[type=button]')]
      .filter(b => shown(b) && !b.disabled && b.getAttribute('aria-disabled') !== 'true' && !social(b) && !sendsForm(b) &&
              !b.closest('nav, footer, [id*=cookie i], [class*=cookie i], #onetrust-consent-sdk, [data-auto-banner]'));
    // A button the site itself calls Apply, whatever its words say (BrassRing's "Submit" is #applyFromDetailBtn).
    const APPLY_ID = /(^|[^a-z])apply([^a-z]|btn|button|from|now|job|online|$)/i;
    const idApply = b => b.tagName !== 'A' && visibleText(b).length <= 30 &&
      !/save|share|e-?mail|refer|alert|later|sign ?in|log ?in|sign ?up|register|linkedin|indeed/i.test(visibleText(b)) &&
      APPLY_ID.test([b.id, b.getAttribute('data-automation-id'), b.getAttribute('data-ph-at-id'), b.getAttribute('ng-click')].join(' '));
    const rounds = [tiers[0], 'ats', tiers[1], 'id'].concat(anyButton ? [tiers[2], tiers[3]] : []);
    for (const re of rounds) {
      let hit = re === 'ats' ? cands.filter(b => atsLink(b) && !b.closest('header'))
        : re === 'id' ? cands.filter(idApply)
        : cands.filter(b => (re.test(visibleText(b)) || re.test(name(b))) && !(re === tiers[3] && b.closest('header')));
      // Links to several jobs are a list of other jobs, not this one's application.
      if (re === 'ats' && new Set(hit.map(b => b.href.split(/[?#]/)[0])).size !== 1) hit = [];
      if (!hit.length) continue;
      const b = hit.find(x => !x.closest('header')) || hit[0];
      b.setAttribute('data-auto-entry', '1');
      const href = b.tagName === 'A' ? (b.href || '') : '';
      const sameDoc = !href || /^(javascript:|#)/i.test(b.getAttribute('href') || '#') || href.split('#')[0] === location.href.split('#')[0];
      return {name: (re === 'ats' ? '' : visibleText(b) || name(b)) || ('the link to ' + new URL(href).host), href: sameDoc ? '' : href};
    }
    return null;
    """#

    /// For a sign-in or sign-up box: tags the password box's form (data-auto-account), its user name box
    /// (data-auto-user) and its button (data-auto-account-btn), and says which it is: 'register' (create an account)
    /// or 'login'. Returns null without a visible password box.
    static let tagAccountForm = prelude + formFieldCounter + #"""
    ['data-auto-account', 'data-auto-user', 'data-auto-account-btn'].forEach(a => document.querySelectorAll('[' + a + ']').forEach(e => e.removeAttribute(a)));
    const pws = formFields(document).filter(e => e.type === 'password');
    if (!pws.length) return null;
    const pw = pws[0];
    // The box around the password: its form, or the nearest ancestor that also holds a button.
    let box = pw.form;
    if (!box) { box = pw.parentElement; while (box && box !== document.body && !box.querySelector('button, input[type=submit], [role=button]')) box = box.parentElement; }
    box = box || document.body;
    box.setAttribute('data-auto-account', '1');
    const inBox = formFields(document).filter(e => box.contains(e));
    const user = inBox.find(e => e.type === 'email') || inBox.filter(e => e.type !== 'password' && e.type !== 'checkbox' && e.type !== 'radio' && e.tagName === 'INPUT' &&
      (pw.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_PRECEDING)).pop();
    if (user) user.setAttribute('data-auto-user', '1');
    const btns = [...box.querySelectorAll('button, input[type=submit], [role=button], a')].filter(b => shown(b) && !b.disabled && !social(b));
    const label = b => clean(b.innerText || b.value || b.getAttribute('aria-label') || '');
    const LOGIN = /^(log ?in|sign ?in|login|signin|continue|next|submit)( to your account)?$/i;
    const REGISTER = /^(create( an| my)? (account|profile)|register|sign ?up|join( now)?|get started|start( my)? application|continue|next|submit|create)$/i;
    const confirm = pws.length >= 2 || [...box.querySelectorAll('label')].some(l => /confirm|re-?type|re-?enter|verify|repeat|confirmation/i.test(clean(l.innerText)) && /password/i.test(clean(l.innerText)));
    const regBtn = btns.find(b => /^(create|register|sign ?up|join|get started|start)/i.test(label(b)));
    const loginBtn = btns.find(b => /^(log ?in|sign ?in|login|signin)$/i.test(label(b)));
    const kind = confirm || (regBtn && !loginBtn) ? 'register' : 'login';
    const btn = kind === 'register' ? (regBtn || btns.find(b => REGISTER.test(label(b))) || btns.find(b => b.type === 'submit'))
                                    : (loginBtn || btns.find(b => LOGIN.test(label(b))) || btns.find(b => b.type === 'submit'));
    if (btn) btn.setAttribute('data-auto-account-btn', '1');
    // A resume upload offered to first-time visitors outside the sign-in box (e.g. Avature's "First time here?").
    const upload = [...document.querySelectorAll('input[type=file]')].find(f => !box.contains(f) &&
      /resume|résumé|\bcv\b|my computer|upload/i.test(((f.labels && f.labels[0] && f.labels[0].innerText) || '') + ' ' + f.name + ' ' + f.id + ' ' + (f.getAttribute('aria-label') || '')));
    if (upload) upload.setAttribute('data-auto-firsttime-upload', '1');
    return {kind, passwords: pws.length, button: btn ? label(btn) : '', user: !!user, upload: !!upload};
    """#

    /// Fills every visible, empty password box (a new account's password and its confirmation) with `value`.
    static let fillPasswords = prelude + formFieldCounter + #"""
    let n = 0;
    for (const el of formFields(document).filter(e => e.type === 'password' && !e.value)) {
      el.focus();
      const desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
      desc.set.call(el, value);
      el.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: value}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      el.blur();
      n++;
    }
    return n;
    """#

    /// When no Next or Submit button has a known name: the form's own submit button, or the one primary-looking
    /// button near the fields, tagged with data-auto-btn. Returns its name or null.
    /// A popup over the form that wants something first (Dayforce's privacy statement, with a box to tick and its own
    /// Save): tags it `data-auto-modal` and returns its heading, or ''. Not a cookie or chat popup, an offer to join a
    /// mailing list, or one with a file box (a resume popup is handled with the resume).
    static let tagBlockingDialog = prelude + #"""
    document.querySelectorAll('[data-auto-modal]').forEach(d => d.removeAttribute('data-auto-modal'));
    const NOT = '[id*=cookie i], [class*=cookie i], #onetrust-consent-sdk, [id*=consent-sdk i], [id*=chat i], [class*=chat i]';
    const OFFER = /subscribe|newsletter|job alerts?|talent (community|network)|join our|stay (in touch|connected)|sign up for/i;
    const dialogs = [...document.querySelectorAll('[role=dialog][aria-modal=true], [role=alertdialog][aria-modal=true], dialog[open]')]
      .filter(d => shown(d) && !d.closest(NOT) && !(d.tagName === 'DIALOG' && !d.matches(':modal')));
    for (const d of dialogs.reverse()) {
      const boxes = [...d.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]), select, textarea, [role=combobox]')]
        .filter(c => shown(c) || ((c.type === 'checkbox' || c.type === 'radio') && shown(c.parentElement)));
      if (!boxes.length || d.querySelector('input[type=file]') || OFFER.test(text(d).slice(0, 600))) continue;
      // On top of the page, not a panel beside it.
      const r = d.getBoundingClientRect();
      const x = Math.min(Math.max(r.left + r.width / 2, 0), innerWidth - 1), y = Math.min(Math.max(r.top + Math.min(r.height, innerHeight) / 2, 0), innerHeight - 1);
      const top = document.elementFromPoint(x, y);
      if (top && !d.contains(top)) continue;
      d.setAttribute('data-auto-modal', '1');
      const h = d.querySelector('h1, h2, h3, [class*=title i]');
      const named = d.getAttribute('aria-labelledby') && document.getElementById(d.getAttribute('aria-labelledby').split(/\s+/)[0]);
      const first = e => e ? clean((e.innerText || e.textContent || '').split('\n').find(l => l.trim()) || '') : '';
      return (first(named) || first(h) || first(d)).slice(0, 80) || 'popup';
    }
    return '';
    """#

    static let tagPrimaryButton = prelude + #"""
    const root = rootSel ? document.querySelector(rootSel) : document.body;
    if (!root) return null;
    document.querySelectorAll('[data-auto-btn]').forEach(b => b.removeAttribute('data-auto-btn'));
    const BAD = /^(back|previous|cancel|close|save( (for|as) (later|draft))?|clear|reset|remove|delete|add( another)?|upload|browse|choose file|attach|edit|sign out|log ?out|search|skip|print|download|forgot|show|hide|help)\b/i;
    const name = b => clean(b.innerText || b.value || b.getAttribute('aria-label') || '');
    const ok = b => shown(b) && !b.disabled && b.getAttribute('aria-disabled') !== 'true' && name(b) && !BAD.test(name(b)) && !social(b) &&
      !b.closest('header, nav, footer, [id*=cookie i], [class*=cookie i], #onetrust-consent-sdk, [role=search]');
    const fields = [...root.querySelectorAll('[data-auto-id]')].filter(shown);
    const forms = new Set(fields.map(f => f.form).filter(Boolean));
    let cands = [];
    for (const f of forms) cands.push(...[...f.querySelectorAll('button[type=submit], button:not([type]), input[type=submit]')].filter(ok));
    if (!cands.length) cands = [...root.querySelectorAll('button, input[type=submit], [role=button]')].filter(ok)
      .filter(b => b.type === 'submit' || /primary|submit|next|continue|cta/i.test(b.className + ' ' + (b.getAttribute('data-automation-id') || '')));
    if (!cands.length) return null;
    const pick = cands[cands.length - 1];
    pick.setAttribute('data-auto-btn', '1');
    return name(pick);
    """#

    // MARK: LinkedIn

    /// What marks a job in LinkedIn's search results: the AI results page's cards, the signed-in list's cards, the public
    /// page's cards, or any link to a job (LinkedIn changes its markup now and then; a link to /jobs/view/ has stayed).
    static let jobCardSelector = "[componentkey^=\"job-card-component-ref-\"], [data-occludable-job-id], [data-job-id], " +
        "[data-entity-urn*=\"jobPosting:\"], main a[href*=\"/jobs/view/\"], main a[href*=\"currentJobId=\"]"

    /// Scrolls the job list so every card renders; returns how many cards there are.
    static let scrollJobList = "const SEL = '\(jobCardSelector)';\n" + #"""
    const first = document.querySelector(SEL);
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
    return document.querySelectorAll(SEL).length;
    """#

    /// The job cards on a search page, whichever markup LinkedIn uses: the AI results page (componentkey
    /// job-card-component-ref-<id>), the signed-in list (data-occludable-job-id), the public page (data-entity-urn), or
    /// plain links to /jobs/view/<id> or /jobs/view/<title>-<id>.
    static let jobCards = prelude + #"""
    const txt = (root, sels) => { for (const s of sels) { const e = root.querySelector(s); if (e && clean(e.innerText)) return dedupe(clean(e.innerText)); } return ''; };
    const idOf = s => { const m = (s || '').match(/\/jobs\/view\/(?:[^\/?#]*-)?(\d{6,})(?=[\/?#]|$)|currentJobId=(\d{6,})|jobPosting:(\d{6,})/); return m ? (m[1] || m[2] || m[3]) : null; };
    const BOX = 'li, [data-occludable-job-id], [data-job-id], [data-entity-urn*="jobPosting:"], .base-card, .job-card-container, [role=listitem]';
    const NOISE = /^(promoted|promocionado|easy apply|solicitud sencilla|viewed|visto|actively (hiring|recruiting)|se busca personal|be an early applicant|adelántate a solicitar el empleo|\d+ (applicants?|solicitudes?)|.*\b(ago|hace)\b.*|new|nuevo)$/i;
    const APPLIED = /^(Applied|Solicitado|Postulado)\b/i;
    const out = []; const seen = new Set();
    // The AI results page: each card is a button keyed by the job's number (an inner box repeats the key); its first
    // paragraphs are the title (shown twice: for screen readers, with "(Verified job)", and on screen), company and place.
    for (const n of document.querySelectorAll('[componentkey^="job-card-component-ref-"]')) {
      const id = ((n.getAttribute('componentkey') || '').match(/(\d{6,})$/) || [])[1];
      if (!id || seen.has(id)) continue; seen.add(id);
      const ps = [...n.querySelectorAll('p')].map(p => {
        const span = p.querySelector('span[aria-hidden="true"]') || p;
        return dedupe(clean(span.textContent));
      });
      const title = (ps[0] || '').replace(/\s*\((Verified job|Empleo verificado)\)$/i, '');
      const company = ps[1] || '', location = ps[2] || '';
      out.push({job_id: id, title, company, location, applied: ps.slice(3).some(l => APPLIED.test(l))});
    }
    const nodes = [];
    for (const n of document.querySelectorAll('[data-occludable-job-id], [data-job-id], [data-entity-urn*="jobPosting:"]')) nodes.push(n);
    // Plain links only when LinkedIn's card markup is missing, so "similar jobs" next to a result aren't picked up.
    if (!nodes.length && !out.length) for (const a of document.querySelectorAll('main a[href*="/jobs/view/"], main a[href*="currentJobId="]')) nodes.push(a.closest(BOX) || a);
    for (const n of nodes) {
      const link = n.matches('a') ? n : n.querySelector('a[href*="/jobs/view/"], a[href*="currentJobId="]');
      let id = n.getAttribute('data-occludable-job-id') || n.getAttribute('data-job-id');
      if (!id || !/^\d+$/.test(id)) id = idOf(n.getAttribute('data-entity-urn')) || (link && idOf(link.getAttribute('href')));
      if (!id || seen.has(id)) continue; seen.add(id);
      const raw = clean(n.innerText).length ? (n.innerText || '').split('\n').map(l => dedupe(clean(l))).filter(Boolean) : [];
      const lines = raw.filter(l => !NOISE.test(l)).filter((l, i, a) => i === 0 || l !== a[i - 1]);
      let title = link && link.getAttribute('aria-label') ? dedupe(clean(link.getAttribute('aria-label'))) :
        txt(n, ['.base-search-card__title', '.job-card-list__title', '.job-card-container__link', 'strong']);
      if (!title && link) title = dedupe(clean(link.innerText));
      title = (title || lines[0] || '').replace(/ with verification$/i, '').replace(/ con verificación$/i, '');
      const rest = lines.filter(l => l !== title);
      const company = txt(n, ['.artdeco-entity-lockup__subtitle', '.base-search-card__subtitle', '.job-card-container__primary-description', '.job-card-container__company-name']) || rest[0] || '';
      const location = txt(n, ['.artdeco-entity-lockup__caption', '.job-search-card__location', '.job-card-container__metadata-wrapper', '.job-card-container__metadata-item']) || rest.filter(l => l !== company)[0] || '';
      // "Applied" as its own line, not inside a title or company ("Applied Scientist", "Applied Materials").
      const applied = raw.some(l => APPLIED.test(l) && l !== title && l !== company && l !== location);
      out.push({job_id: id, title, company, location, applied});
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
    // The job's own button: its name starts with the action and it's short. Suggested jobs further down are links
    // whose text ends in "Easy Apply", and filter links lead back to a search.
    const own = b => clean(b.innerText).length <= 40 && !(b.tagName === 'A' && /linkedin\.com\/(jobs\/(search|collections|view)|search)/.test(b.href || '') && !/\/apply\b|openSDUIApplyFlow/i.test(b.href || ''));
    const buttons = [...main.querySelectorAll('button, a, [role=button]')].filter(shown).filter(own);
    const easy = buttons.find(b => /^(easy apply|solicitud sencilla)\b/i.test(name(b)));
    if (easy) { easy.setAttribute('data-auto-apply', '1'); return {kind: 'easy_apply', description}; }
    const ext = buttons.find(b => /^(apply|solicitar)\b/i.test(name(b)));
    if (ext) { ext.setAttribute('data-auto-apply', '1'); return {kind: 'external', description, href: ext.href || ''}; }
    const top = (main.innerText || '').slice(0, 3000);
    if (/\bApplied\b.{0,40}\bago\b|Application submitted|\bSolicitado hace\b|Solicitud enviada/.test(top)) return {kind: 'applied', description};
    if (/No longer accepting applications|Ya no se aceptan solicitudes/i.test(top)) return {kind: 'closed', description};
    return {kind: 'unknown', description};
    """#

    /// Finds the Easy Apply window and tags it data-auto-root="easy-apply"; returns how far along it is ('' when it
    /// doesn't say), or null when there's no window. The window is a dialog, or (LinkedIn's newer one) whatever holds
    /// the "Apply to <company>" heading and the form.
    static let tagEasyApplyModal = prelude + #"""
    document.querySelectorAll('[data-auto-root="easy-apply"]').forEach(e => e.removeAttribute('data-auto-root'));
    const APPLY = /apply to|easy apply|contact info|solicitar en|solicitud sencilla|información de contacto/i;
    let m = document.querySelector('.jobs-easy-apply-modal') ||
            document.querySelectorAll('[role=dialog], dialog[open], [aria-modal="true"]').find(d => shown(d) && APPLY.test(d.innerText));
    if (!m) {
      const h = document.querySelectorAll('h1, h2, h3, [role=heading]').find(e => shown(e) && /^(apply to|solicitar en|postularse en)\b/i.test(clean(e.innerText)));
      for (let p = h && h.parentElement, i = 0; p && i < 10 && !m; p = p.parentElement, i++) {
        if (p.querySelector('input, select, textarea') && p.querySelector('button')) m = p;
      }
    }
    if (!m) return null;
    m.setAttribute('data-auto-root', 'easy-apply');
    const bar = m.querySelector('[role=progressbar], progress, .artdeco-completeness-meter-linear__progress-element');
    if (bar && (bar.getAttribute('aria-valuenow') || bar.getAttribute('value'))) return bar.getAttribute('aria-valuenow') || bar.getAttribute('value');
    const pages = (m.innerText || '').match(/(\d+)\s*\/\s*(\d+)\s*(pages?|páginas?)/i);
    return pages ? pages[1] + '/' + pages[2] : '';
    """#

    static let easyApplyResumeSelected = #"""
    const root = document.querySelector('[data-auto-root="easy-apply"]');
    if (!root) return false;
    return !!root.querySelector('.jobs-document-upload-redesign-card__container--selected, ' +
      '[class*="document-upload"][aria-checked="true"], [class*="resume"] [aria-checked="true"], ' +
      '[class*="document-upload"] input[type=radio]:checked');
    """#

    /// LinkedIn's AI results page pages with buttons rather than by address: the page its pager shows (1 when there's no
    /// pager), or -1 on the other layouts.
    static let resultsPage = #"""
    if (!document.querySelector('[componentkey^="job-card-component-ref-"]')) return -1;
    const cur = document.querySelector('[data-testid="pagination-controls-list"] [aria-current="true"]');
    const n = cur ? parseInt((cur.getAttribute('aria-label') || cur.textContent || '').replace(/\D+/g, ''), 10) : 1;
    return n > 0 ? n : 1;
    """#

    /// The job number of the first card on the AI results page ('' when there's none), to tell when the list changes.
    static let firstResult = #"""
    const n = document.querySelector('[componentkey^="job-card-component-ref-"]');
    return n ? ((n.getAttribute('componentkey') || '').match(/(\d+)$/) || ['', ''])[1] : '';
    """#

    /// Tags the AI results pager's button toward `page` with data-auto-page: that page's own button, else Next. False
    /// when neither is there (the last page).
    static let tagPagerButton = #"""
    document.querySelectorAll('[data-auto-page]').forEach(e => e.removeAttribute('data-auto-page'));
    const list = document.querySelector('[data-testid="pagination-controls-list"]');
    const b = (list && list.querySelector('button[aria-label="Page ' + page + '"]')) ||
      document.querySelector('button[data-testid^="pagination-controls-next-button"]:not([data-testid$="hidden"])');
    if (!b || b.disabled || b.getAttribute('aria-disabled') === 'true') return false;
    b.setAttribute('data-auto-page', '1');
    return true;
    """#

    /// LinkedIn's number for a place, from the lookup behind its location box (first match; '' when there's none).
    static let linkedInPlace = #"""
    const u = '/jobs-guest/api/typeaheadHits?origin=jserp&typeaheadType=GEO&geoTypes=POPULATED_PLACE,ADMIN_DIVISION_2,MARKET_AREA,COUNTRY_REGION&query=' + encodeURIComponent(query);
    try {
      const r = await fetch(u, {credentials: 'include', headers: {accept: 'application/json'}});
      if (!r.ok) return '';
      const hits = await r.json();
      const id = Array.isArray(hits) && hits.length ? String(hits[0].id || '') : '';
      return /^\d+$/.test(id) ? id : '';
    } catch (e) { return ''; }
    """#

    /// LinkedIn is showing its signed-out version: the login or sign-up wall, or the public pages it shows visitors.
    static let linkedInSignedOutPage = #"""
    if (!/linkedin\.com$/.test(location.hostname)) return false;
    if (/\/(login|authwall|checkpoint|uas|signup)\b/.test(location.pathname)) return true;
    return !!document.querySelector('[data-tracking-control-name^="public_jobs"], a.nav__button-secondary[href*="/login"]');
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
