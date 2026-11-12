'use strict';
// Public by design: project URL + publishable key. All data access is through owner-checked app_* database functions.
const SB_URL = 'https://ihxzvpwbqydqtblvazbq.supabase.co';
const SB_KEY = 'sb_publishable_r9OWeA-XSdFMLKygoJM1Bg_Vr8D9aeZ';
const $ = (id) => document.getElementById(id);
const usd = (c) => '$' + ((Number(c) || 0) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const ago = (t) => { if (!t) return ''; const s = (Date.now() - new Date(t)) / 1000; return s < 90 ? 'now' : s < 5400 ? Math.round(s / 60) + 'm' : s < 129600 ? Math.round(s / 3600) + 'h' : Math.round(s / 86400) + 'd'; };
function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) { if (k === 'class') e.className = v; else if (k.startsWith('on')) e.addEventListener(k.slice(2), v); else if (v !== false && v != null) e.setAttribute(k, v); }
  for (const c of kids.flat()) if (c != null && c !== false) e.append(c.nodeType ? c : document.createTextNode(String(c)));
  return e;
}
const sb = window.supabase.createClient(SB_URL, SB_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false } });
const S = { snap: null, msgs: [], tab: 'chat', seen: new Set(), busy: false };
const TABS = [['chat', 'Jarvis'], ['home', 'Home'], ['missions', 'Missions'], ['agents', 'Agents'], ['money', 'Money'], ['feed', 'Feed']];

async function rpc(name, args) {
  const { data, error } = await sb.rpc(name, args || {});
  if (error) throw error;
  return data;
}
function note(msg) { const b = $('banner'); b.textContent = msg; b.hidden = !msg; }

// ---------- login (email code; owner check is enforced in the database) ----------
async function boot() {
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  const { data } = await sb.auth.getSession();
  if (data.session) return enter();
  $('login').hidden = false;
}
$('f-email').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = $('email').value.trim();
  $('login-msg').textContent = 'Sending…';
  const { error } = await sb.auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
  if (error) { $('login-msg').textContent = 'Could not send a code. Check the email is the owner email and that email login is enabled.'; return; }
  $('f-email').hidden = true; $('f-code').hidden = false; $('login-msg').textContent = 'Code sent. Check your email.';
});
$('f-code').addEventListener('submit', async (e) => {
  e.preventDefault();
  const { error } = await sb.auth.verifyOtp({ email: $('email').value.trim(), token: $('code').value.trim(), type: 'email' });
  if (error) { $('login-msg').textContent = 'That code did not work. Request a new one.'; return; }
  $('login').hidden = true; enter();
});

async function enter() {
  try { await rpc('app_snapshot'); } catch (e) {
    await sb.auth.signOut();
    $('login').hidden = false; $('f-email').hidden = false; $('f-code').hidden = true;
    $('login-msg').textContent = 'This account is not authorized for HQ.';
    return;
  }
  $('app').hidden = false;
  $('tabs').replaceChildren(...TABS.map(([k, t]) => h('button', { id: 't-' + k, onclick: () => show(k) }, t)));
  show(S.tab);
  await refresh();
  setInterval(refresh, 8000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
}
function show(k) {
  S.tab = k;
  document.querySelectorAll('.view').forEach((v) => v.classList.toggle('on', v.id === 'v-' + k));
  document.querySelectorAll('nav button').forEach((b) => b.classList.toggle('on', b.id === 't-' + k));
  render();
}

// ---------- data ----------
async function refresh() {
  try {
    const [snap, msgs] = await Promise.all([rpc('app_snapshot'), rpc('app_messages', { p_limit: 80 })]);
    S.snap = snap; note('');
    const fresh = msgs.filter((m) => m.role === 'jarvis' && m.kind === 'chat' && !S.seen.has(m.id));
    const first = S.msgs.length === 0;
    S.msgs = msgs;
    if (!first && $('speak').checked && fresh.length) speakText(fresh[fresh.length - 1].body);
    msgs.forEach((m) => S.seen.add(m.id));
    render();
  } catch (e) { note('Offline or signed out. Retrying…'); }
}
async function send(body, kind, payload) {
  try { const id = await rpc('app_send', { p_body: body || '', p_kind: kind || 'chat', p_payload: payload || {} }); setTimeout(refresh, 600); return id; }
  catch (e) { note(String(e.message || e)); return null; }
}
// Send an action and show Jarvis's one-line answer in the banner (he replies within seconds).
async function act(kind, payload) {
  note('Sent. Waiting for Jarvis…');
  const id = await send('', kind, payload); if (!id) return;
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 1500));
    try { const m = (await rpc('app_messages', { p_limit: 20 })).find((x) => x.reply_to === id); if (m) { note(m.body); setTimeout(() => note(''), 12000); refresh(); return; } } catch (e) {}
  }
  note('Still working. Check the Jarvis tab.');
}

// ---------- render ----------
function render() {
  const s = S.snap; if (!s) return;
  const st = s.state || {};
  const pill = $('pill');
  const paused = st.kill_switch || st.pause_reason;
  pill.className = 'pill ' + (st.kill_switch ? 'bad' : paused ? 'warn' : 'ok');
  pill.textContent = st.kill_switch ? 'KILL SWITCH ON' : paused ? 'Paused: ' + st.pause_reason : 'Running · ' + (st.mode || '').replace(/_/g, ' ');
  $('stamp').textContent = 'beat ' + ago(st.last_heartbeat);
  // Never rebuild a screen while the owner is typing into it (the 8s refresh would wipe the field).
  const ae = document.activeElement;
  if (S.tab !== 'chat' && ae && /^(INPUT|TEXTAREA)$/.test(ae.tagName) && $('v-' + S.tab).contains(ae)) return;
  ({ chat: rChat, home: rHome, missions: rMissions, agents: rAgents, money: rMoney, feed: rFeed })[S.tab](s);
}
function rChat() {
  const box = $('msgs'); const atEnd = box.parentElement.scrollHeight - box.parentElement.scrollTop - box.parentElement.clientHeight < 80;
  const items = S.msgs.filter((m) => m.kind === 'chat' || m.kind === 'system');
  box.replaceChildren(...(items.length ? items.map((m) => h('div', { class: 'm ' + m.role }, m.body)) : [h('p', { class: 'dim' }, 'Tell Jarvis what to do. Same brain as Telegram.')]));
  if (atEnd) $('views').scrollTop = $('views').scrollHeight;
}
function rHome(s) {
  const v = $('v-home'); const c = s.capital || {};
  const need = (s.needs_you || []).map((n) => h('div', { class: 'card' },
    h('div', { class: 'dim' }, n.kind + ' · ' + ago(n.created_at)), h('div', {}, n.body),
    n.needs_decision ? h('div', { class: 'btns' },
      h('button', { class: 'ok', onclick: () => send('', 'decision', { msg_id: n.id, approved: true }) }, 'Approve'),
      h('button', { class: 'bad', onclick: () => send('', 'decision', { msg_id: n.id, approved: false }) }, 'Reject')) : null,
    Array.isArray(n.options) && !n.needs_decision ? h('div', { class: 'btns' }, n.options.map((o, i) => h('button', { class: 'ghost', onclick: () => send('', 'answer', { msg_id: n.id, idx: i }) }, typeof o === 'string' ? o : (o.label || o.title || 'Option ' + (i + 1))))) : null));
  v.replaceChildren(
    h('div', { class: 'card' }, h('div', { class: 'dim' }, 'Operating fund'), h('div', { class: 'big' }, c.available_cents != null ? usd(c.available_cents) : '—'),
      h('div', { class: 'dim' }, (c.mode ? String(c.mode).toUpperCase() + ' · ' : '') + 'AI today ' + usd(s.spend_today_cents) + ' of ' + usd((s.state || {}).cap_cents))),
    h('h2', {}, 'Needs you'), ...(need.length ? need : [h('p', { class: 'dim' }, 'Nothing waiting on you.')]),
    h('h2', {}, 'Ventures'), ...(s.ventures || []).map((x) => h('div', { class: 'card' },
      h('div', { class: 'row' }, h('h3', {}, x.name), h('span', { class: 'tag' }, [x.status === 'proposed' ? 'awaiting approval' : (s.venture_stage || {})[x.slug], x.agents + ' agents', x.leads + ' leads'].filter(Boolean).join(' · '))),
      h('div', { class: 'dim' }, 'In ' + usd(x.in_cents) + ' · Out ' + usd(x.out_cents) + ' · Expected ' + usd(x.expected_cents) + ' (not cash) · AI 7d ' + usd(x.ai_cents_7d)))),
    h('h2', {}, 'Pipeline'), h('div', { class: 'card dim' },
      `Tasks: ${s.tasks.todo} todo, ${s.tasks.doing} doing, ${s.tasks.blocked} blocked, ${s.tasks.done_24h} done today. Leads: ${s.leads.total} (${s.leads.due} due). Drafts waiting: ${(s.drafts || []).length}.`),
    h('h2', {}, 'Systems'), ...(s.systems || []).map((x) => h('div', { class: 'row dim' }, h('span', {}, x.name), h('span', {}, x.status || '?'))),
    h('h2', {}, 'Notifications'), pushCard(),
    h('h2', {}, 'Emergency'), h('div', { class: 'btns' },
      h('button', { class: s.state.kill_switch ? 'ok' : 'bad', onclick: () => { if (confirm(s.state.kill_switch ? 'Turn the kill switch off?' : 'Stop everything now?')) rpc('app_set_kill', { p_on: !s.state.kill_switch }).then(refresh).catch((e) => note(e.message)); } }, s.state.kill_switch ? 'Kill switch OFF: resume' : 'KILL SWITCH')));
}
// ---------- web push (installed app, iOS 16.4+; the key and subscription never leave the owner-checked functions) ----------
const b64 = (t) => { const p = '='.repeat((4 - t.length % 4) % 4); const r = atob((t + p).replace(/-/g, '+').replace(/_/g, '/')); return Uint8Array.from([...r].map((c) => c.charCodeAt(0))); };
function pushCard() {
  const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone;
  const ok = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  const msg = h('div', { class: 'dim' }, !ok ? (standalone ? 'This browser does not support push.' : 'On iPhone: Share, Add to Home Screen, open from the icon, then turn this on.')
    : Notification.permission === 'granted' ? 'On. Decisions and emergencies reach you here and on Telegram.' : Notification.permission === 'denied' ? 'Blocked in system settings.' : 'Off.');
  const btn = ok && Notification.permission !== 'granted' && Notification.permission !== 'denied' ? h('div', { class: 'btns' }, h('button', { class: 'ghost', onclick: async () => {
    try {
      const perm = await Notification.requestPermission(); if (perm !== 'granted') { msg.textContent = 'Permission not given.'; return; }
      const key = await rpc('app_push_public_key'); if (!key) { msg.textContent = 'Push is not set up on the server yet.'; return; }
      const reg = await navigator.serviceWorker.ready;
      const sub = (await reg.pushManager.getSubscription()) || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64(key) });
      await rpc('app_save_push', { p_sub: sub.toJSON(), p_ua: navigator.userAgent });
      msg.textContent = 'On. Decisions and emergencies reach you here and on Telegram.';
    } catch (e) { msg.textContent = 'Could not turn on: ' + String(e.message || e); }
  } }, 'Turn on notifications')) : null;
  return h('div', { class: 'card' }, msg, btn);
}
// ---------- bank statement CSV (parsed here; only date, description, amount leave the phone; account numbers never do) ----------
function csvRows(text) {
  const rows = []; let row = [], cur = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"' && text[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') q = false; else cur += c; }
    else if (c === '"') q = true; else if (c === ',') { row.push(cur); cur = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cur); cur = ''; if (row.some((x) => x.trim())) rows.push(row); row = []; }
    else cur += c;
  }
  row.push(cur); if (row.some((x) => x.trim())) rows.push(row);
  return rows;
}
function parseDate(t) {
  t = (t || '').trim(); let m;
  if ((m = t.match(/^(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})$/))) return m[1] + '-' + m[2].padStart(2, '0') + '-' + m[3].padStart(2, '0');
  if ((m = t.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/))) { let a = +m[1], b = +m[2]; if (a > 12) [a, b] = [b, a]; return m[3] + '-' + String(a).padStart(2, '0') + '-' + String(b).padStart(2, '0'); }
  return null;
}
function toCents(t) { t = (t || '').replace(/[$,\s]/g, ''); if (!t) return null; const neg = /^\(.*\)$/.test(t); const v = Math.round(parseFloat(t.replace(/[()]/g, '')) * 100); return isNaN(v) ? null : (neg ? -v : v); }
function parseStatement(text) {
  const all = csvRows(text.replace(/^\ufeff/, '')); let hi = all.findIndex((r) => r.some((c) => /date/i.test(c)) && r.some((c) => /cad|amount|debit|credit/i.test(c)));
  if (hi < 0) return [];
  const H = all[hi].map((c) => c.trim().toLowerCase()); const col = (r, ...names) => { for (const n of names) { const i = H.findIndex((h) => h.includes(n)); if (i >= 0 && r[i] != null) return r[i]; } return ''; };
  const out = [];
  for (const r of all.slice(hi + 1)) {
    const d = parseDate(col(r, 'transaction date', 'date')); if (!d) continue;
    let c = toCents(col(r, 'cad$', 'amount'));
    if (c == null) { const deb = toCents(col(r, 'debit', 'withdraw')), cred = toCents(col(r, 'credit', 'deposit')); if (deb == null && cred == null) continue; c = (cred || 0) - Math.abs(deb || 0); }
    const desc = [col(r, 'description 1'), col(r, 'description 2')].map((x) => x.trim()).filter(Boolean).join(' ') || col(r, 'description').trim();
    out.push({ date: d, description: desc.replace(/\s+/g, ' ').slice(0, 200), cents: c });
  }
  return out.slice(0, 2000);
}
function bankCard(c) {
  const amt = h('input', { type: 'text', inputmode: 'decimal', placeholder: 'Bank balance, e.g. 412.50', style: 'width:100%;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px;margin:8px 0' });
  const file = h('input', { type: 'file', accept: '.csv,text/csv', style: 'display:none', onchange: async (e) => {
    const f = e.target.files[0]; if (!f) return; if (f.size > 1000000) { note('That file is too big for a statement.'); return; }
    const rows = parseStatement(await f.text()); if (!rows.length) { note('No transactions found in that file.'); return; }
    act('bank', { verb: 'rows', rows }); e.target.value = '';
  } });
  return h('div', {}, h('h2', {}, 'Bank (source of truth)'), h('div', { class: 'card' },
    h('div', { class: 'dim' }, c.bank_balance_cents != null ? 'Last recorded ' + usd(c.bank_balance_cents) + ', ' + c.bank_age_days + ' days ago. Spending is capped at what the bank supports.' : 'No balance recorded yet. Spending is limited by the internal ledger only.'),
    amt, h('div', { class: 'btns' },
      h('button', { onclick: () => { if (amt.value.trim()) { act('bank', { verb: 'balance', amount: amt.value.trim() }); amt.value = ''; } } }, 'Save balance'),
      h('button', { class: 'ghost', onclick: () => file.click() }, 'Import statement CSV'),
      h('button', { class: 'ghost', onclick: () => act('bank', { verb: 'reconcile' }) }, 'Reconcile')), file));
}
function rMissions(s) {
  const v = $('v-missions');
  const act = (id, verb) => send('', 'mission', { verb, id });
  const ta = h('textarea', { rows: 3, placeholder: 'New mission: what outcome do you want?', style: 'width:100%;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px' });
  const vn = h('input', { type: 'text', placeholder: 'New venture name', style: 'width:100%;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px;margin:8px 0' });
  const vi = h('textarea', { rows: 2, placeholder: 'What it sells, to whom, how it makes money', style: 'width:100%;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px' });
  v.replaceChildren(
    h('div', {}, ta, h('div', { class: 'btns' }, h('button', { onclick: () => { if (ta.value.trim()) { send('', 'mission', { verb: 'new', objective: ta.value.trim() }); ta.value = ''; } } }, 'Open mission'))),
    h('div', { class: 'card' }, h('div', { class: 'dim' }, 'Start a venture: created inactive, validated first, you approve before anything is spent.'), vn, vi,
      h('div', { class: 'btns' }, h('button', { class: 'ghost', onclick: () => { if (vn.value.trim().length >= 3 && vi.value.trim().length >= 15) { act('venture', { verb: 'new', name: vn.value.trim(), idea: vi.value.trim() }); vn.value = ''; vi.value = ''; } else note('Give a name and at least a sentence.'); } }, 'Set up venture'))),
    ...(s.missions || []).map((m) => h('details', { class: 'card' },
      h('summary', {}, h('b', {}, (m.title || '').replace(/^Mission: /, '')), ' ', h('span', { class: 'tag' }, m.status + (m.verdict ? ' · ' + m.verdict : ''))),
      h('div', { class: 'dim' }, 'Budget ' + usd(m.spent_cents) + ' of ' + usd(m.budget_cents) + (m.expected_cad ? ' · expected $' + m.expected_cad + ' CAD' : '') + (m.days_to_cash ? ' in ' + m.days_to_cash + 'd' : '')),
      h('div', { class: 'bar' }, h('i', { style: 'width:' + Math.min(100, Math.round(100 * (m.spent_cents || 0) / Math.max(1, m.budget_cents || 1))) + '%' })),
      m.objective ? h('p', {}, m.objective) : null, m.success ? h('p', {}, h('b', {}, 'Success: '), m.success) : null,
      m.risks ? h('p', {}, h('b', {}, 'Risks: '), m.risks) : null, m.next_action ? h('p', {}, h('b', {}, 'Next: '), m.next_action) : null,
      m.verdict_reason ? h('p', { class: 'dim' }, m.verdict_reason) : null,
      h('div', { class: 'btns' }, h('button', { class: 'ghost', onclick: () => act(m.id, 'pause') }, 'Pause'), h('button', { class: 'ghost', onclick: () => act(m.id, 'resume') }, 'Resume'),
        h('button', { class: 'ghost', onclick: () => { if (confirm('Abandon this mission?')) act(m.id, 'abandon'); } }, 'Abandon')))));
}
function rAgents(s) {
  $('v-agents').replaceChildren(...(s.agents || []).map((a) => h('div', { class: 'card' },
    h('div', { class: 'row' }, h('h3', {}, a.title || a.slug), h('span', { class: 'tag' }, a.status)),
    h('div', { class: 'dim' }, `${a.role} · ${a.tier || ''} · ${a.venture || 'company'}`),
    h('div', { class: 'dim' }, `Today ${usd(a.spent_today)} of ${usd(a.cap_cents)} · ${a.open} open · ${a.done_7d} done this week`),
    a.last_task ? h('div', { class: 'dim' }, 'Last: ' + a.last_task) : null,
    h('div', { class: 'btns' }, h('button', { class: 'ghost', onclick: () => rpc('app_set_agent', { p_slug: a.slug, p_status: a.status === 'active' ? 'paused' : 'active' }).then(refresh).catch((e) => note(e.message)) }, a.status === 'active' ? 'Pause' : 'Resume')))));
}
function rMoney(s) {
  const c = s.capital || {}; const row = (a, b) => h('div', { class: 'row' }, h('span', { class: 'dim' }, a), h('span', {}, b));
  const days = s.spend_7d || [];
  $('v-money').replaceChildren(
    h('div', { class: 'card' }, h('div', { class: 'dim' }, 'Available'), h('div', { class: 'big' }, c.available_cents != null ? usd(c.available_cents) : 'Capital controller not live yet'),
      c.fund_cents != null ? [row('Started with', usd(c.fund_cents)), row('Money in (received only)', usd(c.revenue_cents)), row('AI spend', usd(c.ai_spend_cents)), row('Other spend', usd(c.expense_cents)),
        row('Reserved', usd(c.reserved_cents)), row('Recurring / month', usd(c.recurring_monthly_cents)), row('This week', usd(c.week_spend_cents) + ' of ' + usd(c.weekly_limit_cents)),
        row('Per purchase limit', usd(c.per_transaction_limit_cents)), row('Reserve floor', usd(c.min_reserve_cents)),
        c.bank_balance_cents != null ? row('Bank balance (source of truth)', usd(c.bank_balance_cents) + ' · ' + c.bank_age_days + 'd ago') : row('Bank balance', 'not recorded'),
        c.ledger_available_cents != null ? row('Ledger says', usd(c.ledger_available_cents)) : null] : null,
      (s.bank_alerts || []).map((a) => h('div', { class: 'dim', style: 'color:var(--warn)' }, '! ' + a))),
    s.pnl && s.pnl.total ? [h('h2', {}, 'Profit and loss, 30 days'), h('div', { class: 'card' },
      (s.pnl.ventures || []).map((v) => row(v.name, 'net ' + usd(v.net_cents) + ' (in ' + usd(v.revenue_cents) + ')')),
      row('Total cash in', usd(s.pnl.total.revenue_cents)), row('Overhead AI', usd(s.pnl.total.holding_ai_cents)),
      row('Net after overhead', usd(s.pnl.total.net_after_overhead_cents)),
      h('div', { class: 'dim' }, 'Not cash: pipeline ' + usd(s.pnl.total.pipeline_cents) + ', forecasts ' + usd(s.pnl.total.forecast_cents)))] : null,
    bankCard(c),
    h('h2', {}, 'AI spend, last 7 days'), h('div', { class: 'card' }, days.length ? days.map((d) => row(d.d, usd(d.c))) : h('span', { class: 'dim' }, 'No spend recorded.')),
    h('h2', {}, 'Permissions'), h('div', { class: 'card' }, (s.policy || []).length ? s.policy.map((p) => row(p.action, p.tier)) : h('span', { class: 'dim' }, 'Policy table not live yet.')),
    h('p', { class: 'dim' }, 'Limits are changed in Telegram with /capital and /policy. Agents cannot change them.'));
}
function rFeed(s) {
  $('v-feed').replaceChildren(...(s.feed || []).map((f) => h('div', { class: 'card' },
    h('div', { class: 'row dim' }, h('span', {}, (f.who || 'system') + ' · ' + f.type), h('span', {}, ago(f.at))), h('div', {}, f.text), f.status ? h('span', { class: 'tag' }, f.status) : null)));
}

// ---------- chat + browser voice ----------
$('f-chat').addEventListener('submit', (e) => { e.preventDefault(); const t = $('say').value.trim(); if (!t) return;
  $('say').value = ''; S.msgs.push({ id: 'tmp' + Date.now(), role: 'owner', kind: 'chat', body: t }); rChat(); send(t, 'chat'); });
function speakText(t) { try { if (!('speechSynthesis' in window)) return; speechSynthesis.cancel(); speechSynthesis.speak(new SpeechSynthesisUtterance(String(t).slice(0, 600))); } catch (e) {} }
const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
if (!SR) $('mic').hidden = true;
else {
  let rec = null;
  $('mic').addEventListener('click', () => {
    if (rec) { rec.stop(); return; }
    rec = new SR(); rec.lang = 'en-CA'; rec.interimResults = true;
    rec.onresult = (ev) => { $('say').value = Array.from(ev.results).map((r) => r[0].transcript).join(' '); };
    rec.onend = () => { rec = null; $('mic').classList.remove('rec'); if ($('say').value.trim()) $('f-chat').requestSubmit(); };
    rec.onerror = () => { rec = null; $('mic').classList.remove('rec'); };
    $('mic').classList.add('rec'); rec.start();
  });
}
boot();
