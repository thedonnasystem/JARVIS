// Functions that run INSIDE the page (page.evaluate). Each must be fully self-contained: no imports, no closures over module scope.

export function discoverNav({ selectors, origin }) {
  const vis = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const seen = new Set(); const out = [];
  document.querySelectorAll(selectors).forEach((el, i) => {
    if (!vis(el)) return;
    if (el.tagName === 'A') { const href = el.getAttribute('href') || ''; if (/^(mailto|tel|sms|javascript):/i.test(href)) return; try { const u = new URL(href, location.href); if (u.origin !== origin) return; } catch (e) { return; } }
    const label = (el.getAttribute('aria-label') || el.innerText || el.textContent || el.id || '').trim().replace(/\s+/g, ' ').slice(0, 60);
    const key = (el.id ? '#' + el.id : '') + '|' + label + '|' + (el.getAttribute('href') || '');
    if (seen.has(key)) return; seen.add(key);
    const tag = 'qa-nav-' + i; el.setAttribute('data-qa-nav', tag);
    out.push({ key, label: label || '(unnamed ' + el.tagName.toLowerCase() + ')', tag, selected: el.classList.contains('on') || el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-current') != null });
  });
  return out;
}

export function evalA11y({ tapFail, tapWarn, contrastFail, contrastWarn, maxSamples, checkTap }) {
  const issues = [];
  const vis = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const desc = (el) => el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\s+/).join('.') : '') + ' "' + (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().replace(/\s+/g, ' ').slice(0, 30) + '"';
  const nameOf = (el) => {
    const al = el.getAttribute('aria-label'); if (al && al.trim()) return al.trim();
    const lb = el.getAttribute('aria-labelledby'); if (lb) { const t = lb.split(/\s+/).map((i) => (document.getElementById(i) || {}).textContent || '').join(' ').trim(); if (t) return t; }
    if (el.labels && el.labels.length) { const t = [...el.labels].map((l) => l.textContent).join(' ').trim(); if (t) return t; }
    if (el.closest('label') && el.closest('label').textContent.trim()) return el.closest('label').textContent.trim();
    if (el.tagName === 'IMG') return el.getAttribute('alt') || '';
    if (el.tagName === 'INPUT' && /^(button|submit|reset)$/.test(el.type)) return el.value || '';
    const t = (el.innerText || el.textContent || '').trim(); if (t) return t;
    return el.getAttribute('title') || '';
  };
  // 1. accessible names
  document.querySelectorAll('button, a[href], [role=button], input:not([type=hidden]), select, textarea, summary').forEach((el) => {
    if (!vis(el)) return;
    if (!nameOf(el)) {
      const ph = el.getAttribute('placeholder');
      if (ph && /^(INPUT|TEXTAREA)$/.test(el.tagName)) issues.push({ rule: 'name-placeholder-only', severity: 'warn', node: desc(el) });
      else issues.push({ rule: 'name-missing', severity: 'fail', node: desc(el) });
    }
  });
  document.querySelectorAll('img').forEach((el) => { if (vis(el) && !el.hasAttribute('alt')) issues.push({ rule: 'img-alt-missing', severity: 'fail', node: desc(el) }); });
  // 2. tap targets (phone only)
  if (checkTap) {
    document.querySelectorAll('button, a[href], [role=button], input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea, summary, [onclick]').forEach((el) => {
      if (!vis(el)) return; const r = el.getBoundingClientRect(); const m = Math.min(r.width, r.height);
      if (m < tapFail) issues.push({ rule: 'tap-target-small', severity: 'fail', node: desc(el) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) });
      else if (m < tapWarn) issues.push({ rule: 'tap-target-below-44', severity: 'warn', node: desc(el) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) });
    });
    document.querySelectorAll('input[type=checkbox], input[type=radio]').forEach((el) => {
      if (!vis(el)) return; const host = el.closest('label') || el; const r = host.getBoundingClientRect(); const m = Math.min(r.width, r.height);
      if (m < tapWarn) issues.push({ rule: m < tapFail ? 'tap-target-small' : 'tap-target-below-44', severity: m < tapFail ? 'fail' : 'warn', node: desc(el) + ' (label box) ' + Math.round(r.width) + 'x' + Math.round(r.height) });
    });
  }
  // 3. contrast (simple: solid backgrounds only; gradients/images skipped and counted)
  const cv = document.createElement('canvas'); cv.width = cv.height = 1; const cx = cv.getContext('2d', { willReadFrequently: true });
  const cache = new Map();
  const rgba = (c) => { if (cache.has(c)) return cache.get(c); cx.clearRect(0, 0, 1, 1); cx.fillStyle = '#000'; cx.fillStyle = c; cx.fillRect(0, 0, 1, 1); const d = cx.getImageData(0, 0, 1, 1).data; const a = d[3] / 255; const v = a ? [d[0] * 255 / d[3], d[1] * 255 / d[3], d[2] * 255 / d[3], a] : [0, 0, 0, 0]; cache.set(c, v); return v; };
  const lum = ([r, g, b]) => { const f = (x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4); }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
  const bgOf = (el) => { let layers = []; let n = el; let skipped = false;
    while (n && n.nodeType === 1) { const cs = getComputedStyle(n); if (cs.backgroundImage && cs.backgroundImage !== 'none') { skipped = true; break; } const c = rgba(cs.backgroundColor); if (c[3] > 0) { layers.push(c); if (c[3] >= 1) break; } n = n.parentElement; }
    if (skipped) return null; let base = [255, 255, 255]; if (!layers.length || layers[layers.length - 1][3] < 1) { const rb = rgba(getComputedStyle(document.documentElement).backgroundColor); base = rb[3] > 0 ? rb : [255, 255, 255]; }
    for (let i = layers.length - 1; i >= 0; i--) { const [r, g, b, a] = layers[i]; base = [r * a + base[0] * (1 - a), g * a + base[1] * (1 - a), b * a + base[2] * (1 - a)]; } return base; };
  let sampled = 0, skippedBg = 0; const reported = new Set();
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
  while (walker.nextNode() && sampled < maxSamples) {
    const el = walker.currentNode; if (!/^(P|SPAN|DIV|A|BUTTON|LI|H1|H2|H3|H4|LABEL|B|SUMMARY|TD|TH|INPUT|TEXTAREA)$/.test(el.tagName)) continue;
    const own = [...el.childNodes].some((c) => c.nodeType === 3 && c.textContent.trim()) || (/^(INPUT|TEXTAREA)$/.test(el.tagName) && (el.value || el.placeholder));
    if (!own || !vis(el)) continue; sampled++;
    const cs = getComputedStyle(el); const fg = rgba(cs.color); const bg = bgOf(el); if (!bg) { skippedBg++; continue; }
    const f = [fg[0] * fg[3] + bg[0] * (1 - fg[3]), fg[1] * fg[3] + bg[1] * (1 - fg[3]), fg[2] * fg[3] + bg[2] * (1 - fg[3])];
    const l1 = lum(f), l2 = lum(bg); const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    const px = parseFloat(cs.fontSize); const large = px >= 24 || (px >= 18.66 && parseInt(cs.fontWeight, 10) >= 700); const need = large ? 3 : contrastWarn;
    if (ratio < contrastFail) { const k = 'f' + cs.color + bg.join(','); if (!reported.has(k)) { reported.add(k); issues.push({ rule: 'contrast-very-low', severity: 'fail', node: desc(el) + ' ratio ' + ratio.toFixed(2) }); } }
    else if (ratio < need) { const k = 'w' + cs.color + bg.join(','); if (!reported.has(k)) { reported.add(k); issues.push({ rule: 'contrast-below-aa', severity: 'warn', node: desc(el) + ' ratio ' + ratio.toFixed(2) + (large ? ' (large)' : '') }); } }
  }
  return { issues, contrastSampled: sampled, contrastSkippedBackground: skippedBg };
}

export function evalDocument() {
  const out = [];
  const lang = document.documentElement.getAttribute('lang'); out.push({ rule: 'html-lang', ok: !!lang, detail: lang || 'missing' });
  out.push({ rule: 'title', ok: !!document.title.trim(), detail: document.title || 'missing' });
  out.push({ rule: 'viewport-meta', ok: !!document.querySelector('meta[name=viewport]'), detail: '' });
  out.push({ rule: 'landmark-main', ok: !!document.querySelector('main, [role=main]'), detail: '' });
  out.push({ rule: 'landmark-nav', ok: !!document.querySelector('nav, [role=navigation]'), detail: '' });
  out.push({ rule: 'landmark-header', ok: !!document.querySelector('header, [role=banner]'), detail: '' });
  out.push({ rule: 'h1-or-heading', ok: !!document.querySelector('h1, h2, [role=heading]'), detail: '' });
  return out;
}

export function evalOverflow() {
  const de = document.documentElement; const w = window.innerWidth;
  const doc = Math.max(de.scrollWidth, document.body ? document.body.scrollWidth : 0);
  const offenders = [];
  if (doc > w + 1) {
    const clipped = (el) => { for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) { const o = getComputedStyle(n).overflowX; if (o === 'auto' || o === 'scroll' || o === 'hidden') return true; } return false; };
    document.querySelectorAll('body *').forEach((el) => { const r = el.getBoundingClientRect(); if (r.width > 0 && (r.right > w + 1 || r.left < -1) && getComputedStyle(el).display !== 'none' && !clipped(el) && offenders.length < 8) offenders.push(el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\s+/)[0] : '') + ' right=' + Math.round(r.right)); });
  }
  return { overflow: doc > w + 1, scrollWidth: doc, innerWidth: w, offenders };
}

export function evalBadges({ screenSel, panelSel, badgeRe, attrSel, screenScopeSel, numericRe, ageRe }) {
  const re = new RegExp(badgeRe); const num = new RegExp(numericRe); const age = new RegExp(ageRe, 'gi');
  const vis = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const roots = [...document.querySelectorAll(screenSel)].filter(vis);
  const rootList = roots.length ? roots : [document.querySelector('main') || document.body];
  const label = (el) => (el.querySelector('h1,h2,h3,b,summary') || el).textContent.trim().replace(/\s+/g, ' ').slice(0, 50) || (el.id || el.tagName.toLowerCase());
  const hasBadge = (el) => re.test(el.innerText || '') || !!el.querySelector(attrSel);
  const panels = [];
  rootList.forEach((root) => {
    const screenBadge = !!root.querySelector(screenScopeSel);
    let cards = [...root.querySelectorAll(panelSel)].filter(vis);
    cards = cards.filter((c) => !c.querySelector(panelSel));   // leaf panels only
    if (!cards.length) cards = [root];
    // text that is outside any panel but inside the screen root also counts as a panel ("loose" content)
    cards.forEach((c) => {
      const text = (c.innerText || '').replace(age, ' ');
      const numeric = num.test(text); if (!numeric) return;
      let covered = hasBadge(c); let how = covered ? 'in-panel' : '';
      if (!covered) { let p = c.parentElement; while (p && root.contains(p) && p !== root) { if (p.matches(panelSel) && hasBadge(p)) { covered = true; how = 'ancestor-panel'; break; } p = p.parentElement; } }
      if (!covered && screenBadge) { covered = true; how = 'screen-scope'; }
      panels.push({ label: label(c), covered, how, sample: text.trim().replace(/\s+/g, ' ').slice(0, 60) });
    });
    // loose numeric content directly in the screen (not inside any panel)
    if (cards[0] !== root) {
      const clone = root.cloneNode(true); clone.querySelectorAll(panelSel).forEach((n) => n.remove());
      const loose = (clone.textContent || '').replace(age, ' ');
      if (num.test(loose) && loose.replace(/\s+/g, '').length > 0) { const covered = re.test(clone.textContent) || !!clone.querySelector(attrSel) || screenBadge; panels.push({ label: '(loose content in ' + (root.id || 'screen') + ')', covered, how: covered ? 'in-screen' : '', sample: loose.trim().replace(/\s+/g, ' ').slice(0, 60) }); }
    }
  });
  return { panels, screens: rootList.map((r) => r.id || r.tagName.toLowerCase()) };
}

export function evalControls({ denyRe }) {
  const re = new RegExp(denyRe, 'i'); const hits = []; const seen = new Set();
  document.querySelectorAll('button, a, input, select, textarea, summary, [role=button], [role=switch], [onclick], form').forEach((el) => {
    const text = [(el.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 80), el.value && el.tagName !== 'TEXTAREA' ? el.value : '', el.getAttribute('aria-label'), el.getAttribute('placeholder'), el.getAttribute('name'), el.id, el.getAttribute('title'), el.getAttribute('data-action')].filter(Boolean).join(' | ');
    if (re.test(text) && !seen.has(text)) { seen.add(text); const r = el.getBoundingClientRect(); hits.push({ control: el.tagName.toLowerCase() + (el.id ? '#' + el.id : ''), text: text.slice(0, 120), visibleNow: r.width > 0 && r.height > 0 }); }
  });
  return hits;
}

export function evalXss() {
  const sinks = [];
  document.querySelectorAll('[onerror], [onload], [onclick], [onmouseover], [onfocus]').forEach((el) => { for (const a of el.attributes) if (/^on/.test(a.name) && /__xss/.test(a.value)) sinks.push(el.tagName.toLowerCase() + '[' + a.name + ']'); });
  document.querySelectorAll('script').forEach((s) => { if (/__xss/.test(s.textContent)) sinks.push('script(inline)'); });
  document.querySelectorAll('a[href^="javascript:"]').forEach((a) => { if (/__xss/.test(a.getAttribute('href'))) sinks.push('a[href=javascript:]'); });
  const text = document.body.innerText || '';
  return { fired: window.__xss || 0, injectedNodes: sinks, literalVisible: /<img src=x|<script>window\.__xss|"><svg onload/.test(text) };
}

// Visible text that is really a rendering bug: a literal null/undefined/NaN/[object Object] shown to the user.
export function evalLeaks() {
  const out = []; const re = /(^|[^\w])(null|undefined|NaN|Infinity)([^\w]|$)|\[object Object\]/;
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (w.nextNode()) {
    const n = w.currentNode; const el = n.parentElement; if (!el || /^(SCRIPT|STYLE|NOSCRIPT)$/.test(el.tagName)) continue;
    if (!re.test(n.data)) continue; const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
    if (r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none') out.push((el.id ? '#' + el.id + ' ' : el.tagName.toLowerCase() + ' ') + JSON.stringify(n.data.trim().slice(0, 50)) + ' in ' + (el.closest('section,main,div') || el).tagName.toLowerCase() + ((el.closest('[id]') || {}).id ? '#' + el.closest('[id]').id : ''));
  }
  return out;
}
