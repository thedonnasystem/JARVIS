'use strict';
// FENDEZY GROUP HQ screens. Read-only. Reads ONLY through HQ.model(ctx): demo mode uses window.HQ_DEMO (hq/demo_data.js, synthetic);
// live mode (signed-in owner) overlays whatever the existing app_* reads already return (app_snapshot, app_office, app_needs_you) and
// leaves everything the database cannot answer yet as SIMULATED / NOT CONNECTED / INCOMPLETE. No network calls, no writes, no HTML injection: all text is set as text.
(function (root) {
  const doc = root.document;
  const NS = 'http://www.w3.org/2000/svg';
  const SCREENS = [['overview', 'Overview'], ['org', 'Org chart'], ['divisions', 'Divisions'], ['offices', 'Offices'], ['jarvis', 'Jarvis'], ['managers', 'Managers'],
    ['agents', 'Agents'], ['missions', 'Missions'], ['activity', 'Activity'], ['finance', 'Finance'], ['health', 'Health']];
  const DETAIL_TYPES = { division: 1, manager: 1, mission: 1, office: 1 };

  // ---------- tiny helpers (text only) ----------
  function h(tag, attrs, ...kids) {
    const e = doc.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) { if (k === 'class') e.className = v; else if (k.startsWith('on')) e.addEventListener(k.slice(2), v); else if (v !== false && v != null) e.setAttribute(k, v); }
    for (const c of kids.flat(2)) if (c != null && c !== false) e.append(c.nodeType ? c : doc.createTextNode(String(c)));
    return e;
  }
  function sv(tag, attrs, ...kids) {
    const e = doc.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs || {})) { if (k.startsWith('on')) e.addEventListener(k.slice(2), v); else if (v != null && v !== false) e.setAttribute(k, v); }
    for (const c of kids.flat(2)) if (c != null && c !== false) e.append(c.nodeType ? c : doc.createTextNode(String(c)));
    return e;
  }
  const usd = (c) => '$' + ((Number(c) || 0) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const mins = (m) => (m == null ? '' : m < 2 ? 'now' : m < 90 ? Math.round(m) + 'm' : m < 2160 ? Math.round(m / 60) + 'h' : Math.round(m / 1440) + 'd');
  const sinceMin = (t) => (t ? Math.max(0, (Date.now() - new Date(t).getTime()) / 60000) : null);
  const pct = (a, b) => Math.min(100, Math.round(100 * (Number(a) || 0) / Math.max(1, Number(b) || 1)));
  const trunc = (s, n) => { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  const clone = (o) => JSON.parse(JSON.stringify(o));

  // ---------- model: the ONE place data comes from ----------
  const SRC = { LIVE: 'live', SIMULATED: 'sim', 'NOT CONNECTED': 'nc', INCOMPLETE: 'inc' };
  function model(ctx) {
    const D = clone(root.HQ_DEMO);
    const demo = !ctx || ctx.mode !== 'live' || !ctx.snap;
    const M = { demo, d: D, src: {} };
    const all = ['overview', 'org', 'divisions', 'offices', 'managers', 'j_state', 'j_approvals', 'j_gateway', 'j_policy', 'agents', 'missions', 'feed', 'f_cap', 'f_capital', 'f_ledger', 'h_checks', 'h_deploy', 'h_backup', 'h_consent'];
    all.forEach((k) => { M.src[k] = 'SIMULATED'; });
    D.liveVentures = null;
    if (demo) return M;
    const s = ctx.snap; const st = s.state || {};
    D.jarvis.state = { mode: st.mode, kill_switch: !!st.kill_switch, pause_reason: st.pause_reason, cap_cents: st.cap_cents, last_heartbeat_min: sinceMin(st.last_heartbeat) };
    M.src.j_state = 'LIVE'; M.src.j_gateway = 'LIVE';
    const inbox = Array.isArray(ctx.inbox) ? ctx.inbox : [];
    D.jarvis.pending_approvals = inbox.map((i) => ({ id: String(i.ref_id), title: i.title, why: i.why, age_min: sinceMin(i.created_at), division_id: null, kind: i.kind }));
    M.src.j_approvals = 'LIVE';
    if (Array.isArray(s.policy) && s.policy.length) { D.jarvis.policy = s.policy.map((p) => ({ action: p.action, tier: p.tier })); M.src.j_policy = 'LIVE'; } else { D.jarvis.policy = []; M.src.j_policy = 'NOT CONNECTED'; }
    if (Array.isArray(ctx.office) && ctx.office.length) {
      const live = ctx.office.map((f) => ({ fn: f.fn, name: f.name, defined_in: 'repo', head: (f.agents[0] || {}).slug || null, headline: f.headline, agents: f.agents.length, open: f.open, blocked: f.blocked, done_7d: f.done_7d,
        spent_7d_cents: f.spent_7d, charter: '', members: f.agents.map((a) => ({ slug: a.slug, title: a.title, status: a.status })) }));
      D.offices = live.concat(D.offices.filter((o) => o.defined_in === 'inferred'));
      M.src.offices = 'INCOMPLETE';
    }
    D.agents = (s.agents || []).map((a) => ({ slug: a.slug, title: a.title, role: a.role, status: a.status, tier: a.tier, venture: a.venture, team_id: null, cap_cents: a.cap_cents, spent_today: a.spent_today, done_7d: a.done_7d, open: a.open, last_task: a.last_task }));
    M.src.agents = 'LIVE';
    D.missions = (s.missions || []).map((m) => ({ id: m.id, title: String(m.title || '').replace(/^Mission: /, ''), status: m.status, verdict: m.verdict, division_id: null, budget_cents: m.budget_cents, spent_cents: m.spent_cents,
      expected_cad: m.expected_cad, days_to_cash: m.days_to_cash, objective: m.objective, success: m.success, risks: m.risks, next_action: m.next_action, gate: null, updated_min: sinceMin(m.updated_at), steps: [] }));
    M.src.missions = 'LIVE';
    D.feed = (s.feed || []).map((f) => ({ min_ago: sinceMin(f.at), type: f.type, who: f.who, text: f.text, status: f.status, division_id: null }));
    M.src.feed = 'LIVE';
    const c = s.capital || null;
    if (c) { D.finance.capital = c; M.src.f_capital = 'LIVE'; } else M.src.f_capital = 'NOT CONNECTED';
    D.finance.spend_today_cents = s.spend_today_cents || 0;
    D.finance.spend_7d = (s.spend_7d || []).map((x) => ({ d: x.d, c: x.c }));
    M.src.f_cap = 'LIVE';
    D.finance.by_division = []; D.finance.ledger = { cash_in_30d_cents: s.pnl && s.pnl.total ? s.pnl.total.revenue_cents : null, cash_out_30d_cents: null, expected_not_cash_cents: s.pnl && s.pnl.total ? s.pnl.total.pipeline_cents : null, rows_30d: null, note: 'Only the 30-day profit and loss summary is readable from the app. A ledger transaction list is not connected.' };
    M.src.f_ledger = 'INCOMPLETE';
    D.health.checks = (s.systems || []).map((x) => ({ name: x.name, status: x.status === 'ok' ? 'ok' : x.status || 'unknown', checked_min: sinceMin(x.checked), detail: x.url ? 'registered system' : '' }));
    D.health.checks.unshift({ name: 'Engine heartbeat', status: st.kill_switch ? 'stopped' : (D.jarvis.state.last_heartbeat_min != null && D.jarvis.state.last_heartbeat_min <= 20 ? 'ok' : 'stale'), checked_min: D.jarvis.state.last_heartbeat_min, detail: 'Ticks every 5 minutes' });
    M.src.h_checks = 'LIVE';
    D.health.deployments = []; D.health.backups = null; D.health.consent_gate = null;
    M.src.h_deploy = 'NOT CONNECTED'; M.src.h_backup = 'NOT CONNECTED'; M.src.h_consent = 'NOT CONNECTED';
    D.liveVentures = (s.ventures || []).map((v) => ({ slug: v.slug, name: v.name, status: v.status, agents: v.agents, leads: v.leads, in_cents: v.in_cents, out_cents: v.out_cents, expected_cents: v.expected_cents, ai_cents_7d: v.ai_cents_7d }));
    M.src.overview = 'INCOMPLETE';
    return M;
  }

  // ---------- state ----------
  const S = { screen: 'overview', detail: null, open: null, filters: { mstat: 'all', adiv: 'all', atype: 'all', astat: 'all' }, ctx: null, box: null };
  const findDiv = (M, id) => M.d.divisions.find((x) => x.id === id);
  const divName = (M, id) => { const d = findDiv(M, id); return d ? d.name : id ? String(id) : 'none'; };

  function readHash() {
    const raw = String((root.location && root.location.hash) || '').replace(/^#/, ''); if (!raw) return;
    const [scr, type, id] = raw.split('/').map((x) => { try { return decodeURIComponent(x); } catch (e) { return ''; } });
    if (SCREENS.some((x) => x[0] === scr)) { S.screen = scr; S.detail = DETAIL_TYPES[type] === 1 && id ? { type, id } : null; }
  }
  function writeHash() { try { const hs = '#' + S.screen + (S.detail ? '/' + S.detail.type + '/' + encodeURIComponent(S.detail.id) : ''); if (root.history && root.history.replaceState) root.history.replaceState(null, '', hs); } catch (e) {} }
  function go(screen, detail) { S.screen = screen; S.detail = detail || null; writeHash(); draw(); if (S.box && S.box.parentElement) S.box.parentElement.scrollTop = 0; }

  // ---------- shared pieces ----------
  const badge = (src) => h('span', { class: 'hq-badge b-' + SRC[src], title: { LIVE: 'Read from the live database through an existing app_* function', SIMULATED: 'Synthetic demo numbers. Not real.', 'NOT CONNECTED': 'No data source exists yet for this panel', INCOMPLETE: 'Partly live, partly missing' }[src] }, src);
  const panel = (title, src, ...body) => h('section', { class: 'card hq-panel', 'data-src': SRC[src] }, h('div', { class: 'row hq-ph' }, h('h3', {}, title), badge(src)), ...body);
  const dim = (t) => h('div', { class: 'dim' }, t);
  const kv = (a, b) => h('div', { class: 'row hq-kv' }, h('span', { class: 'dim' }, a), h('span', {}, b));
  const meter = (a, b, cls) => h('div', { class: 'bar' }, h('i', { class: cls || '', style: 'width:' + pct(a, b) + '%' }));
  const dot = (health) => h('i', { class: 'hq-dot d-' + (health || 'grey'), 'aria-hidden': 'true' });
  const tag = (t, cls) => h('span', { class: 'tag ' + (cls || '') }, t);
  const link = (label, fn) => h('button', { class: 'ghost hq-link', onclick: fn }, label);
  const back = (screen, label) => h('button', { class: 'ghost hq-back', onclick: () => go(screen) }, '‹ ' + label);
  const ownerNote = (t, where) => h('div', { class: 'hq-owner' }, h('b', {}, 'Owner action' + (where === '' ? '. ' : ' in ' + (where || 'Telegram') + '. ')), t, ' This screen cannot change it.');
  const filterBar = (key, options, M) => h('div', { class: 'hq-chips', role: 'group' }, options.map(([v, l]) => h('button', { class: 'chip' + (S.filters[key] === v ? ' on' : ''), 'aria-pressed': String(S.filters[key] === v), onclick: () => { S.filters[key] = v; draw(); } }, l)));

  // ---------- derived alerts (computed from the model, labelled with the source of the number) ----------
  function alerts(M) {
    const d = M.d, out = []; const j = d.jarvis.state;
    if (j.kill_switch) out.push({ lvl: 'bad', text: 'Kill switch is ON: all agents stopped.', src: M.src.j_state });
    else if (j.last_heartbeat_min == null || j.last_heartbeat_min > 20) out.push({ lvl: 'bad', text: 'No heartbeat for ' + (j.last_heartbeat_min == null ? '?' : Math.round(j.last_heartbeat_min)) + ' minutes: HQ may be down.', src: M.src.j_state });
    const cap = j.cap_cents || 330; const sp = d.finance.spend_today_cents;
    if (sp >= cap * 0.8) out.push({ lvl: sp >= cap ? 'bad' : 'warn', text: 'AI spend today ' + usd(sp) + ' is ' + pct(sp, cap) + '% of the ' + usd(cap) + ' cap.', src: M.src.f_cap });
    const blocked = d.missions.filter((m) => m.status === 'blocked'); if (blocked.length) out.push({ lvl: 'warn', text: blocked.length + ' mission' + (blocked.length > 1 ? 's' : '') + ' blocked: ' + trunc(blocked[0].title, 50), src: M.src.missions });
    if (d.health.backups && /unproven|not captured/.test(String(d.health.backups.status) + String(d.health.backups.restore_proof))) out.push({ lvl: 'warn', text: 'Backups configured but no restore proof captured.', src: M.src.h_backup });
    if (M.src.divisions === 'SIMULATED') d.divisions.filter((x) => x.health === 'amber' || x.health === 'red').forEach((x) => out.push({ lvl: x.health === 'red' ? 'bad' : 'warn', text: x.name + ': ' + (x.risks[0] || 'needs attention'), src: 'SIMULATED' }));
    return out;
  }

  // ---------- screens ----------
  function sOverview(M) {
    const d = M.d, j = d.jarvis, st = j.state;
    const run = st.kill_switch ? ['KILL SWITCH ON', 'bad'] : st.pause_reason ? ['PAUSED', 'warn'] : ['RUNNING', 'ok'];
    const needs = j.pending_approvals; const act = d.agents.filter((a) => a.status === 'active').length;
    const live = d.missions.filter((m) => !/completed|rejected|abandoned|failed/.test(m.status)).length;
    const tile = (label, val, sub, src, go_) => h('button', { class: 'hq-tile', onclick: go_ }, h('span', { class: 'dim' }, label), h('b', {}, val), h('span', { class: 'dim' }, sub), badge(src));
    return [
      panel('Group status', M.src.j_state, h('div', { class: 'row' }, h('div', { class: 'big hq-status ' + run[1] }, run[0]), h('div', { class: 'dim' }, 'mode ' + String(st.mode || '?').replace(/_/g, ' ') + ' · beat ' + mins(st.last_heartbeat_min))),
        dim(st.mode === 'dry_run' ? 'Dry-run: nothing can be sent or spent for real. Enforced in the database.' : 'Live mode.')),
      h('div', { class: 'hq-tiles' },
        tile('AI spend today', usd(d.finance.spend_today_cents), 'of ' + usd(st.cap_cents) + ' cap', M.src.f_cap, () => go('finance')),
        tile('Operating cash', d.finance.capital && d.finance.capital.available_cents != null ? usd(d.finance.capital.available_cents) : 'n/a', 'available', M.src.f_capital, () => go('finance')),
        tile('Waiting on you', String(needs.length), 'approvals and questions', M.src.j_approvals, () => go('jarvis')),
        tile('Live missions', String(live), d.missions.filter((m) => m.status === 'blocked').length + ' blocked', M.src.missions, () => go('missions')),
        tile('Agents active', act + '/' + d.agents.length, 'workforce', M.src.agents, () => go('agents')),
        tile('Divisions', String(d.divisions.length), d.divisions.filter((x) => x.health === 'green').length + ' green', M.src.divisions, () => go('divisions'))),
      panel('Needs the Chairman', M.src.j_approvals, ...(needs.length ? needs.slice(0, 5).map((n) => h('div', { class: 'hq-need' }, h('div', {}, n.title), h('div', { class: 'dim' }, [n.why, n.age_min != null ? mins(n.age_min) + ' ago' : ''].filter(Boolean).join(' · ')))) : [dim('Nothing waiting on you.')]),
        link('Open Jarvis control center', () => go('jarvis'))),
      panel('Alerts', M.demo ? 'SIMULATED' : 'INCOMPLETE', ...(alerts(M).length ? alerts(M).map((a) => h('div', { class: 'hq-alert a-' + a.lvl }, h('span', {}, a.text), badge(a.src))) : [dim('No alerts.')])),
      panel('Divisions at a glance', M.src.divisions, h('div', { class: 'hq-heat' }, d.divisions.map((x) => h('button', { class: 'hq-heatc', onclick: () => go('divisions', { type: 'division', id: x.id }) }, dot(x.health), h('span', {}, x.name), h('span', { class: 'dim' }, x.lifecycle))))),
      M.demo ? panel('How to read this page', 'SIMULATED', dim('Every number here is synthetic. Badges show where a panel would get real data: LIVE (existing database read), SIMULATED (demo), NOT CONNECTED (no source yet), INCOMPLETE (partly live).')) : panel('How to read this page', 'INCOMPLETE', dim('LIVE panels come from the database you are signed in to. SIMULATED panels (divisions, managers, teams, budgets, KPIs) are a proposal: the database has no such tables yet.')),
    ];
  }

  // org chart: indented tree drawn as SVG, expandable, phone friendly
  function orgNodes(M) {
    const d = M.d; const O = S.open;
    const kids = {};
    const n = (id, label, sub, kind, ref, health, children) => ({ id, label, sub, kind, ref, health, children: children || [] });
    const divNodes = d.divisions.map((x) => {
      const mgr = d.managers.find((m) => m.id === x.manager_id);
      const teams = (x.team_ids || []).map((tid) => d.teams.find((t) => t.id === tid)).filter(Boolean).map((t) => n('t:' + t.id, t.name, t.agent_ids.length + (t.agent_ids.length === 1 ? ' agent' : ' agents'), 'team', null, null, []));
      const mn = mgr ? n('m:' + mgr.id, mgr.title, mgr.status, 'manager', mgr.id, mgr.status === 'active' ? 'green' : 'grey', teams) : null;
      return n('d:' + x.id, x.name, x.lifecycle, 'division', x.id, x.health, mn ? [mn] : teams);
    });
    const offNodes = d.offices.map((o) => n('o:' + o.fn, o.name, o.agents ? o.agents + (o.agents === 1 ? ' agent' : ' agents') : 'unstaffed', 'office', o.fn, o.agents ? 'green' : 'grey', []));
    const tree = n('chair', 'Chairman', 'Owner', 'chair', null, null, [n('jarvis', 'Jarvis (COO)', 'only agent that contacts the Chairman', 'jarvis', null, 'green', [
      n('g:off', 'Corporate offices', offNodes.length + ' offices', 'group', null, null, offNodes), n('g:div', 'Divisions', divNodes.length + ' divisions', 'group', null, null, divNodes)])]);
    const rows = []; (function walk(x, lvl) { rows.push({ x, lvl }); kids[x.id] = x.children; if (O.has(x.id)) x.children.forEach((c) => walk(c, lvl + 1)); })(tree, 0);
    return { rows, tree };
  }
  function sOrg(M) {
    const W = 360, RH = 32; const { rows } = orgNodes(M); const H = rows.length * RH + 6;
    const svg = sv('svg', { viewBox: '0 0 ' + W + ' ' + H, class: 'hq-org', role: 'img', 'aria-label': 'Organization chart: Chairman, Jarvis, corporate offices, divisions, managers, teams' });
    const ypos = []; rows.forEach((r, i) => { ypos[i] = 3 + i * RH; });
    const parentIdx = (i) => { for (let k = i - 1; k >= 0; k--) if (rows[k].lvl === rows[i].lvl - 1) return k; return -1; };
    rows.forEach((r, i) => { const p = parentIdx(i); if (p >= 0) { const px = 10 + (r.lvl - 1) * 16 + 8; svg.append(sv('path', { d: 'M' + px + ' ' + (ypos[p] + 24) + ' V' + (ypos[i] + 13) + ' H' + (10 + r.lvl * 16), class: 'org-line' })); } });
    const toggle = (id) => { if (S.open.has(id)) S.open.delete(id); else S.open.add(id); draw(); };
    const open = (x) => { if (x.kind === 'division') go('divisions', { type: 'division', id: x.ref }); else if (x.kind === 'manager') go('managers', { type: 'manager', id: x.ref }); else if (x.kind === 'office') go('offices', { type: 'office', id: x.ref }); else if (x.kind === 'jarvis') go('jarvis'); };
    const hasDetail = (x) => ['division', 'manager', 'office', 'jarvis'].includes(x.kind);
    rows.forEach((r, i) => {
      const x = r.x, px = 10 + r.lvl * 16, w = W - px - 6, y = ypos[i], exp = S.open.has(x.id), kidsN = x.children.length;
      const g = sv('g', { class: 'org-node k-' + x.kind, role: 'button', tabindex: '0', 'data-node': x.id, 'aria-label': x.label + (kidsN ? (exp ? ', expanded' : ', collapsed') : ''), 'aria-expanded': kidsN ? String(exp) : null,
        onclick: () => (kidsN ? toggle(x.id) : hasDetail(x) ? open(x) : null), onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (kidsN) toggle(x.id); else if (hasDetail(x)) open(x); } } });
      g.append(sv('rect', { x: px, y, width: w, height: 26, rx: 7, class: 'org-box' }));
      if (x.health) g.append(sv('circle', { cx: px + 10, cy: y + 13, r: 4, class: 'org-dot d-' + x.health }));
      const tx = px + (x.health ? 20 : 9); const maxc = Math.max(8, Math.floor((w - (tx - px) - 34) / 5.9));
      g.append(sv('text', { x: tx, y: y + 11, class: 'org-t' }, trunc(x.label, maxc)), sv('text', { x: tx, y: y + 22, class: 'org-s' }, trunc(x.sub, maxc + 6)));
      if (kidsN) g.append(sv('text', { x: px + w - 22, y: y + 17, class: 'org-chev' }, exp ? '−' : '+'));
      svg.append(g);
      if (kidsN && hasDetail(x)) {
        svg.append(sv('g', { class: 'org-info', role: 'button', tabindex: '0', 'data-open': x.id, 'aria-label': 'Open ' + x.label, onclick: () => open(x), onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(x); } } },
          sv('circle', { cx: px + w - 8, cy: y + 13, r: 8, class: 'org-i' }), sv('text', { x: px + w - 8, y: y + 17, class: 'org-it' }, '›')));
      }
    });
    const all = () => { const ids = new Set(); (function w(x) { ids.add(x.id); x.children.forEach(w); })(orgNodes(M).tree); S.open = ids; draw(); };
    return [panel('Fendezy Group organization', 'SIMULATED',
      dim('Chairman → Jarvis → corporate offices and eight divisions → managers → teams. Tap a row to expand; tap the › button to open its profile.'),
      h('div', { class: 'btns' }, h('button', { class: 'ghost', onclick: all }, 'Expand all'), h('button', { class: 'ghost', onclick: () => { S.open = new Set(['chair', 'jarvis', 'g:off', 'g:div']); draw(); } }, 'Collapse')),
      h('div', { class: 'hq-orgwrap' }, svg),
      dim('Offices (repo-defined) carry live agent counts when signed in. Divisions, managers and teams are an inferred proposal: the repo has no division table.'))];
  }

  function sDivisions(M) {
    const d = M.d;
    if (S.detail && S.detail.type === 'division') {
      const x = findDiv(M, S.detail.id); if (!x) return [back('divisions', 'Divisions'), dim('Unknown division.')];
      const mgr = d.managers.find((m) => m.id === x.manager_id);
      return [back('divisions', 'All divisions'),
        panel(x.name, M.src.divisions, h('div', { class: 'row' }, h('span', {}, [dot(x.health), ' ', x.health]), tag(x.lifecycle)), dim(x.charter), kv('Origin', x.origin),
          kv('Manager', mgr ? h('button', { class: 'ghost hq-link', onclick: () => go('managers', { type: 'manager', id: mgr.id }) }, mgr.title) : 'none')),
        panel('Budget and money', M.src.divisions, kv('Monthly AI budget', usd(x.budget.monthly_cents)), kv('Spent this month', usd(x.budget.spent_cents)), meter(x.budget.spent_cents, x.budget.monthly_cents),
          kv('Cash in / out', usd(x.money.in_cents) + ' / ' + usd(x.money.out_cents)), kv('Expected (not cash)', usd(x.money.expected_cents))),
        panel('KPIs', M.src.divisions, ...x.kpis.map((k) => h('div', { class: 'hq-kpi' }, kv(k.name, k.value + (k.unit === '%' ? '%' : '') + ' / target ' + k.target + (k.unit === '%' ? '%' : '')), meter(k.value, k.target || 1)))),
        panel('Teams', M.src.divisions, ...(x.team_ids.length ? x.team_ids.map((tid) => { const t = d.teams.find((q) => q.id === tid); return t ? h('div', { class: 'hq-sub' }, h('b', {}, t.name), dim(t.purpose), dim(t.agent_ids.map((id) => { const a = d.agents.find((q) => q.slug === id); return a ? a.title : id; }).join(', '))) : null; }) : [dim('No teams yet.')])),
        panel('Risks', M.src.divisions, ...(x.risks.length ? x.risks.map((r) => h('div', { class: 'hq-alert a-warn' }, r)) : [dim('None recorded.')])),
        panel('Missions', M.src.missions, ...(d.missions.filter((m) => m.division_id === x.id).map((m) => h('button', { class: 'hq-rowbtn', onclick: () => go('missions', { type: 'mission', id: m.id }) }, h('span', {}, m.title), tag(m.status)))), ...(d.missions.some((m) => m.division_id === x.id) ? [] : [dim('No missions linked.')]))];
    }
    const cards = d.divisions.map((x) => { const mgr = d.managers.find((m) => m.id === x.manager_id);
      return h('button', { class: 'card hq-div', onclick: () => go('divisions', { type: 'division', id: x.id }) }, h('div', { class: 'row' }, h('h3', {}, x.name), tag(x.lifecycle)), h('div', { class: 'dim' }, [dot(x.health), ' ', x.health, ' · ', mgr ? mgr.title : 'no manager']),
        h('div', { class: 'dim' }, trunc(x.charter, 90)), meter(x.budget.spent_cents, x.budget.monthly_cents), h('div', { class: 'dim' }, usd(x.budget.spent_cents) + ' of ' + usd(x.budget.monthly_cents) + ' / month · ' + x.kpis.length + ' KPIs')); });
    const out = [panel(d.divisions.length + ' divisions', M.src.divisions, dim('INFERRED from the venture list: the repo defines no division table. Edit hq/demo_data.js to change the proposal.')), h('div', { class: 'hq-grid' }, cards)];
    if (d.liveVentures) out.push(panel('Live ventures (real, from the database)', 'LIVE', ...(d.liveVentures.length ? d.liveVentures.map((v) => h('div', { class: 'hq-sub' }, h('div', { class: 'row' }, h('b', {}, v.name), tag(v.status)), dim(v.agents + ' agents · ' + v.leads + ' leads · in ' + usd(v.in_cents) + ' · out ' + usd(v.out_cents) + ' · AI 7d ' + usd(v.ai_cents_7d)))) : [dim('No active ventures.')])));
    return out;
  }

  function sOffices(M) {
    const d = M.d;
    if (S.detail && S.detail.type === 'office') {
      const o = d.offices.find((x) => x.fn === S.detail.id); if (!o) return [back('offices', 'Offices'), dim('Unknown office.')];
      return [back('offices', 'All offices'), panel(o.name, o.defined_in === 'repo' ? M.src.offices : 'SIMULATED', tag(o.defined_in === 'repo' ? 'defined in repo' : 'inferred / proposed'), dim(o.headline), dim(o.charter || 'Charter not stored in the database.'),
        kv('Head', o.head || 'unstaffed'), kv('Agents', String(o.agents)), kv('Open / blocked', o.open + ' / ' + o.blocked), kv('Done this week', String(o.done_7d)), kv('AI spend 7d', usd(o.spent_7d_cents)),
        ...((o.members || []).map((a) => h('div', { class: 'row dim' }, h('span', {}, a.title || a.slug), h('span', {}, a.status)))))];
    }
    return [panel('Corporate offices', M.src.offices, dim('The nine functions come from the repo (office_v1). Legal and Security & Risk are proposed additions, not in the repo.')),
      ...d.offices.map((o) => h('button', { class: 'card hq-div', onclick: () => go('offices', { type: 'office', id: o.fn }) }, h('div', { class: 'row' }, h('h3', {}, o.name), tag(o.defined_in === 'repo' ? 'repo' : 'proposed')), dim(o.headline), dim(o.agents + ' agents · ' + o.open + ' open · ' + o.blocked + ' blocked · ' + o.done_7d + ' done this week')))];
  }

  function sJarvis(M) {
    const d = M.d, j = d.jarvis, st = j.state; const cap = st.cap_cents || 330; const sp = d.finance.spend_today_cents;
    const top = d.agents.slice().sort((a, b) => (b.spent_today || 0) - (a.spent_today || 0)).slice(0, 6);
    return [
      panel('Status (display only)', M.src.j_state,
        h('div', { class: 'row' }, h('span', {}, 'Kill switch'), h('span', { class: 'hq-state ' + (st.kill_switch ? 'bad' : 'ok'), 'data-kill': st.kill_switch ? 'on' : 'off' }, st.kill_switch ? 'ON' : 'OFF')),
        h('div', { class: 'row' }, h('span', {}, 'Mode'), h('span', { class: 'hq-state ' + (st.mode === 'dry_run' ? 'ok' : 'warn') }, String(st.mode || '?').replace(/_/g, ' ').toUpperCase())),
        kv('Heartbeat', mins(st.last_heartbeat_min) + ' ago'), kv('Paused reason', st.pause_reason || 'none'),
        ownerNote('Kill switch: /kill and /resume. Mode and limits: /capital, /policy.')),
      panel('Spend gateway', M.src.j_gateway, kv('AI spent today', usd(sp) + ' of ' + usd(cap)), meter(sp, cap, sp >= cap * 0.8 ? 'warm' : ''), kv('Company daily cap', usd(cap)), kv('Reserve floor', usd(j.gateway.reserve_floor_cents)), dim(j.gateway.note),
        h('h4', { class: 'hq-h4' }, 'Highest spenders today'), ...top.map((a) => h('div', { class: 'row dim' }, h('span', {}, a.title), h('span', {}, usd(a.spent_today) + ' / ' + usd(a.cap_cents)))),
        ownerNote('Caps are changed with /capital. Agents cannot change them.')),
      panel('Pending approvals', M.src.j_approvals, ...(j.pending_approvals.length ? j.pending_approvals.map((p) => h('div', { class: 'hq-need' }, h('div', {}, p.title), h('div', { class: 'dim' }, [p.why, p.age_min != null ? mins(p.age_min) + ' ago' : ''].filter(Boolean).join(' · ')))) : [dim('Nothing pending.')]),
        M.demo ? dim('Demo: no buttons here by design. In the live app, approve or reject in the Inbox tab or in Telegram.') : link('Decide in the Inbox tab', () => S.ctx && S.ctx.goTab && S.ctx.goTab('inbox'))),
      panel('Autonomy tiers', M.src.j_policy, ...(j.policy.length ? j.policy.map((p) => h('div', { class: 'row' }, h('span', { class: 'dim' }, p.action), tag(p.tier, 't-' + p.tier))) : [dim('Policy table not readable yet.')]), ownerNote('Tiers change with /policy.'))];
  }

  function sManagers(M) {
    const d = M.d;
    if (S.detail && S.detail.type === 'manager') {
      const m = d.managers.find((x) => x.id === S.detail.id); if (!m) return [back('managers', 'Managers'), dim('Unknown manager.')];
      const div = findDiv(M, m.division_id); const teams = d.teams.filter((t) => t.division_id === m.division_id);
      return [back('managers', 'All managers'), panel(m.title, 'SIMULATED', h('div', { class: 'row' }, tag(m.status), tag(m.tier + ' model')), dim(m.charter), kv('Division', div ? h('button', { class: 'ghost hq-link', onclick: () => go('divisions', { type: 'division', id: div.id }) }, div.name) : 'none'),
        kv('Reports to', m.reports_to), kv('Authority', m.authority), kv('Scorecard', m.scorecard.flag + ' · ' + m.scorecard.done_7d + ' done this week' + (m.scorecard.cents_per_done != null ? ' · ' + m.scorecard.cents_per_done + 'c per task' : '')), kv('Last report', m.last_report)),
        panel('Teams managed', 'SIMULATED', ...(teams.length ? teams.map((t) => h('div', { class: 'hq-sub' }, h('b', {}, t.name), dim(t.purpose), dim(t.agent_ids.join(', ')))) : [dim('No teams yet.')]))];
    }
    return [panel('Division managers', M.src.managers, dim('Manager profiles are an inferred proposal (no manager table in the database yet).')),
      ...d.managers.map((m) => h('button', { class: 'card hq-div', onclick: () => go('managers', { type: 'manager', id: m.id }) }, h('div', { class: 'row' }, h('h3', {}, m.title), tag(m.status)), dim(divName(M, m.division_id)), dim(trunc(m.last_report, 100)), dim('scorecard ' + m.scorecard.flag + ' · ' + m.scorecard.done_7d + ' done this week')))];
  }

  function sAgents(M) {
    const d = M.d; const f = S.filters; const teamOf = (a) => d.teams.find((t) => t.id === a.team_id);
    const list = d.agents.filter((a) => (f.astat === 'all' || a.status === f.astat) && (f.adiv === 'all' || (teamOf(a) || {}).division_id === f.adiv || (f.adiv === 'none' && !teamOf(a))));
    const groups = {}; list.forEach((a) => { const t = teamOf(a); const k = t ? t.name : (a.venture || 'Company'); (groups[k] = groups[k] || []).push(a); });
    const cap = (a) => h('details', { class: 'card hq-agent' }, h('summary', {}, h('b', {}, a.title), ' ', tag(a.status), ' ', h('span', { class: 'dim' }, a.role)),
      kv('Today', usd(a.spent_today) + ' of ' + usd(a.cap_cents)), meter(a.spent_today, a.cap_cents), kv('Open / done this week', a.open + ' / ' + a.done_7d), kv('Model tier', a.tier || ''), a.last_task ? dim('Last: ' + a.last_task) : null);
    return [panel('Workforce', M.src.agents, kv('Agents', d.agents.length + ' (' + d.agents.filter((a) => a.status === 'active').length + ' active)'), kv('Spend today', usd(d.agents.reduce((t, a) => t + (a.spent_today || 0), 0))),
      filterBar('astat', [['all', 'All'], ['active', 'Active'], ['paused', 'Paused']], M),
      M.demo ? filterBar('adiv', [['all', 'All divisions'], ...d.divisions.map((x) => [x.id, x.name])], M) : dim('Agents are grouped by venture. Mapping agents to divisions needs the org model (not connected).'),
      dim('Read-only. Pause/resume stays on the Agents tab of the app.')),
      ...Object.keys(groups).sort().flatMap((k) => [h('h4', { class: 'hq-h4' }, k), ...groups[k].map(cap)]), ...(list.length ? [] : [dim('No agents match.')])];
  }

  const MSTAT = [['all', 'All'], ['active', 'Active'], ['blocked', 'Blocked'], ['planning', 'Planning'], ['completed', 'Done']];
  const mFilter = (m, v) => v === 'all' || (v === 'active' ? /executing|running|active|approved/.test(m.status) : v === 'done' ? m.status === 'completed' : m.status === (v === 'completed' ? 'completed' : v));
  function sMissions(M) {
    const d = M.d;
    if (S.detail && S.detail.type === 'mission') {
      const m = d.missions.find((x) => String(x.id) === String(S.detail.id)); if (!m) return [back('missions', 'Missions'), dim('Unknown mission.')];
      return [back('missions', 'All missions'), panel(m.title, M.src.missions, h('div', { class: 'row' }, tag(m.status), tag(m.verdict || 'no verdict')), dim(divName(M, m.division_id)), m.objective ? h('p', {}, m.objective) : null, m.success ? h('p', {}, h('b', {}, 'Success: '), m.success) : null, m.risks ? h('p', {}, h('b', {}, 'Risks: '), m.risks) : null,
        m.next_action ? h('p', {}, h('b', {}, 'Next: '), m.next_action) : null, m.gate ? h('p', {}, h('b', {}, 'Gate: '), m.gate) : null, kv('Budget', usd(m.spent_cents) + ' of ' + usd(m.budget_cents)), meter(m.spent_cents, m.budget_cents),
        m.expected_cad ? kv('Expected (not cash)', '$' + m.expected_cad + ' CAD') : null, m.updated_min != null ? kv('Updated', mins(m.updated_min) + ' ago') : null),
        panel('Tasks', M.demo ? 'SIMULATED' : 'NOT CONNECTED', ...(m.steps && m.steps.length ? m.steps.map((s, i) => h('div', { class: 'row' }, h('span', {}, (i + 1) + '. ' + s.title), tag(s.status))) : [dim('Task list per mission is not readable from the app yet.')])),
        M.demo ? dim('Demo: read-only.') : link('Pause / resume / abandon on the Missions tab', () => S.ctx && S.ctx.goTab && S.ctx.goTab('missions'))];
    }
    const list = d.missions.filter((m) => mFilter(m, S.filters.mstat));
    const counts = {}; d.missions.forEach((m) => { counts[m.status] = (counts[m.status] || 0) + 1; });
    return [panel('Missions and tasks', M.src.missions, dim(d.missions.length + ' missions · ' + Object.entries(counts).map(([k, v]) => v + ' ' + k).join(', ')), filterBar('mstat', MSTAT, M)),
      ...list.map((m) => h('button', { class: 'card hq-div', onclick: () => go('missions', { type: 'mission', id: m.id }) }, h('div', { class: 'row' }, h('h3', {}, m.title), tag(m.status)), dim(divName(M, m.division_id) + (m.next_action ? ' · next: ' + trunc(m.next_action, 50) : '')), meter(m.spent_cents, m.budget_cents), dim(usd(m.spent_cents) + ' of ' + usd(m.budget_cents)))),
      ...(list.length ? [] : [dim('No missions match this filter.')])];
  }

  function sActivity(M) {
    const d = M.d; const f = S.filters.atype; const list = d.feed.filter((x) => f === 'all' || x.type === f);
    return [panel('Company activity', M.src.feed, filterBar('atype', [['all', 'All'], ['task', 'Tasks'], ['message', 'Messages'], ['audit', 'Audit']], M)),
      ...list.map((x) => h('div', { class: 'card hq-feed' }, h('div', { class: 'row dim' }, h('span', {}, (x.who || 'system') + ' · ' + x.type + (x.division_id ? ' · ' + divName(M, x.division_id) : '')), h('span', {}, mins(x.min_ago))), h('div', {}, x.text), x.status ? tag(x.status) : null)),
      ...(list.length ? [] : [dim('No activity of this type.')])];
  }

  function sFinance(M) {
    const d = M.d, f = d.finance, c = f.capital || {}, cap = d.jarvis.state.cap_cents || 330; const mx = Math.max(1, ...f.spend_7d.map((x) => x.c));
    return [
      panel('AI spend cap', M.src.f_cap, h('div', { class: 'big' }, usd(f.spend_today_cents)), dim('spent today of the ' + usd(cap) + ' daily company cap'), meter(f.spend_today_cents, cap, f.spend_today_cents >= cap * 0.8 ? 'warm' : ''), ownerNote('The cap is changed with /capital.')),
      panel('Last 7 days', M.src.f_cap, ...(f.spend_7d.length ? f.spend_7d.map((x) => h('div', { class: 'hq-bar' }, h('span', { class: 'dim' }, x.d), h('span', { class: 'bar' }, h('i', { style: 'width:' + pct(x.c, mx) + '%' })), h('span', {}, usd(x.c)))) : [dim('No spend recorded.')])),
      panel('Operating capital', M.src.f_capital, c.available_cents != null ? [kv('Available', usd(c.available_cents)), kv('Started with', usd(c.fund_cents)), kv('Money in (received only)', usd(c.revenue_cents)), kv('AI spend', usd(c.ai_spend_cents)), kv('Reserved', usd(c.reserved_cents)),
        kv('This week', usd(c.week_spend_cents) + ' of ' + usd(c.weekly_limit_cents)), kv('Per purchase limit', usd(c.per_transaction_limit_cents)), kv('Reserve floor', usd(c.min_reserve_cents)),
        c.bank_balance_cents != null ? kv('Bank balance (source of truth)', usd(c.bank_balance_cents) + ' · ' + c.bank_age_days + 'd ago') : kv('Bank balance', 'not recorded')] : [dim('Capital controller not live.')], ownerNote('Limits: /capital. Bank balance and reconciliation are entered on the Money tab.')),
      panel('Ledger summary', M.src.f_ledger, kv('Cash in (30d)', f.ledger.cash_in_30d_cents != null ? usd(f.ledger.cash_in_30d_cents) : 'not available'), kv('Cash out (30d)', f.ledger.cash_out_30d_cents != null ? usd(f.ledger.cash_out_30d_cents) : 'not available'), kv('Expected, not cash', f.ledger.expected_not_cash_cents != null ? usd(f.ledger.expected_not_cash_cents) : 'not available'), dim(f.ledger.note)),
      panel('AI spend by division (7d)', M.src.divisions === 'SIMULATED' && f.by_division.length ? 'SIMULATED' : 'NOT CONNECTED', ...(f.by_division.length ? f.by_division.map((x) => kv(divName(M, x.division_id), usd(x.ai_cents_7d))) : [dim('Spend is not tagged by division in the database yet.')]))];
  }

  function sHealth(M) {
    const d = M.d, H = d.health; const cls = (s) => (s === 'ok' ? 'ok' : s === 'warn' || s === 'dormant' ? 'warn' : 'bad');
    return [
      panel('Health checks', M.src.h_checks, ...H.checks.map((c) => h('div', { class: 'row' }, h('span', {}, [h('i', { class: 'hq-dot d-' + (cls(c.status) === 'ok' ? 'green' : cls(c.status) === 'warn' ? 'amber' : 'red') }), ' ', c.name]), h('span', { class: 'dim' }, c.status + (c.checked_min != null ? ' · ' + mins(c.checked_min) : ''))))),
      panel('Deployments', M.src.h_deploy, ...(H.deployments.length ? H.deployments.map((x) => h('div', { class: 'hq-sub' }, h('div', { class: 'row' }, h('b', {}, x.name), tag(x.status)), dim(x.env + ' · ' + x.ref + ' · ' + mins(x.age_min) + ' ago'))) : [dim('Deployment status is not readable from the app.')]), ownerNote('Merges and production deploys need release authorization from the Chairman.', '')),
      panel('Backups', M.src.h_backup, ...(H.backups ? [kv('Status', H.backups.status), kv('Last run', mins(H.backups.last_run_min) + ' ago'), kv('Restore proof', H.backups.restore_proof), dim(H.backups.note)] : [dim('Backup state is not readable from the app.')])),
      panel('Consent gate', M.src.h_consent, ...(H.consent_gate ? [h('div', { class: 'row' }, h('span', {}, 'State'), h('span', { class: 'hq-state ' + (H.consent_gate.state === 'on' ? 'ok' : 'warn') }, String(H.consent_gate.state).toUpperCase())), dim(H.consent_gate.detail)] : [dim('Consent gate state is not readable from the app.')]), ownerNote('Only the Chairman can turn it on.', ''))];
  }

  const RENDER = { overview: sOverview, org: sOrg, divisions: sDivisions, offices: sOffices, jarvis: sJarvis, managers: sManagers, agents: sAgents, missions: sMissions, activity: sActivity, finance: sFinance, health: sHealth };

  // ---------- draw ----------
  function draw() {
    const box = S.box; if (!box) return;
    const M = model(S.ctx); S.model = M;
    if (!S.open) S.open = new Set(['chair', 'jarvis', 'g:off', 'g:div']);
    const banner = M.demo
      ? h('div', { class: 'hq-banner demo', role: 'status' }, h('b', {}, 'SIMULATED DATA. '), 'Demo only: every number, name and status is synthetic. Nothing is connected.')
      : h('div', { class: 'hq-banner mixed', role: 'status' }, h('b', {}, 'MIXED DATA. '), 'Panels badged LIVE come from the database. SIMULATED / NOT CONNECTED / INCOMPLETE panels are placeholders.');
    const nav = h('div', { class: 'hq-nav', role: 'navigation', 'aria-label': 'HQ sections' }, SCREENS.map(([k, t]) => h('button', { class: 'chip' + (S.screen === k ? ' on' : ''), 'data-screen': k, 'aria-current': S.screen === k ? 'page' : null, onclick: () => go(k) }, t)));
    let body; try { body = RENDER[S.screen](M); } catch (e) { body = [h('p', { class: 'dim' }, 'This screen could not be drawn: ' + String((e && e.message) || e))]; }
    box.replaceChildren(h('div', { class: 'hq' }, h('div', { class: 'hq-head' }, h('h1', {}, 'FENDEZY GROUP'), h('div', { class: 'dim' }, 'Headquarters' + (M.demo ? ' · demo' : ''))), banner, nav, h('div', { class: 'hq-body', 'data-screen': S.screen }, body)));
  }
  function render(box, ctx) { S.box = box; S.ctx = ctx; if (!S.hashRead) { S.hashRead = true; readHash(); } draw(); }
  root.HQ = { render, model, SCREENS, go, state: S };
})(typeof window !== 'undefined' ? window : globalThis);
