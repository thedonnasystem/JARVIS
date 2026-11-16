import test from 'node:test';
import assert from 'node:assert/strict';
import { boot, backend, read, tick } from './lib/harness.mjs';

const DEMO_URL = 'https://fendezy-hq-app.onrender.com/?demo=1';
const SCREENS = ['overview', 'org', 'divisions', 'offices', 'jarvis', 'managers', 'agents', 'missions', 'activity', 'finance', 'health'];
const noRpc = () => { throw new Error('demo mode must not call the database'); };
async function demo(extra = {}) {
  const app = await boot({ rpc: noRpc, url: DEMO_URL + (extra.hash || ''), session: null });
  const errs = []; const orig = app.win.console.error; app.win.console.error = (...a) => { errs.push(a.join(' ')); orig.apply(app.win.console, a); };
  app.errs = errs; return app;
}
const chip = (app, k) => app.$('.hq-nav [data-screen="' + k + '"]');
const view = (app) => app.$('#v-hq');

test('demo mode: no login, no backend call at all, banner says SIMULATED, one HQ view, nav hidden', async () => {
  const app = await demo();
  assert.equal(app.$('#login').hidden, true); assert.equal(app.$('#app').hidden, false); assert.equal(app.$('#tabs').hidden, true);
  assert.equal(app.calls.length, 0, 'zero database calls');
  assert.match(app.text('#pill'), /DEMO: simulated data/);
  assert.match(view(app).querySelector('.hq-banner').textContent, /^SIMULATED DATA\./);
  assert.deepEqual(app.all('.view.on').map((v) => v.id), ['v-hq']);
  assert.equal(app.state.signedOut, false); assert.equal(app.win.__errors.length, 0);
  app.stop();
});

for (const k of SCREENS) {
  test(`demo screen "${k}" renders, every panel carries a SIMULATED badge, nothing claims LIVE`, async () => {
    const app = await demo();
    await app.click(chip(app, k));
    assert.ok(chip(app, k).classList.contains('on'));
    const panels = app.all('#v-hq .hq-panel');
    assert.ok(panels.length > 0, 'has panels');
    for (const p of panels) { const b = p.querySelector('.hq-badge'); assert.ok(b, 'panel without a badge: ' + p.textContent.slice(0, 40)); assert.equal(b.textContent, 'SIMULATED'); }
    assert.ok(![...app.all('#v-hq .hq-badge')].some((b) => /^LIVE$/.test(b.textContent)), 'demo can never show LIVE');
    assert.match(view(app).querySelector('.hq-banner').textContent, /SIMULATED/);
    assert.equal(app.calls.length, 0); assert.equal(app.errs.length, 0, app.errs.join('|'));
    app.stop();
  });
}

test('the data model has exactly eight divisions, valid references, one manager each, and no personal data', async () => {
  const app = await demo(); const D = app.win.HQ_DEMO;
  assert.equal(D.meta.synthetic, true); assert.equal(D.divisions.length, 8);
  const ids = new Set(D.divisions.map((x) => x.id)), mgrs = new Set(D.managers.map((m) => m.id)), teams = new Set(D.teams.map((t) => t.id)), agents = new Set(D.agents.map((a) => a.slug));
  for (const x of D.divisions) { assert.ok(mgrs.has(x.manager_id), x.id + ' manager'); x.team_ids.forEach((t) => assert.ok(teams.has(t), t)); x.mission_ids.forEach((m) => assert.ok(D.missions.some((q) => q.id === m))); }
  D.teams.forEach((t) => { assert.ok(ids.has(t.division_id)); t.agent_ids.forEach((a) => assert.ok(agents.has(a), a)); });
  D.missions.forEach((m) => assert.ok(ids.has(m.division_id)));
  const raw = read('webapp/hq/demo_data.js');
  assert.ok(!/[\w.+-]+@[\w-]+\.[a-z]{2,}/i.test(raw), 'no email addresses');
  assert.ok(!/\b\d{3}[-. ]\d{3}[-. ]\d{4}\b/.test(raw), 'no phone numbers');
  assert.ok(!/https?:\/\//.test(raw), 'no urls');
  app.stop();
});

test('chip navigation, back button and hash deep links', async () => {
  const app = await demo();
  await app.click(chip(app, 'divisions'));
  assert.equal(app.all('#v-hq .hq-grid .hq-div').length, 8);
  await app.click(app.all('#v-hq .hq-grid .hq-div')[0]);
  assert.match(view(app).textContent, /Donna Systems[\s\S]*Budget and money[\s\S]*KPIs[\s\S]*Teams[\s\S]*Risks/);
  assert.equal(app.win.location.hash, '#divisions/division/donna');
  await app.click(app.button('#v-hq', '‹ All divisions'));
  assert.equal(app.all('#v-hq .hq-grid .hq-div').length, 8);
  app.stop();
  const deep = await demo({ hash: '#missions/mission/ms-2' });
  assert.match(view(deep).textContent, /Onboard FF Marketing Client A[\s\S]*Gate:[\s\S]*Tasks/); deep.stop();
  const bad = await demo({ hash: '#nope/evil/1' });
  assert.match(view(bad).textContent, /Group status/, 'unknown hash falls back to the overview'); bad.stop();
});

test('org chart: Chairman > Jarvis > offices + 8 divisions > managers > teams; expand/collapse; open profile', async () => {
  const app = await demo(); await app.click(chip(app, 'org'));
  const nodes = () => app.all('#v-hq .org-node').map((g) => g.getAttribute('data-node'));
  assert.deepEqual(nodes().slice(0, 3), ['chair', 'jarvis', 'g:off']); assert.ok(nodes().includes('g:div'));
  assert.equal(nodes().filter((n) => n.startsWith('d:')).length, 8);
  assert.equal(nodes().filter((n) => n.startsWith('o:')).length, 11);
  assert.ok(!nodes().some((n) => n.startsWith('m:')), 'managers hidden until a division is expanded');
  await app.click(app.$('#v-hq [data-node="d:donna"]'));
  assert.ok(nodes().includes('m:m-donna')); assert.equal(app.$('#v-hq [data-node="d:donna"]').getAttribute('aria-expanded'), 'true');
  await app.click(app.$('#v-hq [data-node="m:m-donna"]'));
  assert.ok(nodes().includes('t:t-donna-build'));
  await app.click(app.button('#v-hq', 'Expand all'));
  assert.equal(nodes().filter((n) => n.startsWith('t:')).length, 10);
  assert.equal(nodes().filter((n) => n.startsWith('m:')).length, 8);
  await app.click(app.button('#v-hq', 'Collapse'));
  assert.equal(nodes().length, 4 + 11 + 8);
  await app.click(app.$('#v-hq [data-node="d:eng"]')); await app.click(app.$('#v-hq [data-open="d:eng"]'));
  assert.match(view(app).textContent, /Engineering & Platform[\s\S]*Budget and money/);
  assert.equal(app.errs.length, 0); app.stop();
});

test('missions: filter by status, read-only detail with tasks', async () => {
  const app = await demo(); await app.click(chip(app, 'missions'));
  assert.equal(app.all('#v-hq .hq-div').length, 5);
  await app.click(app.button('#v-hq', 'Blocked'));
  assert.equal(app.all('#v-hq .hq-div').length, 1); assert.match(view(app).textContent, /Client A/);
  await app.click(app.button('#v-hq', 'Done'));
  assert.equal(app.all('#v-hq .hq-div').length, 1); assert.match(view(app).textContent, /Province buyer research/);
  await app.click(app.button('#v-hq', 'All'));
  await app.click(app.all('#v-hq .hq-div')[0]);
  assert.match(view(app).textContent, /Tasks[\s\S]*1\. Inspect the PWA/); assert.match(view(app).textContent, /Demo: read-only/);
  app.stop();
});

test('activity and agents filters work', async () => {
  const app = await demo(); await app.click(chip(app, 'activity'));
  const total = app.all('#v-hq .hq-feed').length; assert.ok(total >= 8);
  await app.click(app.button('#v-hq', 'Audit')); assert.ok(app.all('#v-hq .hq-feed').length < total && app.all('#v-hq .hq-feed').length > 0);
  await app.click(chip(app, 'agents')); const all = app.all('#v-hq .hq-agent').length;
  await app.click(app.button('#v-hq', 'Paused')); assert.ok(app.all('#v-hq .hq-agent').length < all && app.all('#v-hq .hq-agent').length > 0);
  app.stop();
});

test('Jarvis control center is display only: states shown, owner-action labels, no control that changes anything', async () => {
  const app = await demo(); await app.click(chip(app, 'jarvis'));
  const t = view(app).textContent;
  assert.match(t, /Kill switch[\s\S]*OFF/); assert.equal(app.$('[data-kill]').getAttribute('data-kill'), 'off');
  assert.match(t, /DRY RUN/); assert.match(t, /Spend gateway[\s\S]*\$3\.30/); assert.match(t, /Pending approvals/);
  assert.ok((t.match(/Owner action in Telegram/g) || []).length >= 3);
  const labels = app.all('#v-hq .hq-body button').map((b) => b.textContent);
  assert.deepEqual(labels, [], 'no buttons in the body of the Jarvis screen in demo mode: ' + labels.join('|'));
  for (const k of ['finance', 'health']) { await app.click(chip(app, k)); assert.deepEqual(app.all('#v-hq .hq-body button').map((b) => b.textContent), [], k + ' has no action buttons'); }
  assert.match(view(app).textContent, /Consent gate[\s\S]*OFF/);
  app.stop();
});

test('finance shows the $3.30 cap, spend today and ledger summary', async () => {
  const app = await demo(); await app.click(chip(app, 'finance'));
  assert.match(view(app).textContent, /\$1\.88[\s\S]*\$3\.30 daily company cap[\s\S]*Last 7 days[\s\S]*Operating capital[\s\S]*Ledger summary[\s\S]*Received money only|Ledger counts received money only/);
  app.stop();
});

test('escaping: hostile text in the data is shown as text, never parsed as markup', async () => {
  const app = await demo(); const D = app.win.HQ_DEMO; const evil = '<img src=x onerror=window.__pwn=1><script>window.__pwn=2</script>';
  D.divisions[0].name = evil; D.managers[0].title = evil; D.missions[0].title = evil; D.feed[0].text = evil; D.agents[1].title = evil; D.jarvis.pending_approvals[0].title = evil;
  for (const k of SCREENS) { await app.click(chip(app, k)); assert.equal(app.all('#v-hq img').length, 0, k); assert.equal(app.all('#v-hq script').length, 0, k); }
  await app.click(chip(app, 'divisions')); assert.ok(view(app).textContent.includes(evil));
  assert.equal(app.win.__pwn, undefined); app.stop();
});

test('hq code: no innerHTML, no network, no eval, no storage, no external urls; CSP unchanged', () => {
  for (const f of ['webapp/hq/hq.js', 'webapp/hq/demo_data.js']) {
    const src = read(f);
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(src), f + ' html injection');
    assert.ok(!/\bfetch\s*\(|XMLHttpRequest|WebSocket|sendBeacon|eval\s*\(|new Function|importScripts|localStorage|sessionStorage|\.rpc\s*\(|rpc\(/.test(src), f + ' network/eval/storage');
    assert.ok(!/https?:\/\//.test(src.replace(/http:\/\/www\.w3\.org\/2000\/svg/, '')), f + ' external url');
  }
  const html = read('webapp/index.html');
  assert.match(html, /script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https:\/\/ihxzvpwbqydqtblvazbq\.supabase\.co wss:\/\/ihxzvpwbqydqtblvazbq\.supabase\.co/);
  assert.ok(!/<script[^>]*src="https?:/.test(html), 'no external script');
});

// ---------- signed-in (live) mode ----------
test('live mode: HQ tab overlays existing reads as LIVE, keeps the rest SIMULATED, and makes no new or mutating calls', async () => {
  const app = await boot({ rpc: backend() });
  await app.tab('hq');
  assert.match(view(app).querySelector('.hq-banner').textContent, /^MIXED DATA/);
  const before = app.calls.length;
  const seen = {};
  for (const k of SCREENS) {
    await app.click(chip(app, k));
    seen[k] = app.all('#v-hq .hq-badge').map((b) => b.textContent);
    assert.ok(app.all('#v-hq .hq-panel').every((p) => p.querySelector('.hq-badge')), k + ' badges');
    assert.equal(app.$('#banner').hidden, true, k + ': ' + app.text('#banner'));
  }
  assert.equal(app.calls.length, before, 'switching HQ screens makes no database call');
  const names = new Set(app.calls.map((c) => c.name));
  for (const n of names) assert.ok(['app_snapshot', 'app_messages', 'app_office', 'app_payments', 'app_needs_you'].includes(n), 'unexpected call ' + n);
  assert.ok(seen.jarvis.includes('LIVE')); assert.ok(seen.agents.includes('LIVE')); assert.ok(seen.missions.includes('LIVE')); assert.ok(seen.activity.includes('LIVE')); assert.ok(seen.finance.includes('LIVE'));
  assert.ok(seen.managers.every((b) => b === 'SIMULATED') && seen.org.every((b) => b === 'SIMULATED'), 'org structure is never presented as live');
  assert.ok(seen.health.includes('NOT CONNECTED'), 'deployments/backups/consent are not connected'); assert.ok(seen.finance.includes('INCOMPLETE'));
  app.stop();
});

test('live mode: real fixture values show up; pending approvals come from the inbox; hand-off buttons use the existing tabs', async () => {
  const app = await boot({ rpc: backend() }); await app.tab('hq');
  await app.click(chip(app, 'overview')); assert.match(view(app).textContent, /\$0\.42[\s\S]*of \$3\.30 cap[\s\S]*\$123\.45/);
  await app.click(chip(app, 'jarvis')); const t = view(app).textContent;
  assert.match(t, /Spend \$5 on ads[\s\S]*Which city first\?/); assert.match(t, /DRY RUN/); assert.match(t, /send_email/);
  await app.click(app.button('#v-hq', 'Decide in the Inbox tab'));
  assert.ok(app.$('#v-inbox').classList.contains('on'));
  await app.tab('hq'); await app.click(chip(app, 'missions')); assert.match(view(app).textContent, /Cold email test[\s\S]*Map leads/);
  await app.click(app.all('#v-hq .hq-div')[0]); assert.match(view(app).textContent, /Test cold email/);
  await app.click(app.button('#v-hq', 'Pause / resume / abandon on the Missions tab')); assert.ok(app.$('#v-missions').classList.contains('on'));
  assert.equal(app.callsTo('app_send').length, 0, 'HQ screens never send anything');
  await app.tab('hq'); await app.click(chip(app, 'agents')); assert.match(view(app).textContent, /Jarvis[\s\S]*ceo|Jarvis/);
  await app.click(chip(app, 'activity')); assert.match(view(app).textContent, /Planned the day/);
  await app.click(chip(app, 'offices')); assert.match(view(app).textContent, /Executive Office[\s\S]*Legal & Compliance/);
  app.stop();
});

test('live mode with an empty database still draws every HQ screen', async () => {
  const empty = { state: { mode: 'dry_run', last_heartbeat: new Date().toISOString() }, tasks: { todo: 0, doing: 0, blocked: 0, done_24h: 0 }, leads: { total: 0, due: 0 } };
  const app = await boot({ rpc: backend({ app_snapshot: empty, app_office: [], app_needs_you: [] }) }); await app.tab('hq');
  for (const k of SCREENS) { await app.click(chip(app, k)); assert.ok(app.all('#v-hq .hq-panel').length > 0, k); assert.doesNotMatch(view(app).textContent, /could not be drawn/, k); assert.equal(app.$('#banner').hidden, true, k + app.text('#banner')); }
  app.stop();
});

test('kill switch ON is shown as ON and raised as an alert in live mode', async () => {
  const snap = backend().constructor && null;
  const be = backend({ app_snapshot: (() => { const s = JSON.parse(JSON.stringify({ state: { kill_switch: true, mode: 'dry_run', last_heartbeat: new Date().toISOString(), cap_cents: 330 }, tasks: { todo: 0, doing: 0, blocked: 0, done_24h: 0 }, leads: { total: 0, due: 0 }, spend_today_cents: 300 })); return s; })() });
  const app = await boot({ rpc: be }); await app.tab('hq');
  await app.click(chip(app, 'overview')); assert.match(view(app).textContent, /KILL SWITCH ON[\s\S]*Kill switch is ON[\s\S]*is 91% of the \$3\.30 cap/);
  await app.click(chip(app, 'jarvis')); assert.equal(app.$('[data-kill]').getAttribute('data-kill'), 'on');
  void snap; app.stop();
});
