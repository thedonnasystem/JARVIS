'use strict';
// FENDEZY HQ screens + the text Jarvis (v1). Org names and policy come from hq/org.js (owner-provided). Missions planned here come from the
// OFFLINE planner (hq/jarvis.js): SIMULATED, stored in this browser only (localStorage, try/catch), never sent anywhere.
// Signed in (live mode), panels backed by the existing app_* reads are labelled LIVE, and the Chairman can hand an objective to the EXISTING
// mission engine through ctx.sendMission (app.js -> app_send kind 'mission', verb 'new': the same call the Missions tab already makes).
// No other network call, no LLM call, no HTML injection: all text is set as text nodes.
(function (root) {
  const doc = root.document;
  const SCREENS = [['overview', 'Overview'], ['jarvis', 'Jarvis'], ['missions', 'Missions'], ['org', 'Org chart'], ['divisions', 'Divisions'], ['offices', 'Offices'],
    ['managers', 'Managers'], ['agents', 'Agents'], ['activity', 'Activity'], ['finance', 'Finance'], ['health', 'Health']];
  const DETAIL_TYPES = { division: 1, mission: 1 };
  const STORE_NAME = 'fendezy.hq.sim.v1';   // browser-storage slot name (not a credential)
  const EXAMPLE = 'Research the Ottawa commercial cleaning market and prepare a business launch proposal.';
  const J = () => root.HQJarvis; const ORG = () => root.HQ_ORG;

  // ---------- helpers (text only) ----------
  function h(tag, attrs, ...kids) {
    const e = doc.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) { if (k === 'class') e.className = v; else if (k.startsWith('on')) e.addEventListener(k.slice(2), v); else if (v !== false && v != null) e.setAttribute(k, v); }
    for (const c of kids.flat(3)) if (c != null && c !== false) e.append(c.nodeType ? c : doc.createTextNode(String(c)));
    return e;
  }
  const usd = (c) => '$' + ((Number(c) || 0) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const pct = (a, b) => Math.min(100, Math.round(100 * (Number(a) || 0) / Math.max(1, Number(b) || 1)));
  const txt = (v, dflt) => (v == null || v === '' ? (dflt == null ? 'unknown' : dflt) : String(v));
  const when = (iso) => { const t = new Date(iso); return isNaN(t) ? '' : t.toISOString().slice(0, 16).replace('T', ' ') + ' UTC'; };
  const SRC = { LIVE: 'live', SIMULATED: 'sim', 'NOT CONNECTED': 'nc', 'OWNER-DEFINED · NOT CONNECTED': 'nc' };
  const TIPS = { LIVE: 'Read from the live database through an existing app_* function', SIMULATED: 'Demo / offline planner. Not live company data.', 'NOT CONNECTED': 'No live data source for this panel', 'OWNER-DEFINED · NOT CONNECTED': 'Owner-provided structure. The database has no division or office tables yet.' };
  const badge = (src) => h('span', { class: 'hq-badge b-' + SRC[src], title: TIPS[src] }, src);
  const panel = (title, src, ...body) => h('section', { class: 'card hq-panel', 'data-src': SRC[src] }, h('div', { class: 'row hq-ph' }, h('h3', {}, title), badge(src)), ...body);
  const dim = (t) => h('div', { class: 'dim' }, t);
  const kv = (a, b) => h('div', { class: 'row hq-kv' }, h('span', { class: 'dim' }, a), h('span', {}, b));
  const meter = (a, b) => h('div', { class: 'bar' }, h('i', { style: 'width:' + pct(a, b) + '%' }));
  const tag = (t, cls) => h('span', { class: 'tag ' + (cls || '') }, t);
  const btn = (label, fn, cls, extra) => h('button', Object.assign({ class: cls || 'ghost', type: 'button', onclick: fn }, extra || {}), label);
  const UN = 'Unassigned — awaiting owner';

  // ---------- state + local store ----------
  const S = { screen: 'overview', detail: null, ctx: null, box: null, draft: null, divPick: '', input: '', mfilter: 'open', msg: '', store: null };
  function store() {
    if (!S.store) { let raw = null; try { raw = root.localStorage.getItem(STORE_NAME); } catch (e) { raw = null; } S.store = raw ? J().load(raw) : J().emptyState(); }
    return S.store;
  }
  function save() { try { root.localStorage.setItem(STORE_NAME, JSON.stringify(S.store)); } catch (e) { /* private mode / blocked storage: keep in memory */ } }
  const live = () => !!(S.ctx && S.ctx.mode === 'live' && S.ctx.snap);
  const simSrc = 'SIMULATED';
  const orgSrc = () => (live() ? 'OWNER-DEFINED · NOT CONNECTED' : 'SIMULATED');
  const divName = (id) => (ORG().divisions.find((d) => d.id === id) || {}).name || txt(id, 'none');
  const offName = (id) => (ORG().corporate_offices.find((o) => o.id === id) || {}).name || txt(id, 'none');

  function readHash() {
    const raw = String((root.location && root.location.hash) || '').replace(/^#/, ''); if (!raw) return;
    const [scr, type, id] = raw.split('/').map((x) => { try { return decodeURIComponent(x); } catch (e) { return ''; } });
    if (SCREENS.some((x) => x[0] === scr)) { S.screen = scr; S.detail = DETAIL_TYPES[type] === 1 && id ? { type, id } : null; }
  }
  function writeHash() { try { const hs = '#' + S.screen + (S.detail ? '/' + S.detail.type + '/' + encodeURIComponent(S.detail.id) : ''); if (root.history && root.history.replaceState) root.history.replaceState(null, '', hs); } catch (e) {} }
  function go(screen, detail) { S.screen = screen; S.detail = detail || null; S.msg = ''; writeHash(); draw(); if (S.box && S.box.parentElement) S.box.parentElement.scrollTop = 0; }
  function mutate(res) { if (res && res.error) S.msg = res.error; else { S.msg = ''; save(); } draw(); }

  // ---------- live readers (only fields the existing app_snapshot already returns) ----------
  function liveState() {
    const s = S.ctx.snap; const st = s.state || {};
    const beat = st.last_heartbeat ? Math.round((Date.now() - new Date(st.last_heartbeat).getTime()) / 60000) : null;
    return { mode: txt(st.mode).replace(/_/g, '-'), kill: !!st.kill_switch, pause: st.pause_reason || '', cap: Number(st.cap_cents) || 0, spend: Number(s.spend_today_cents) || 0, beat };
  }
  function livePanel() {
    const L = liveState();
    return panel('Live controls (read-only)', 'LIVE', kv('Mode', L.mode), kv('Kill switch', L.kill ? 'ON: all agents stopped' : 'off'), L.pause ? kv('Paused', L.pause) : null,
      kv('AI spend today', usd(L.spend) + ' of ' + usd(L.cap) + ' daily cap'), meter(L.spend, L.cap), kv('Engine heartbeat', L.beat == null ? 'none recorded' : L.beat + ' min ago'),
      dim('Read from app_snapshot. Change controls only in the existing Home tab or Telegram.'));
  }

  // ---------- screens ----------
  function pendingApprovals() { return store().missions.filter((m) => !m.cancelled).flatMap((m) => m.approvals.filter((a) => a.status === 'pending').map((a) => ({ m, a }))); }

  function sOverview() {
    const st = store(); const O = ORG(); const P = O.policy;
    const counts = {}; st.missions.forEach((m) => { const k = J().missionStatus(m); counts[k] = (counts[k] || 0) + 1; });
    const pend = pendingApprovals();
    return [
      live() ? livePanel() : panel('Group status', simSrc, dim('Status as of ' + O.status_as_of.date + ', not live.'), ...O.status_as_of.items.slice(0, 4).map(([a, b]) => kv(a, b)), h('div', { class: 'btns' }, btn('Open system health', () => go('health')))),
      panel('Jarvis', simSrc, dim('Type an objective in plain language. Jarvis plans it, routes it to a division and offices, and lists what needs your approval. Planning is offline: no agent runs.'),
        h('div', { class: 'btns' }, btn('Give Jarvis an objective', () => go('jarvis'), ''))),
      panel('Needs your approval', simSrc, ...(pend.length ? pend.slice(0, 6).map(({ m, a }) => h('button', { class: 'hq-rowbtn', type: 'button', onclick: () => go('missions', { type: 'mission', id: m.id }) }, h('span', {}, a.text), h('span', { class: 'dim' }, m.id))) : [dim('Nothing waiting. Approvals appear here when Jarvis plans a mission.')]),
        live() ? dim('Live approvals from the database are in the Inbox tab.') : null),
      panel('Missions', simSrc, kv('Planned', String(counts.planned || 0)), kv('In progress', String(counts['in progress'] || 0)), kv('Blocked', String(counts.blocked || 0)), kv('Complete', String(counts.complete || 0)), kv('Cancelled', String(counts.cancelled || 0)),
        h('div', { class: 'btns' }, btn('Open missions', () => go('missions')))),
      panel('Organization', orgSrc(), kv('Divisions', O.divisions.length + ', all DORMANT'), kv('Group offices', String(O.corporate_offices.length)), kv('Division managers', UN), kv('Spend today', live() ? 'see Live controls' : '$0.00 (simulated)'), kv('AI daily cap (policy)', usd(P.ai_daily_cap_cents)),
        h('div', { class: 'btns' }, btn('Org chart', () => go('org')), btn('Finance', () => go('finance')))),
    ];
  }

  function planView(p) {
    const O = ORG(); const div = O.divisions.find((d) => d.id === p.division);
    const pick = h('select', { 'aria-label': 'Responsible division', class: 'hq-select', onchange: (e) => { S.divPick = e.target.value; S.draft = J().plan(S.draft.objective, O, { division: S.divPick }); draw(); } },
      O.divisions.map((d) => { const o = h('option', { value: d.id }, d.n + ' ' + d.name); if (d.id === p.division) o.selected = true; return o; }));
    const send = live() && S.ctx.sendMission ? btn('Also send to the live mission engine', () => {
      if (!root.confirm('Send this objective to the live mission engine (existing app_send mission/new)? The engine evaluates it under the existing caps, dry-run mode and approvals. The offline plan is not sent.')) return;
      Promise.resolve(S.ctx.sendMission(p.objective)).then((id) => { S.msg = id ? 'Objective sent to the live mission engine. It appears under Live missions once the engine records it.' : 'Not sent: see the message at the top.'; draw(); }).catch((e) => { S.msg = 'Not sent: ' + (e && e.message ? e.message : 'error'); draw(); });
    }) : null;
    return panel('Jarvis plan (draft)', simSrc, h('p', { class: 'hq-sim' }, p.note),
      h('h4', { class: 'hq-h4' }, '1. Understanding'), h('p', {}, p.understanding),
      h('h4', { class: 'hq-h4' }, '2. Task breakdown'), h('ol', { class: 'hq-ol' }, p.tasks.map((t) => h('li', {}, t.title, ' ', tag(t.kind), t.office ? h('span', { class: 'dim' }, ' · ' + offName(t.office)) : null))),
      h('h4', { class: 'hq-h4' }, '3. Responsible division'), pick, dim('Status: DORMANT. Confidence: ' + p.confidence + '. ' + p.why),
      kv('Supporting offices', p.offices.map(offName).join(', ')),
      h('h4', { class: 'hq-h4' }, '4. Proposed agents and AI cost (estimate)'),
      h('ul', { class: 'hq-ol' }, p.tasks.map((t) => h('li', {}, t.agent + ': ' + (t.est_cents ? usd(t.est_cents) + ' est.' : 'no AI cost')))),
      kv('Estimated AI cost', usd(p.est_cents) + ' vs ' + usd(p.cap_cents) + ' daily cap'), meter(p.est_cents, p.cap_cents),
      dim(p.within_cap ? 'Fits within one day at the cap. Estimates are planning assumptions, not measurements.' : 'Over the daily cap: would take ' + p.days_at_cap + ' days at the cap.'),
      h('h4', { class: 'hq-h4' }, '5. Deliverables expected'), h('ul', { class: 'hq-ol' }, p.deliverables.map((d) => h('li', {}, d))),
      h('h4', { class: 'hq-h4' }, '6. Needs your approval'), h('ul', { class: 'hq-ol hq-appr' }, p.approvals.map((a) => h('li', {}, tag(a.kind), ' ', a.text))),
      h('div', { class: 'btns' }, btn('Create mission (simulated)', () => {
        const m = J().createMission(store(), S.draft, O); if (!m) return; save(); S.draft = null; S.input = ''; S.divPick = ''; go('missions', { type: 'mission', id: m.id });
      }, ''), btn('Discard', () => { S.draft = null; draw(); })),
      send ? h('div', { class: 'btns' }, send) : null);
  }

  function sJarvis() {
    const ta = h('textarea', { id: 'hq-objective', rows: 3, maxlength: 600, 'aria-label': 'Objective for Jarvis', placeholder: 'e.g. ' + EXAMPLE, class: 'hq-input', oninput: (e) => { S.input = e.target.value; } });
    ta.value = S.input;
    const doPlan = () => { const p = J().plan(ta.value, ORG()); if (p.error) { S.msg = p.error; S.draft = null; } else { S.msg = ''; S.draft = p; S.divPick = ''; } S.input = ta.value; draw(); };
    const recent = store().missions.slice(0, 5);
    return [
      panel('Give Jarvis an objective', simSrc, ta, h('div', { class: 'btns' }, btn('Plan it', doPlan, ''), btn('Use example', () => { S.input = EXAMPLE; ta.value = EXAMPLE; doPlan(); })),
        dim('Offline planner: rule-based, zero AI cost, nothing leaves this device. It never runs agents, researches, contacts anyone or spends.')),
      S.draft ? planView(S.draft) : null,
      panel('Recent missions', simSrc, ...(recent.length ? recent.map((m) => missionRow(m)) : [dim('No missions yet.')])),
      panel('Live mission engine', live() ? 'LIVE' : 'NOT CONNECTED', live()
        ? dim('Signed in: after planning, "Also send to the live mission engine" hands the objective to the existing engine through app_send (mission/new), the same path as the Missions tab. Missions it records are listed under Missions as LIVE.')
        : dim('Not connected in demo mode. Signed in to the real app, Jarvis can hand an objective to the existing mission engine (app_send mission/new). Nothing is sent from here.')),
      panel('Voice', 'NOT CONNECTED', h('button', { type: 'button', class: 'ghost', disabled: 'disabled', 'aria-disabled': 'true' }, 'Voice (ElevenLabs) — planned after text Jarvis is stable')),
    ];
  }

  function missionRow(m) {
    const st = J().missionStatus(m);
    return h('button', { class: 'hq-rowbtn', type: 'button', onclick: () => go('missions', { type: 'mission', id: m.id }) },
      h('span', {}, h('b', {}, m.id), ' ', m.title), h('span', { class: 'dim' }, st + ' · ' + J().progress(m) + '%'));
  }

  function sMissions() {
    if (S.detail && S.detail.type === 'mission') { const m = store().missions.find((x) => x.id === S.detail.id); if (m) return missionDetail(m); }
    const all = store().missions;
    const f = { open: (m) => !['complete', 'cancelled'].includes(J().missionStatus(m)), all: () => true, complete: (m) => J().missionStatus(m) === 'complete', cancelled: (m) => m.cancelled };
    const list = all.filter(f[S.mfilter] || f.all);
    const chips = h('div', { class: 'hq-chips', role: 'group' }, [['open', 'Open'], ['complete', 'Complete'], ['cancelled', 'Cancelled'], ['all', 'All']].map(([k, l]) =>
      h('button', { class: 'chip' + (S.mfilter === k ? ' on' : ''), type: 'button', 'aria-pressed': String(S.mfilter === k), onclick: () => { S.mfilter = k; draw(); } }, l)));
    const out = [panel('Missions (offline planner)', simSrc, chips, ...(list.length ? list.map(missionRow) : [dim(all.length ? 'No missions in this filter.' : 'No missions yet. Give Jarvis an objective.')]),
      h('div', { class: 'btns' }, btn('New objective', () => go('jarvis'), '')))];
    if (live()) {
      const lm = Array.isArray(S.ctx.snap.missions) ? S.ctx.snap.missions : [];
      out.push(panel('Live missions (database)', 'LIVE', ...(lm.length ? lm.map((m) => h('div', { class: 'hq-sub' }, h('div', {}, txt(String(m.title || '').replace(/^Mission: /, ''), 'Untitled')),
        dim(txt(m.status) + (m.verdict ? ' · ' + m.verdict : '') + ' · spent ' + usd(m.spent_cents) + ' of ' + usd(m.budget_cents)), m.next_action ? dim('Next: ' + m.next_action) : null)) : [dim('No missions recorded in the database.')]),
        dim('Pause, resume or abandon these in the Missions tab.')));
    }
    return out;
  }

  function missionDetail(m) {
    const O = ORG(); const Jv = J(); const st = Jv.missionStatus(m); const stx = store();
    const taskRow = (t) => {
      const pg = Jv.pendingGates(m, t); const open = !m.cancelled && t.status !== 'done' && t.status !== 'cancelled';
      const nextLabel = t.status === 'doing' ? 'Mark done' : 'Start';
      return h('div', { class: 'hq-sub hq-task' }, h('div', { class: 'row' }, h('span', {}, h('b', {}, t.id), ' ', t.title), tag(t.status, 's-' + t.status.replace(/\s/g, ''))),
        dim([t.agent, t.office ? offName(t.office) : '', t.est_cents ? usd(t.est_cents) + ' est. AI' : '', t.kind !== 'internal' ? t.kind + ' action' : ''].filter(Boolean).join(' · ')),
        t.reason ? dim('Blocked: ' + t.reason) : null,
        open && pg.length ? dim('Waiting for your approval: ' + pg.join(', ')) : null,
        open ? h('div', { class: 'btns' }, btn(nextLabel, () => mutate(Jv.advanceTask(stx, m.id, t.id)), 'ghost', pg.length ? { disabled: 'disabled' } : null),
          t.status !== 'blocked' ? btn('Blocked', () => { const r = root.prompt ? root.prompt('What is blocking it?') : ''; if (r === null) return; mutate(Jv.blockTask(stx, m.id, t.id, r || '')); }) : null,
          btn('Cancel task', () => mutate(Jv.cancelTask(stx, m.id, t.id)))) : null);
    };
    const noteKind = h('select', { 'aria-label': 'Note type', class: 'hq-select' }, [['finding', 'Finding'], ['deliverable', 'Deliverable'], ['recommendation', 'Recommendation']].map(([v, l]) => h('option', { value: v }, l)));
    const noteText = h('textarea', { rows: 2, maxlength: 2000, 'aria-label': 'Note text', class: 'hq-input', placeholder: 'Record a finding, deliverable or recommendation (you write it; no agent has)' });
    const blk = Jv.blockers(m);
    return [
      btn('‹ Missions', () => go('missions'), 'ghost hq-back'),
      panel(m.id + ' · ' + m.title, simSrc, h('p', { class: 'hq-sim' }, m.note),
        kv('Status', st), kv('Progress', Jv.progress(m) + '%'), meter(Jv.progress(m), 100), kv('Owner', m.owner),
        kv('Division', divName(m.division) + ' (DORMANT)'), kv('Supporting offices', m.offices.map(offName).join(', ')), kv('Estimated AI cost', usd(m.est_cents) + ' (planning estimate)'), kv('Created', when(m.created_at)),
        h('p', {}, m.understanding)),
      panel('Tasks', simSrc, dim('Nothing advances by itself. You move each task by hand; every change is written to Activity.'), ...m.tasks.map(taskRow)),
      panel('Blockers', simSrc, ...(blk.length ? blk.map((b) => h('div', { class: 'hq-alert a-warn' }, b)) : [dim('No blockers.')])),
      panel('Needs your approval', simSrc, dim('Recorded in this browser only. Approving here authorizes nothing in the real company and runs nothing.'),
        ...m.approvals.map((a) => h('div', { class: 'hq-sub' }, h('div', { class: 'row' }, h('span', {}, h('b', {}, a.id), ' ', a.text), tag(a.status, 's-' + a.status)),
          !m.cancelled && a.status === 'pending' ? h('div', { class: 'btns' }, btn('Record approval', () => mutate(Jv.decide(stx, m.id, a.id, true))), btn('Decline', () => mutate(Jv.decide(stx, m.id, a.id, false)))) : null))),
      panel('Findings, deliverables and recommendations', simSrc,
        h('h4', { class: 'hq-h4' }, 'Expected deliverables'), h('ul', { class: 'hq-ol' }, m.deliverables.map((d) => h('li', {}, d.text + ' (' + d.status + ')'))),
        h('h4', { class: 'hq-h4' }, 'Recorded by the Chairman'), ...(m.notes.length ? m.notes.map((n) => h('div', { class: 'hq-sub' }, tag(n.kind), ' ', n.text, dim(when(n.at)))) : [dim('None yet. No agent has produced findings.')]),
        m.cancelled ? null : h('div', {}, noteKind, noteText, h('div', { class: 'btns' }, btn('Add note', () => mutate(Jv.addNote(stx, m.id, noteKind.value, noteText.value)))))),
      m.cancelled ? null : h('div', { class: 'btns' }, h('select', { 'aria-label': 'Reassign division', class: 'hq-select', onchange: (e) => { if (e.target.value) mutate(Jv.reassign(stx, m.id, e.target.value, O)); } },
        h('option', { value: '' }, 'Reassign division…'), O.divisions.filter((d) => d.id !== m.division).map((d) => h('option', { value: d.id }, d.name))),
        btn('Cancel mission', () => { if (root.confirm('Cancel ' + m.id + '? Open tasks become cancelled.')) mutate(Jv.cancelMission(stx, m.id)); }, 'bad')),
    ];
  }

  function sOrg() {
    const O = ORG(); const ti = O.corporate_offices.find((o) => o.id === 'technology-security');
    const node = (title, sub, kids, cls) => h('li', { class: 'hq-node ' + (cls || '') }, h('div', { class: 'hq-nb' }, h('b', {}, title), sub ? dim(sub) : null), kids && kids.length ? h('ul', { class: 'hq-tree' }, kids) : null);
    return [panel('Org chart', orgSrc(), dim('Reporting line: division managers report to Jarvis; Jarvis reports to the Chairman.'),
      h('ul', { class: 'hq-tree hq-root' }, node('Chairman', 'Final authority', [node('Jarvis', 'Group operator', [
        node('Divisions (8, all DORMANT)', null, O.divisions.map((d) => node(d.n + '. ' + d.name, 'Manager: ' + UN, null, 'k-div'))),
        node('Group offices (8)', null, O.corporate_offices.map((o) => node(o.name, 'Head: ' + UN, o === ti ? O.standing_functions.map((f) => node(f.name, 'Standing function. ' + f.note, null, 'k-std')) : null, 'k-off'))),
      ], 'k-jarvis')], 'k-chair')))];
  }

  function sDivisions() {
    const O = ORG();
    if (S.detail && S.detail.type === 'division') {
      const d = O.divisions.find((x) => x.id === S.detail.id);
      if (d) {
        const ms = store().missions.filter((m) => m.division === d.id);
        return [btn('‹ Divisions', () => go('divisions'), 'ghost hq-back'),
          panel(d.n + '. ' + d.name, orgSrc(), h('p', {}, d.charter.text), kv('Status', 'DORMANT'), kv('Authorized to operate', 'No'), kv('Authorized to spend', 'No'),
            kv('Manager', UN), kv('Reports to', 'Jarvis'), dim('Activating this division needs the Chairman\'s approval.')),
          panel('Missions routed here (offline planner)', simSrc, ...(ms.length ? ms.map(missionRow) : [dim('None.')]))];
      }
    }
    return [panel('Divisions', orgSrc(), dim('All eight are DORMANT: not authorized to operate or spend.'),
      h('div', { class: 'hq-grid' }, O.divisions.map((d) => h('button', { class: 'hq-div', type: 'button', onclick: () => go('divisions', { type: 'division', id: d.id }) },
        h('div', { class: 'row' }, h('h3', {}, d.n + '. ' + d.name), tag('DORMANT')), dim(d.charter.text), dim('Manager: ' + UN)))))];
  }

  function sOffices() {
    const O = ORG(); const ms = store().missions;
    return [panel('Group offices', orgSrc(), dim('Shared offices serve every division. Heads not yet defined by the owner.'),
      h('div', { class: 'hq-grid' }, O.corporate_offices.map((o) => h('div', { class: 'hq-div' }, h('h3', {}, o.name), dim('Head: ' + UN),
        dim('Supporting ' + ms.filter((m) => !m.cancelled && m.offices.includes(o.id)).length + ' simulated mission(s)'))))),
    panel('Standing functions', orgSrc(), ...O.standing_functions.map((f) => h('div', { class: 'hq-sub' }, h('b', {}, f.name), dim('Governed under ' + offName(f.governed_by) + '. ' + f.note), tag('owner to confirm'))))];
  }

  function sManagers() {
    const O = ORG();
    return [panel('Jarvis', orgSrc(), kv('Reports to', 'Chairman'), dim(O.jarvis.role)),
      panel('Division managers', orgSrc(), ...O.divisions.map((d) => h('div', { class: 'hq-sub row' }, h('span', {}, d.name), h('span', { class: 'dim' }, UN + ' · reports to Jarvis')))),
      panel('Office heads', orgSrc(), ...O.corporate_offices.map((o) => h('div', { class: 'hq-sub row' }, h('span', {}, o.name), h('span', { class: 'dim' }, UN))))];
  }

  function sAgents() {
    const roles = {}; store().missions.filter((m) => !m.cancelled).forEach((m) => m.tasks.forEach((t) => { if (/proposed/.test(t.agent)) (roles[t.agent] = roles[t.agent] || new Set()).add(m.id); }));
    const out = [];
    if (live()) {
      const ag = Array.isArray(S.ctx.snap.agents) ? S.ctx.snap.agents : [];
      out.push(panel('Agents in the database', 'LIVE', ...(ag.length ? ag.map((a) => h('div', { class: 'hq-sub' }, h('div', { class: 'row' }, h('b', {}, txt(a.title || a.slug, 'agent')), tag(txt(a.status))),
        dim(txt(a.role, 'no role') + ' · spent today ' + usd(a.spent_today) + ' of ' + usd(a.cap_cents)))) : [dim('No agents recorded.')])));
    }
    out.push(panel('Division workforce', orgSrc(), dim('No agents are assigned to any division. ' + UN + '.')));
    out.push(panel('Proposed by the offline planner', simSrc, dim('Roles Jarvis would need. None of these agents exists or has run.'),
      ...(Object.keys(roles).length ? Object.entries(roles).map(([r, ids]) => h('div', { class: 'hq-sub row' }, h('span', {}, r), h('span', { class: 'dim' }, [...ids].join(', ')))) : [dim('None yet.')])));
    return out;
  }

  function sActivity() {
    const a = store().activity;
    const out = [panel('Activity (offline planner and your manual changes)', simSrc, ...(a.length ? a.slice(0, 100).map((x) => h('div', { class: 'hq-sub' }, h('div', {}, x.text), dim(when(x.at)))) : [dim('No activity yet.')]))];
    if (live()) {
      const f = Array.isArray(S.ctx.snap.feed) ? S.ctx.snap.feed : [];
      out.unshift(panel('Execution history (database)', 'LIVE', ...(f.length ? f.slice(0, 40).map((x) => h('div', { class: 'hq-sub' }, h('div', {}, txt(x.text, '')), dim([txt(x.who, ''), txt(x.type, ''), txt(x.status, ''), x.at ? when(x.at) : ''].filter(Boolean).join(' · ')))) : [dim('No recorded activity.')])));
    }
    return out;
  }

  function sFinance() {
    const P = ORG().policy; const B = ORG().bank;
    const planned = store().missions.filter((m) => !m.cancelled).reduce((a, m) => a + m.tasks.filter((t) => t.status !== 'done' && t.status !== 'cancelled').reduce((b, t) => b + t.est_cents, 0), 0);
    return [
      live() ? livePanel() : panel('AI spend today', simSrc, kv('Spent today', '$0.00 SIMULATED'), kv('Daily cap (policy)', usd(P.ai_daily_cap_cents)), meter(0, P.ai_daily_cap_cents), dim('Demo mode: no spend is read or made.')),
      panel('Capital policy (read-only)', live() ? 'NOT CONNECTED' : simSrc, dim('Owner policy. Shown as written; not editable here and not read from the database.'),
        kv('Capital framework', usd(P.capital_framework_cents)), kv('Reserve', usd(P.reserve_cents)), kv('Hard stop', usd(P.hard_stop_cents)), kv('Low-cost mode at', usd(P.low_cost_mode_cents)),
        kv('Per-transaction limit', usd(P.per_transaction_limit_cents)), kv('Weekly limit', usd(P.weekly_limit_cents)), kv('Global daily AI cap', usd(P.ai_daily_cap_cents)),
        kv('Automatic reloads', P.automatic_reloads ? 'Yes' : 'None'), kv('New subscriptions', P.new_subscriptions), kv('Tax set-aside', P.tax_set_aside_pct + '%'),
        kv('Operating buffer', P.operating_buffer_months + ' months'), kv('Reinvestment pool', P.reinvestment_pool.join(' / ') + ' split'), kv('Max active revenue ventures', String(P.max_active_revenue_ventures)),
        kv('Bank reconciliation', 'Manual')),
      panel('Bank: ' + B.name, live() ? 'NOT CONNECTED' : simSrc, kv('Balance', B.status), dim('No balance is shown. Reconcile manually.')),
      panel('Planned AI cost of open simulated missions', simSrc, kv('Estimated, not spent', usd(planned)), dim('Planning estimates from the offline planner. Nothing has been spent.')),
    ];
  }

  function sHealth() {
    const O = ORG(); const out = [];
    if (live()) {
      out.push(livePanel());
      const sys = Array.isArray(S.ctx.snap.systems) ? S.ctx.snap.systems : [];
      out.push(panel('Registered systems', 'LIVE', ...(sys.length ? sys.map((x) => kv(txt(x.name, 'system'), txt(x.status))) : [dim('None registered.')])));
    }
    out.push(panel('System and security status', live() ? 'NOT CONNECTED' : simSrc, dim('Status as of ' + O.status_as_of.date + ', not live.'), ...O.status_as_of.items.map(([a, b]) => kv(a, b))));
    out.push(panel('Engineering & Reliability', orgSrc(), dim(O.standing_functions[0].note)));
    return out;
  }

  // ---------- frame ----------
  function draw() {
    if (!S.box) return;
    const fn = { overview: sOverview, jarvis: sJarvis, missions: sMissions, org: sOrg, divisions: sDivisions, offices: sOffices, managers: sManagers, agents: sAgents, activity: sActivity, finance: sFinance, health: sHealth }[S.screen] || sOverview;
    const banner = live()
      ? h('div', { class: 'hq-banner mixed', role: 'note' }, 'Signed in. LIVE panels read the database through existing app_* functions. SIMULATED panels come from the offline planner in this browser. Division and office names are the owner\'s structure; the database has no division tables yet.')
      : h('div', { class: 'hq-banner demo', role: 'note' }, 'SIMULATED. Demo mode: nothing here is live company data. ' + J().SIM_NOTE.replace(/^SIMULATED\. /, '') + ' Division and office names are the owner\'s structure.');
    const nav = h('nav', { class: 'hq-nav', 'aria-label': 'HQ screens' }, SCREENS.map(([k, l]) => h('button', { class: 'chip' + (S.screen === k ? ' on' : ''), type: 'button', 'data-screen': k, 'aria-current': S.screen === k ? 'page' : null, onclick: () => go(k) }, l)));
    let body; try { body = fn(); } catch (e) { body = [panel('Error', simSrc, dim('This screen failed to render: ' + (e && e.message ? e.message : 'error')))]; }
    S.box.replaceChildren(h('div', { class: 'hq' }, h('div', { class: 'hq-head' }, h('h1', {}, 'FENDEZY HQ')), banner, nav,
      S.msg ? h('div', { class: 'hq-alert a-warn', role: 'status' }, S.msg) : null, ...[].concat(body).filter(Boolean)));
  }

  function render(box, ctx) {
    const first = !S.box; S.box = box; S.ctx = ctx || { mode: 'demo' };
    if (first) readHash();
    // never redraw over the Chairman's typing: live refreshes arrive every few seconds
    const a = doc.activeElement; if (!first && a && box.contains(a) && /^(TEXTAREA|SELECT|INPUT)$/.test(a.tagName)) return;
    draw();
  }
  root.HQ = { render, SCREENS, _state: S, _reset: () => { S.store = null; S.draft = null; S.input = ''; S.msg = ''; S.detail = null; S.screen = 'overview'; } };
})(window);
