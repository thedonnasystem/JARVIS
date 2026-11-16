import test from 'node:test';
import assert from 'node:assert/strict';
import { boot, backend, read } from './lib/harness.mjs';

const DEMO_URL = 'https://fendezy-hq-app.onrender.com/?demo=1';
const SCREENS = ['overview', 'jarvis', 'missions', 'org', 'divisions', 'offices', 'managers', 'agents', 'activity', 'finance', 'health'];
const OTTAWA = 'Research the Ottawa commercial cleaning market and prepare a business launch proposal.';
const noRpc = () => { throw new Error('demo mode must not call the database'); };
async function demo(extra = {}) {
  const app = await boot({ rpc: noRpc, url: DEMO_URL + (extra.hash || ''), session: null, confirms: [], confirmAnswer: extra.confirmAnswer });
  const errs = []; const orig = app.win.console.error; app.win.console.error = (...a) => { errs.push(a.join(' ')); orig.apply(app.win.console, a); };
  // record any attempt to reach the network from the page
  app.net = []; const w = app.win;
  w.fetch = (...a) => { app.net.push(['fetch', String(a[0])]); return Promise.reject(new Error('blocked')); };
  const xo = w.XMLHttpRequest.prototype.open; w.XMLHttpRequest.prototype.open = function (...a) { app.net.push(['xhr', String(a[1])]); return xo.apply(this, a); };
  w.WebSocket = function (u) { app.net.push(['ws', String(u)]); throw new Error('blocked'); };
  app.errs = errs; return app;
}
const chip = (app, k) => app.$('.hq-nav [data-screen="' + k + '"]');
const view = (app) => app.$('#v-hq');
const J = (app) => app.win.HQJarvis; const ORG = (app) => app.win.HQ_ORG;
async function planIt(app, text) {
  await app.click(chip(app, 'jarvis'));
  const ta = app.$('#hq-objective'); ta.value = text; ta.dispatchEvent(new app.win.Event('input', { bubbles: true }));
  await app.click(app.button('#v-hq', 'Plan it'));
}
async function createMission(app, text) { await planIt(app, text); await app.click(app.button('#v-hq', 'Create mission (simulated)')); }

// ---------- demo mode: shell ----------
test('demo mode: no login, zero database calls, SIMULATED banner, nav of 11 HQ screens', async () => {
  const app = await demo();
  assert.equal(app.$('#login').hidden, true); assert.equal(app.$('#app').hidden, false); assert.equal(app.$('#tabs').hidden, true);
  assert.equal(app.calls.length, 0);
  assert.match(view(app).querySelector('.hq-banner').textContent, /^SIMULATED\. Demo mode: nothing here is live company data\. Planned by the offline planner\. No agent has run\. No research was performed\./);
  assert.deepEqual(app.all('.hq-nav [data-screen]').map((b) => b.getAttribute('data-screen')), SCREENS);
  assert.equal(app.win.__errors.length, 0); app.stop();
});

for (const k of SCREENS) {
  test(`demo screen "${k}": renders, every panel carries SIMULATED (or NOT CONNECTED), never LIVE, no placeholder leaks`, async () => {
    const app = await demo();
    await createMission(app, OTTAWA);           // so mission-dependent panels are populated too
    await app.click(chip(app, k));
    const panels = app.all('#v-hq .hq-panel'); assert.ok(panels.length > 0);
    for (const p of panels) { const b = p.querySelector('.hq-badge'); assert.ok(b, 'panel without badge: ' + p.textContent.slice(0, 40)); assert.match(b.textContent, /^(SIMULATED|NOT CONNECTED)$/); }
    assert.ok(panels.some((p) => p.querySelector('.hq-badge').textContent === 'SIMULATED'), 'screen has a SIMULATED panel');
    assert.ok(!app.all('#v-hq .hq-badge').some((b) => /LIVE/.test(b.textContent)), 'demo never shows LIVE');
    assert.doesNotMatch(view(app).textContent, /\b(null|undefined|NaN)\b|\[object Object\]/);
    assert.equal(app.calls.length, 0); assert.deepEqual(app.net, []); assert.equal(app.errs.length, 0, app.errs.join('|')); assert.equal(app.win.__errors.length, 0);
    app.stop();
  });
}

// ---------- organization: owner-provided only ----------
test('org data: the owner\'s 8 divisions and 8 offices; Donna/Wolf Squad/FF Marketing preparing (1-3), five dormant; nobody appointed', async () => {
  const app = await demo(); const O = ORG(app);
  assert.deepEqual([...O.divisions].map((d) => d.name), ['B2B Records', 'Donna', 'The Trap', 'Wolf Squad', 'Pimp AI', 'Monopoly', 'FF Marketing', 'Fruition Factory']);
  assert.deepEqual([...O.corporate_offices].map((o) => o.name), ['Business Development', 'Marketing & Growth', 'Sales & Revenue', 'Operations & Automation', 'Finance & Capital', 'Legal, Risk & Compliance', 'Intelligence & Research', 'Technology & Security']);
  assert.ok(O.divisions.every((d) => !d.authorized_to_operate && !d.authorized_to_spend && d.manager.assigned === null && d.manager.reports_to === 'jarvis'));
  assert.deepEqual([...O.divisions.filter((d) => d.status === 'preparing')].map((d) => [d.id, d.activation_order]), [['donna', 1], ['wolf-squad', 2], ['ff-marketing', 3]]);
  assert.deepEqual([...O.divisions.filter((d) => d.status === 'dormant')].map((d) => d.id), ['b2b-records', 'the-trap', 'pimp-ai', 'monopoly', 'fruition-factory']);
  assert.equal(O.status_text.preparing, 'Preparing for activation — not authorized to spend, sign contracts, contact prospects or launch publicly');
  assert.equal(O.status_text.dormant, 'Dormant');
  assert.ok(O.corporate_offices.every((o) => o.head.assigned === null && o.head.reports_to === 'jarvis'));
  assert.equal(O.jarvis.reports_to, 'chairman');
  app.stop();
});

test('Engineering & Reliability: approved permanent function under Technology & Security, constraint shown, no "owner to confirm"', async () => {
  const app = await demo(); const O = ORG(app); const f = O.standing_functions[0];
  assert.deepEqual([...O.standing_functions].map((x) => [x.name, x.governed_by, x.permanent, x.status]), [['Engineering & Reliability', 'technology-security', true, 'approved']]);
  assert.deepEqual([...f.responsibilities], ['Platform reliability', 'Infrastructure and deployment health', 'Testing and release engineering', 'Incident detection and recovery', 'Monitoring and rollback readiness', 'Technical documentation and system integrity']);
  assert.equal(f.constraint, 'Cannot independently approve its own critical production changes.');
  assert.equal(f.head.assigned, null); assert.equal(f.head.reports_to, 'technology-security');
  for (const k of ['org', 'offices', 'managers', 'health']) {
    await app.click(chip(app, k)); const t = view(app).textContent;
    assert.match(t, /Engineering & Reliability/, k); assert.match(t, /Cannot independently approve its own critical production changes\./, k);
    assert.ok(!/owner to confirm|awaiting owner/i.test(t), k);
  }
  await app.click(chip(app, 'offices')); const t = view(app).textContent;
  for (const r of f.responsibilities) assert.ok(t.includes(r), r);
  assert.match(t, /APPROVED/);
  for (const src of ['webapp/hq/org.js', 'webapp/hq/hq.js']) assert.ok(!/owner to confirm/.test(read(src)), src);
  app.stop();
});

test('managers: all 17 positions read exactly "Unassigned — awaiting Chairman\'s appointment." with a PROPOSED role each; no names invented', async () => {
  const app = await demo(); const O = ORG(app); const UN = 'Unassigned — awaiting Chairman\'s appointment.';
  assert.equal(O.unassigned_text, UN);
  const ids = [...O.divisions.map((d) => d.id), ...O.corporate_offices.map((o) => o.id), 'engineering-reliability'];
  assert.deepEqual(Object.keys(O.proposed_roles).sort(), [...ids].sort());
  for (const id of ids) { const r = O.proposed_roles[id]; assert.ok(r.role && r.responsibilities.length >= 3 && r.selection_criteria.length >= 3, id); }
  assert.equal(O.proposed_label, 'PROPOSED — for Chairman approval');
  assert.match(O.appointment_note, /Jarvis may recommend candidates or agent configurations but cannot grant permissions/);
  assert.deepEqual({ ...O.reporting_lines }, { division: 'Division manager -> Jarvis -> Chairman', office: 'Office head -> Jarvis -> Chairman', standing_function: 'Engineering & Reliability lead -> Technology & Security' });
  await app.click(chip(app, 'managers'));
  const t = view(app).textContent;
  assert.equal(t.split(UN).length - 1, 17, 'one per position');
  assert.equal(app.all('#v-hq details.hq-role').length, 17);
  assert.equal((t.match(/PROPOSED — for Chairman approval/g) || []).length, 18, '17 roles + the panel note');
  assert.equal((t.match(/Division manager -> Jarvis -> Chairman/g) || []).length, 8);
  assert.equal((t.match(/Office head -> Jarvis -> Chairman/g) || []).length, 8);
  assert.equal((t.match(/Engineering & Reliability lead -> Technology & Security/g) || []).length, 1);
  assert.match(t, /cannot grant permissions/);
  assert.ok(!/awaiting owner/.test(t));
  // the docs carry the same proposals
  const doc = read('ORG_ROLES_PROPOSED.md');
  assert.match(doc, /PROPOSED — for Chairman approval/); assert.match(doc, /cannot grant permissions/);
  for (const id of ids) { const r = O.proposed_roles[id]; assert.ok(doc.includes(r.role), id); r.responsibilities.concat(r.selection_criteria).forEach((x) => assert.ok(doc.includes(x), id + ': ' + x)); }
  app.stop();
});

test('org chart and divisions: preparing vs dormant shown, Donna detail carries its status, order and proposed role', async () => {
  const app = await demo();
  await app.click(chip(app, 'org'));
  assert.match(view(app).textContent, /Chairman[\s\S]*Jarvis[\s\S]*Divisions \(8: 3 preparing for activation, 5 dormant\)[\s\S]*1\. B2B Records[\s\S]*DORMANT[\s\S]*2\. Donna[\s\S]*PREPARING · order 1[\s\S]*8\. Fruition Factory[\s\S]*Group offices \(8\)[\s\S]*Technology & Security[\s\S]*Engineering & Reliability/);
  await app.click(chip(app, 'divisions')); assert.equal(app.all('#v-hq .hq-grid .hq-div').length, 8);
  const cards = app.all('#v-hq .hq-grid .hq-div').map((c) => c.textContent);
  assert.deepEqual(cards.map((c) => (/PREPARING · order (\d)/.exec(c) || [])[1] || (/DORMANT/.test(c) ? 'D' : '?')), ['D', '1', 'D', '2', 'D', 'D', '3', 'D']);
  await app.click(app.all('#v-hq .hq-grid .hq-div')[1]);
  assert.match(view(app).textContent, /2\. Donna[\s\S]*AI agency, automation and business process systems\.[\s\S]*Status\s*Preparing for activation — not authorized to spend, sign contracts, contact prospects or launch publicly[\s\S]*Activation order\s*1[\s\S]*Authorized to spend\s*No[\s\S]*Manager\s*Unassigned — awaiting Chairman's appointment\.[\s\S]*PROPOSED — for Chairman approval/);
  assert.equal(app.win.location.hash, '#divisions/division/donna');
  app.stop();
});

test('no invented names, numbers or personal-notes content anywhere in the HQ code', () => {
  const banned = ['Energy Sales', 'Day Job', 'Day-Job', 'dials', 'Pitches today', 'garage cleanout', 'Real Estate Wholesale', 'Donna Systems', 'Province', 'Ontario', 'Alberta', 'mortgage', 'insurance client',
    'Client A', 'HVAC', 'Collin', 'Texas', 'soccer', 'football', 'Executive Office', 'New Ventures Lab', 'Engineering & Platform', 'Verification Desk', 'Idea Testing', 'Core Platform', 'Agent Management', 'HQ_DEMO', 'demo_data'];
  for (const f of ['webapp/hq/org.js', 'webapp/hq/jarvis.js', 'webapp/hq/hq.js', 'webapp/hq/hq.css']) {
    const src = read(f);
    for (const b of banned) assert.ok(!src.toLowerCase().includes(b.toLowerCase()), f + ' contains removed content: ' + b);
    assert.ok(!/[\w.+-]+@[\w-]+\.[a-z]{2,}/i.test(src), f + ' email'); assert.ok(!/\b\d{3}[-. ]\d{3}[-. ]\d{4}\b/.test(src), f + ' phone');
  }
  // every money figure in the org file is one of the owner's policy numbers
  const cents = [...read('webapp/hq/org.js').matchAll(/_cents:\s*(\d+)/g)].map((m) => Number(m[1])).sort((a, b) => a - b);
  assert.deepEqual(cents, [330, 2000, 2500, 5000, 7500, 10000, 30000]);
});

// ---------- planner ----------
const ROUTES = [
  [OTTAWA, 'fruition-factory', ['business-development', 'intelligence-research']],
  ['Plan the release of a new single and music video for one of our artists', 'b2b-records'],
  ['Sign a new artist and plan their first album', 'b2b-records'],
  ['Build an AI receptionist automation for a dental clinic', 'donna'],
  ['Design a workflow automation and CRM integration for a client agency', 'donna'],
  ['Launch a Shopify store for phone accessories', 'the-trap'],
  ['Find a supplier and prototype a new product for our e-commerce line', 'the-trap'],
  ['Book 20 sales appointments with local contractors through cold calling', 'wolf-squad'],
  ['Build a prospect list and grow our sales pipeline', 'wolf-squad'],
  ['Create an AI influencer brand and grow subscribers with compliant content monetization', 'pimp-ai'],
  ['Find off-market land to acquire for wholesale', 'monopoly'],
  ['Analyze rental properties for a duplex acquisition', 'monopoly'],
  ['Run a TikTok ad campaign to grow our audience', 'ff-marketing'],
  ['Write a newsletter and social media content plan for brand awareness', 'ff-marketing'],
  ['Validate three new venture ideas and pick one to explore', 'fruition-factory'],
];
test('planner routes 15 objectives across all 8 divisions (Ottawa cleaning -> Fruition Factory + Intelligence & Research + Business Development)', async () => {
  const app = await demo(); const O = ORG(app);
  const hit = new Set();
  for (const [obj, div, offices] of ROUTES) {
    const p = J(app).plan(obj, O); assert.equal(p.division, div, obj); hit.add(p.division);
    if (offices) assert.deepEqual([...p.offices].sort(), offices, obj);
    assert.ok(p.tasks.length >= 3 && p.tasks.every((t) => t.title && typeof t.est_cents === 'number'), obj);
    assert.equal(p.note, 'SIMULATED. Planned by the offline planner. No agent has run. No research was performed.');
    assert.equal(p.cap_cents, 330); assert.equal(p.within_cap, p.est_cents <= 330);
  }
  assert.equal(hit.size, 8, 'all eight divisions reached');
  const g = J(app).plan('hello there friend', O); assert.equal(g.division, 'fruition-factory'); assert.equal(g.confidence, 'low');
  assert.ok(J(app).plan('hi', O).error, 'too short is rejected');
  assert.equal(J(app).plan(OTTAWA, O, { division: 'donna' }).division, 'donna', 'Chairman override');
  app.stop();
});

test('approval list is never empty and covers money, external contact, activation and production', async () => {
  const app = await demo(); const O = ORG(app);
  for (const [obj] of ROUTES) {
    const k = J(app).plan(obj, O).approvals.map((a) => a.kind);
    assert.ok(k.includes('activation') && k.includes('money'), obj);
  }
  const kinds = (o) => J(app).plan(o, O).approvals.map((a) => a.kind);
  assert.ok(kinds('Email 30 restaurant owners and pitch our service').includes('external'));
  assert.ok(kinds('Spend $40 on Facebook ads for the store').filter((x) => x === 'money').length >= 2);
  assert.ok(kinds('Build an AI receptionist automation and deploy it to production').includes('production'));
  assert.ok(kinds('Move money from the RBC bank account to pay a contractor').includes('protected'));
  const big = J(app).plan('Research competitors, build a prospect list, email leads, launch a Shopify store, run an ad campaign and build an automation', O);
  assert.equal(big.within_cap, big.est_cents <= 330); assert.equal(big.days_at_cap, Math.max(1, Math.ceil(big.est_cents / 330)));
  assert.ok(big.tasks.length <= 11, 'task list stays short');
  // a mission routed to a division preparing for activation still needs activation, spend and contact approval
  for (const [obj, div] of [['Build an AI receptionist automation for a dental clinic', 'donna'], ['Build a prospect list and grow our sales pipeline', 'wolf-squad'], ['Write a newsletter and social media content plan for brand awareness', 'ff-marketing']]) {
    const p = J(app).plan(obj, O); assert.equal(p.division, div); const k = p.approvals.map((a) => a.kind);
    assert.ok(k.includes('activation') && k.includes('money') && k.includes('external'), obj);
    assert.match(p.approvals[0].text, /PREPARING FOR ACTIVATION and is not authorized to spend, sign contracts, contact prospects or launch publicly/);
  }
  assert.match(J(app).plan(OTTAWA, O).approvals[0].text, /DORMANT and not authorized to operate or spend/);
  app.stop();
});

test('Jarvis screen: plan shows understanding, tasks, division, agents + cost vs $3.30 cap, deliverables and approvals', async () => {
  const app = await demo(); await planIt(app, OTTAWA);
  const t = view(app).textContent;
  assert.match(t, /1\. Understanding[\s\S]*You want: Research the Ottawa commercial cleaning market[\s\S]*2\. Task breakdown[\s\S]*Desk research from public sources[\s\S]*3\. Responsible division[\s\S]*Fruition Factory[\s\S]*Supporting offices\s*Business Development, Intelligence & Research[\s\S]*4\. Proposed agents and AI cost[\s\S]*\(proposed, not created\)[\s\S]*vs \$3\.30 daily cap[\s\S]*5\. Deliverables expected[\s\S]*6\. Needs your approval[\s\S]*Activate Fruition Factory[\s\S]*Run agents/);
  assert.match(t, /Planned by the offline planner\. No agent has run\. No research was performed\./);
  assert.ok(app.button('#v-hq', 'Voice (ElevenLabs) — planned after text Jarvis is stable').disabled);
  assert.equal(app.button('#v-hq', 'Also send to the live mission engine'), undefined, 'no live hand-off in demo');
  const sel = app.$('#v-hq select[aria-label="Responsible division"]'); sel.value = 'monopoly'; sel.dispatchEvent(new app.win.Event('change', { bubbles: true })); await app.click(sel); // re-render
  assert.match(view(app).textContent, /Activate Monopoly/);
  await planIt(app, 'hi'); assert.match(view(app).textContent, /at least a short sentence/);
  assert.equal(app.calls.length, 0); assert.deepEqual(app.net, []); app.stop();
});

test('missions: create, approvals gate tasks, manual advance/block/cancel, notes, activity log, persistence', async () => {
  const app = await demo(); await createMission(app, OTTAWA);
  assert.equal(app.win.location.hash, '#missions/mission/SIM-0001');
  let t = view(app).textContent;
  assert.match(t, /SIM-0001[\s\S]*Status\s*planned[\s\S]*Progress\s*0%[\s\S]*Owner\s*Chairman[\s\S]*Fruition Factory \(DORMANT\)/);
  assert.match(t, /Blockers[\s\S]*waiting for your approval A1, A2/);
  const st = app.win.HQ._state.store; const m = st.missions[0];
  assert.ok(m.tasks.every((x) => x.status === 'todo'), 'nothing is auto-advanced');
  // a gated task cannot start before approval
  assert.ok(J(app).advanceTask(st, m.id, 'T2').error);
  const startT2 = () => app.all('#v-hq .hq-task').find((d) => d.textContent.startsWith('T2')).querySelector('button');
  assert.ok(startT2().disabled);
  await app.click(app.all('#v-hq button').find((b) => b.textContent === 'Record approval')); // A1
  await app.click(app.all('#v-hq button').find((b) => b.textContent === 'Record approval')); // A2
  assert.ok(!startT2().disabled);
  await app.click(startT2()); assert.equal(m.tasks[1].status, 'doing'); assert.match(view(app).textContent, /Status\s*in progress/);
  await app.click(startT2()); assert.equal(m.tasks[1].status, 'done');
  app.win.prompt = () => 'waiting on a decision';
  await app.click(app.all('#v-hq .hq-task').find((d) => d.textContent.startsWith('T3')).querySelectorAll('button')[1]);
  assert.equal(m.tasks[2].status, 'blocked'); assert.match(view(app).textContent, /Status\s*blocked[\s\S]*waiting on a decision/);
  await app.click(app.all('#v-hq .hq-task').find((d) => d.textContent.startsWith('T4')).querySelectorAll('button')[2]);
  assert.equal(m.tasks[3].status, 'cancelled');
  const ta = app.$('#v-hq textarea[aria-label="Note text"]'); ta.value = 'Owner note <b>bold</b>';
  await app.click(app.button('#v-hq', 'Add note')); assert.equal(m.notes.length, 1); assert.equal(app.all('#v-hq b').filter((b) => b.textContent === 'bold').length, 0);
  // persisted in localStorage and reloaded from it
  const raw = app.win.localStorage.getItem('fendezy.hq.sim.v1'); assert.ok(raw && JSON.parse(raw).missions[0].id === 'SIM-0001');
  app.win.HQ._reset(); app.win.HQ._state.screen = 'missions'; app.win.HQ.render(view(app), { mode: 'demo' });
  assert.equal(app.win.HQ._state.store.missions[0].tasks[1].status, 'done', 'reloaded from storage');
  // cancel mission
  app.win.HQ._state.detail = { type: 'mission', id: 'SIM-0001' }; app.win.HQ.render(view(app), { mode: 'demo' });
  await app.click(app.button('#v-hq', 'Cancel mission'));
  const m2 = app.win.HQ._state.store.missions[0]; assert.equal(J(app).missionStatus(m2), 'cancelled'); assert.equal(m2.tasks[1].status, 'done', 'done stays done');
  await app.click(chip(app, 'activity'));
  const act = view(app).textContent;
  for (const re of [/planned by the offline planner/, /approval A1 recorded as approved/, /T2 moved todo -> doing/, /T2 moved doing -> done/, /T3 marked blocked/, /T4 cancelled/, /finding added/, /SIM-0001 cancelled by the Chairman/]) assert.match(act, re);
  assert.equal(app.calls.length, 0); assert.deepEqual(app.net, []); assert.equal(app.errs.length, 0); app.stop();
});

test('storage failures and corrupt storage never break the HQ', async () => {
  const app = await demo();
  app.win.localStorage.setItem('fendezy.hq.sim.v1', '{"v":1,"missions":[{"id":5}],"activity":"x"}');
  app.win.HQ._reset(); app.win.HQ.render(view(app), { mode: 'demo' });
  assert.equal(app.win.HQ._state.store.missions.length, 0);
  Object.defineProperty(app.win, 'localStorage', { get() { throw new Error('denied'); } });
  app.win.HQ._reset(); app.win.HQ.render(view(app), { mode: 'demo' });
  await createMission(app, OTTAWA); assert.match(view(app).textContent, /SIM-0001/);
  assert.equal(app.win.__errors.length, 0); app.stop();
});

test('finance: policy shown read-only, RBC never shows a number, spend is $0.00 SIMULATED', async () => {
  const app = await demo(); await app.click(chip(app, 'finance'));
  const t = view(app).textContent;
  for (const re of [/Capital framework\s*\$300\.00/, /Reserve\s*\$50\.00/, /Hard stop\s*\$20\.00/, /Low-cost mode at\s*\$100\.00/, /Per-transaction limit\s*\$25\.00/, /Weekly limit\s*\$75\.00/, /Global daily AI cap\s*\$3\.30/,
    /Automatic reloads\s*None/, /New subscriptions\s*Not without Chairman approval/, /Tax set-aside\s*33%/, /Operating buffer\s*1\.5 months/, /Reinvestment pool\s*60 \/ 25 \/ 15/, /Max active revenue ventures\s*3/, /Spent today\s*\$0\.00 SIMULATED/]) assert.match(t, re);
  const bank = app.all('#v-hq .hq-panel').find((p) => /Bank: RBC/.test(p.textContent));
  assert.match(bank.textContent, /Not connected — manual reconciliation required/); assert.doesNotMatch(bank.textContent, /\d/, 'no number of any kind in the bank panel');
  assert.equal(app.all('#v-hq input, #v-hq select').length, 0, 'nothing editable on Finance');
  app.stop();
});

test('finance: reinvestment pool shows the ledger definitions as current and the Chairman\'s labels as proposed, in conflict; ledger untouched', async () => {
  const app = await demo(); await app.click(chip(app, 'finance'));
  const pool = app.all('#v-hq .hq-panel').find((p) => /^Reinvestment pool/.test(p.querySelector('h3').textContent));
  const t = pool.textContent;
  assert.match(t, /Current \(ledger definitions\)\s*Best venture\s*60%\s*Research and systems\s*25%\s*Held for a deal\s*15%/);
  assert.match(t, /Chairman's proposed labels\s*Proposed labels — conflict with ledger definitions, awaiting Chairman confirmation\s*Growth & Reinvestment\s*60%\s*Strategic Capital\s*25%\s*Innovation & New Ventures\s*15%/);
  assert.match(t, /Conflict: .*25%.*15%/);
  assert.match(t, /33% tax set-aside and the 1\.5-month operating buffer are separate/);
  // the ledger keeps its own meaning: pool_best / pool_research / pool_deal at 60 / 25 / 15
  assert.match(read('migrations/20261112_finance_rules_v1.sql'), /pool_best_pct numeric not null default 60, pool_research_pct numeric not null default 25, pool_deal_pct numeric not null default 15/);
  assert.match(read('hq_waterfall.py'), /best venture .*research and systems .*held for a deal/);
  app.stop();
});

test('health: status as of a date, not live, with the known state', async () => {
  const app = await demo(); await app.click(chip(app, 'health'));
  assert.match(view(app).textContent, /Status as of 2026-11-16, not live\.[\s\S]*Production\s*Untouched[\s\S]*ecadb31[\s\S]*Dry-run[\s\S]*Kill switch\s*Off[\s\S]*Executor registry\s*Empty[\s\S]*#16, #17, #20\s*In final verification[\s\S]*Awaiting Chairman authorization/);
  app.stop();
});

test('XSS: hostile objective text is rendered as text everywhere', async () => {
  const app = await demo(); const evil = '<img src=x onerror=window.__pwn=1><script>window.__pwn=2</script> research the market';
  await createMission(app, evil);
  for (const k of SCREENS) { await app.click(chip(app, k)); assert.equal(app.all('#v-hq img').length, 0, k); assert.equal(app.all('#v-hq script').length, 0, k); }
  await app.click(chip(app, 'missions')); assert.ok(view(app).textContent.includes('<img src=x'));
  const deep = await demo({ hash: '#missions/mission/%3Cimg%20src%3Dx%20onerror%3Dwindow.__pwn%3D1%3E' }); assert.equal(deep.all('#v-hq img').length, 0); deep.stop();
  assert.equal(app.win.__pwn, undefined); app.stop();
});

test('hq code: no innerHTML, no network, no eval, no LLM; storage only via the wrapped helpers; CSP unchanged', () => {
  for (const f of ['webapp/hq/hq.js', 'webapp/hq/jarvis.js', 'webapp/hq/org.js']) {
    const src = read(f);
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(src), f + ' html injection');
    assert.ok(!/\bfetch\s*\(|XMLHttpRequest|WebSocket|sendBeacon|eval\s*\(|new Function|importScripts|sessionStorage|\.rpc\s*\(|rpc\(/.test(src), f + ' network/eval');
    assert.ok(!/https?:\/\//.test(src), f + ' external url');
    assert.ok(!/anthropic|openai|elevenlabs\.io|api\./i.test(src), f + ' no AI/voice API');
  }
  assert.ok(!/localStorage/.test(read('webapp/hq/jarvis.js')) && !/localStorage/.test(read('webapp/hq/org.js')));
  assert.equal((read('webapp/hq/hq.js').match(/localStorage\.\w+/g) || []).length, 2, 'one getItem + one setItem, both in try/catch');
  const html = read('webapp/index.html');
  assert.match(html, /script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https:\/\/ihxzvpwbqydqtblvazbq\.supabase\.co wss:\/\/ihxzvpwbqydqtblvazbq\.supabase\.co/);
});

// ---------- signed-in (live) mode ----------
test('live mode: existing reads shown as LIVE, planner stays SIMULATED, org is owner-defined; no new RPCs', async () => {
  const app = await boot({ rpc: backend() }); await app.tab('hq');
  assert.match(view(app).querySelector('.hq-banner').textContent, /^Signed in\./);
  const before = app.calls.length; const seen = {};
  for (const k of SCREENS) {
    await app.click(chip(app, k)); seen[k] = app.all('#v-hq .hq-badge').map((b) => b.textContent);
    assert.ok(app.all('#v-hq .hq-panel').every((p) => p.querySelector('.hq-badge')), k);
    assert.doesNotMatch(view(app).textContent, /\b(null|undefined|NaN)\b|\[object Object\]/, k);
  }
  assert.equal(app.calls.length, before, 'switching HQ screens makes no database call');
  for (const n of new Set(app.calls.map((c) => c.name))) assert.ok(['app_snapshot', 'app_messages', 'app_office', 'app_payments', 'app_needs_you'].includes(n), n);
  for (const k of ['overview', 'missions', 'agents', 'activity', 'finance', 'health']) assert.ok(seen[k].includes('LIVE'), k);
  assert.ok(seen.jarvis.includes('SIMULATED')); assert.ok(seen.org.every((b) => b === 'OWNER-DEFINED · NOT CONNECTED'));
  await app.click(chip(app, 'finance'));
  assert.match(view(app).textContent, /AI spend today\s*\$0\.42 of \$3\.30 daily cap/); assert.match(view(app).textContent, /Not connected — manual reconciliation required/);
  await app.click(chip(app, 'missions')); assert.match(view(app).textContent, /Live missions \(database\)[\s\S]*Cold email test[\s\S]*Map leads/);
  app.stop();
});

test('live mode: "Also send to the live mission engine" uses ONLY the existing app_send mission/new, after confirmation', async () => {
  const be = backend(); const app = await boot({ rpc: be }); await app.tab('hq');
  await planIt(app, OTTAWA);
  app.win.confirm = () => false; await app.click(app.button('#v-hq', 'Also send to the live mission engine'));
  assert.equal(app.callsTo('app_send').length, 0, 'declined confirm sends nothing');
  app.win.confirm = () => true; await app.click(app.button('#v-hq', 'Also send to the live mission engine'));
  const sends = app.callsTo('app_send'); assert.equal(sends.length, 1);
  assert.deepEqual(sends[0].args, { p_body: '', p_kind: 'mission', p_payload: { verb: 'new', objective: OTTAWA } });
  assert.match(view(app).textContent, /Objective sent to the live mission engine/);
  await app.click(app.button('#v-hq', 'Create mission (simulated)'));
  assert.equal(app.callsTo('app_send').length, 1, 'simulated mission actions never touch the database');
  app.stop();
});

test('live mode with an empty database still draws every HQ screen', async () => {
  const empty = { state: { mode: 'dry_run', last_heartbeat: new Date().toISOString() }, tasks: { todo: 0, doing: 0, blocked: 0, done_24h: 0 }, leads: { total: 0, due: 0 } };
  const app = await boot({ rpc: backend({ app_snapshot: empty, app_office: [], app_needs_you: [] }) }); await app.tab('hq');
  for (const k of SCREENS) { await app.click(chip(app, k)); assert.ok(app.all('#v-hq .hq-panel').length > 0, k); assert.doesNotMatch(view(app).textContent, /failed to render|\bnull\b|\bundefined\b|NaN/, k); }
  app.stop();
});
