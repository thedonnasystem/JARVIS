import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { boot, backend, snapshot, read, tick, WEBAPP } from './lib/harness.mjs';

const TABS = ['chat', 'inbox', 'home', 'missions', 'agents', 'money', 'feed'];
const keepOpen = () => new Set([...read('migrations/20261112_lockdown_v1.sql').match(/proname\s+not\s+in\s*\(([^)]*)\)/i)[1].matchAll(/'([^']+)'/g)].map((m) => m[1]));
const PENDING = new Set(['app_needs_you']);   // deliberately closed until the owner signs off the lockdown allowlist patch (scripts/check_app_rpcs.py enforces the same list)

test('app boots: login hidden, app shown, one button per tab, status pill', async () => {
  const app = await boot({ rpc: backend() });
  assert.equal(app.$('#login').hidden, true);
  assert.equal(app.$('#app').hidden, false);
  assert.deepEqual(app.all('#tabs button').map((b) => b.id), TABS.map((k) => 't-' + k));
  assert.match(app.text('#pill'), /^Running/);
  assert.match(app.text('#stamp'), /^beat /);
  app.stop();
});

test('no session: the login form shows and nothing from the database is requested', async () => {
  const app = await boot({ rpc: backend(), session: null });
  assert.equal(app.$('#login').hidden, false);
  assert.equal(app.$('#app').hidden, true);
  assert.equal(app.calls.length, 0);
  app.stop();
});

test('a signed-in stranger is refused with a visible message and signed out', async () => {
  const app = await boot({ rpc: backend({ app_snapshot: () => { throw new Error('not authorized'); } }) });
  assert.equal(app.state.signedOut, true);
  assert.equal(app.$('#app').hidden, true);
  assert.equal(app.$('#login').hidden, false);
  assert.match(app.text('#login-msg'), /not authorized for HQ/);
  app.stop();
});

const EXPECT = {
  chat: /Tell Jarvis what to do/, inbox: /4 waiting on you/, home: /Operating fund[\s\S]*\$123\.45[\s\S]*Follow-ups due[\s\S]*Jane Doe[\s\S]*Donna HVAC[\s\S]*Systems[\s\S]*KILL SWITCH/,
  missions: /Open mission[\s\S]*Idea lab[\s\S]*Garage cleanouts[\s\S]*Cold email test/, agents: /Headquarters[\s\S]*Executive Office[\s\S]*All agents[\s\S]*Jarvis[\s\S]*Proposals and org changes[\s\S]*Hire a closer agent/,
  money: /Available[\s\S]*\$123\.45[\s\S]*Bank \(source of truth\)[\s\S]*AI spend, last 7 days[\s\S]*Permissions[\s\S]*send_email/, feed: /jarvis · task[\s\S]*Planned the day/,
};
for (const k of TABS) {
  test(`tab "${k}" renders from fixture data and is the only visible view`, async () => {
    const app = await boot({ rpc: backend() });
    await app.tab(k);
    const view = app.$('#v-' + k);
    assert.ok(view.classList.contains('on'), 'view is shown');
    assert.deepEqual(app.all('.view.on').map((v) => v.id), ['v-' + k]);
    assert.ok(view.children.length > 0, 'view is not blank');
    assert.match(view.textContent, EXPECT[k]);
    assert.ok(app.$('#t-' + k).classList.contains('on'));
    assert.equal(app.$('#banner').hidden, true, 'no error banner on a healthy render');
    app.stop();
  });
}

test('every tab still draws with an empty database (new install)', async () => {
  const empty = { state: { mode: 'dry_run', last_heartbeat: new Date().toISOString() }, tasks: { todo: 0, doing: 0, blocked: 0, done_24h: 0 }, leads: { total: 0, due: 0 } };
  const app = await boot({ rpc: backend({ app_snapshot: empty, app_office: [], app_needs_you: [] }) });
  for (const k of TABS) { await app.tab(k); assert.equal(app.$('#banner').hidden, true, `${k}: ${app.text('#banner')}`); }
  await app.tab('inbox');
  assert.match(app.text('#v-inbox'), /Nothing waiting on you/);
  app.stop();
});

// ---------- approvals call the right RPC with the right args ----------
test('inbox Approve / Reject use app_send kind "decision" with {msg_id, approved}', async () => {
  const be = backend(); const app = await boot({ rpc: be });
  await app.tab('inbox');
  await app.click(app.button('#v-inbox', 'Approve'));
  await app.click(app.button('#v-inbox', 'Reject'));
  const sends = app.callsTo('app_send');
  assert.deepEqual(sends.map((c) => c.args), [
    { p_body: '', p_kind: 'decision', p_payload: { msg_id: 'm-appr', approved: true } },
    { p_body: '', p_kind: 'decision', p_payload: { msg_id: 'm-appr', approved: false } },
  ]);
  assert.ok(app.callsTo('app_messages').length >= 2, 'the app polls for Jarvis\'s one-line answer after sending');
  app.stop();
});

test('inbox answer options use kind "answer" with {msg_id, idx}', async () => {
  const app = await boot({ rpc: backend() });
  await app.tab('inbox');
  await app.click(app.button('#v-inbox', 'Toronto'));
  assert.deepEqual(app.callsTo('app_send').map((c) => c.args), [{ p_body: '', p_kind: 'answer', p_payload: { msg_id: 'm-q', idx: 1 } }]);
  app.stop();
});

test('inbox mission Resume uses kind "mission"; Abandon asks first and sends nothing when declined', async () => {
  const opts = { rpc: backend(), confirmAnswer: false }; const app = await boot(opts);
  await app.tab('inbox');
  await app.click(app.button('#v-inbox', 'Abandon'));
  assert.equal(app.callsTo('app_send').length, 0, 'declined confirm must not send');
  assert.equal(opts.confirms.length, 1);
  await app.click(app.button('#v-inbox', 'Resume'));
  assert.deepEqual(app.callsTo('app_send').map((c) => c.args), [{ p_body: '', p_kind: 'mission', p_payload: { verb: 'resume', id: 'mis-blocked' } }]);
  opts.confirmAnswer = true;
  await app.click(app.button('#v-inbox', 'Abandon'));
  assert.deepEqual(app.callsTo('app_send').at(-1).args, { p_body: '', p_kind: 'mission', p_payload: { verb: 'abandon', id: 'mis-blocked' } });
  app.stop();
});

test('home "Needs you" Approve / Reject (existing path) still sends the same decision rows', async () => {
  const app = await boot({ rpc: backend() });
  await app.tab('home');
  const card = app.all('#v-home .card').find((c) => c.textContent.includes('Spend $5 on ads'));   // not the outreach draft's own Approve button
  const btn = (l) => [...card.querySelectorAll('button')].find((b) => b.textContent === l);
  await app.click(btn('Approve'));
  await app.click(btn('Reject'));
  assert.deepEqual(app.callsTo('app_send').map((c) => c.args), [
    { p_body: '', p_kind: 'decision', p_payload: { msg_id: 'm-appr', approved: true } },
    { p_body: '', p_kind: 'decision', p_payload: { msg_id: 'm-appr', approved: false } }]);
  app.stop();
});

test('inbox can only trigger decision / answer / mission: any other action kind from the server renders no button', async () => {
  const evil = [{ rank: 1, kind: 'approval', title: 'Sneaky', created_at: new Date().toISOString(), why: 'x', action: 'x',
    actions: [{ verb: 'kill', label: 'Do harm', kind: 'kill', payload: { on: true } }, { verb: 'spend', label: 'Spend', kind: 'payment', payload: { verb: 'done' } },
              { verb: 'approve', label: 'Fine', kind: 'decision', payload: { msg_id: 'ok', approved: true } }, { verb: 'nopayload', label: 'No payload', kind: 'decision' }] }];
  const app = await boot({ rpc: backend({ app_needs_you: evil }) });
  await app.tab('inbox');
  assert.deepEqual(app.all('#v-inbox button').map((b) => b.textContent), ['Fine']);
  app.stop();
});

test('items with no tap action show the Telegram command instead', async () => {
  const app = await boot({ rpc: backend() });
  await app.tab('inbox');
  assert.match(app.text('#v-inbox'), /\$15\.00 to Twilio[\s\S]*In Telegram: \/pay done p1/);
  app.stop();
});

test('tab label carries the inbox count', async () => {
  const app = await boot({ rpc: backend() });
  assert.equal(app.text('#t-inbox'), 'Inbox (4)');
  app.stop();
});

test('fallback: while app_needs_you is closed to the owner, the inbox still shows approvals, questions and blocked missions from app_snapshot', async () => {
  const app = await boot({ rpc: backend({ app_needs_you: () => { throw new Error('permission denied for function app_needs_you'); } }) });
  assert.equal(app.$('#banner').hidden, true, 'a closed optional RPC is not an error');
  await app.tab('inbox');
  const t = app.text('#v-inbox');
  assert.match(t, /3 waiting on you/);
  assert.match(t, /Spend \$5 on ads/); assert.match(t, /Which city first\?/); assert.match(t, /Cold email test/);
  assert.match(t, /Showing approvals, questions and blocked missions/);
  await app.click(app.button('#v-inbox', 'Approve'));
  assert.deepEqual(app.callsTo('app_send').at(-1).args, { p_body: '', p_kind: 'decision', p_payload: { msg_id: 'm-appr', approved: true } });
  app.stop();
});

// ---------- errors are visible, never a blank page ----------
test('a failed refresh shows a banner and keeps the last screen', async () => {
  let down = false; const be = backend();
  const app = await boot({ rpc: (n, a) => { if (down) throw new Error('network down'); return be(n, a); } });
  await app.tab('home');
  const before = app.text('#v-home');
  assert.ok(before.length > 50);
  down = true; await app.refresh();
  assert.equal(app.$('#banner').hidden, false);
  assert.match(app.text('#banner'), /Offline or signed out/);
  assert.equal(app.text('#v-home'), before, 'the previous screen is kept, not blanked');
  down = false; await app.refresh();
  assert.equal(app.$('#banner').hidden, true, 'banner clears when the connection returns');
  app.stop();
});

test('a malformed snapshot shows an error on the page and in the banner instead of a blank tab', async () => {
  const bad = snapshot(); delete bad.tasks;   // rHome reads s.tasks.todo
  const app = await boot({ rpc: backend({ app_snapshot: bad }) });
  await app.tab('home');
  assert.equal(app.$('#banner').hidden, false);
  assert.match(app.text('#banner'), /Could not draw this page/);
  assert.match(app.text('#v-home'), /could not be drawn/);
  await app.tab('feed');   // other tabs keep working
  assert.match(app.text('#v-feed'), /Planned the day/);
  app.stop();
});

test('a failed send shows the reason in the banner', async () => {
  const app = await boot({ rpc: backend({ app_send: () => { throw new Error('not authorized'); } }) });
  await app.tab('inbox');
  await app.click(app.button('#v-inbox', 'Approve'));
  assert.equal(app.$('#banner').hidden, false);
  assert.match(app.text('#banner'), /not authorized/);
  app.stop();
});

// ---------- function names ----------
test('every database function the running app calls is open to the owner (lockdown list) or knowingly pending sign-off', async () => {
  const app = await boot({ rpc: backend() });
  for (const k of TABS) await app.tab(k);
  await app.tab('home'); await app.click(app.button('#v-home', 'Details')); await app.click(app.$('#v-home .btns button.bad'));
  const names = new Set(app.calls.map((c) => c.name));
  assert.ok(names.size >= 6, [...names].join());
  const open = keepOpen();
  for (const n of names) assert.ok(open.has(n) || PENDING.has(n), `${n} is called by the app but the lockdown would revoke it`);
  // and the static scan agrees with what actually ran
  const src = read('webapp/app.js'); const scanned = new Set([...src.matchAll(/\brpc\(\s*'([a-z_]+)'/g)].map((m) => m[1]));
  for (const n of names) assert.ok(scanned.has(n), `${n} was called at runtime but not found by the source scan`);
  app.stop();
});

test('the app never uses innerHTML and its CSP allows exactly its own Supabase project', () => {
  const src = read('webapp/app.js'); const html = read('webapp/index.html');
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(src), 'all text must be set as text');
  const url = src.match(/const SB_URL = '([^']+)'/)[1]; const host = new URL(url).host;
  assert.ok(html.includes(`connect-src 'self' https://${host} wss://${host}`), 'CSP connect-src must match SB_URL');
  assert.match(html, /script-src 'self'/); assert.ok(!/script-src[^;]*unsafe-inline/.test(html));
});

// ---------- offline: the service worker ----------
function loadSw() {
  const listeners = {}; const store = { caches: new Map(), added: null };
  const cache = (name) => { if (!store.caches.has(name)) store.caches.set(name, new Map()); const m = store.caches.get(name);
    return { addAll: async (l) => { store.added = l; l.forEach((u) => m.set(u, 'cached:' + u)); }, put: async (req, res) => { m.set(req.url, res); } }; };
  const self = { addEventListener: (t, f) => { listeners[t] = f; }, skipWaiting: () => {}, clients: { claim: async () => {}, matchAll: async () => [] }, registration: { showNotification: async () => {} } };
  const ctx = { self, location: new URL('https://fendezy-hq-app.onrender.com/sw.js'), URL,
    caches: { open: async (n) => cache(n), keys: async () => [...store.caches.keys()], delete: async (k) => store.caches.delete(k),
      match: async (req) => { for (const m of store.caches.values()) if (m.has(req.url)) return m.get(req.url); return undefined; } },
    fetch: async () => { throw new Error('offline'); }, console };
  vm.createContext(ctx); vm.runInContext(read('webapp/sw.js'), ctx);
  return { listeners, store, ctx };
}
test('service worker install caches every shipped asset and every asset exists', async () => {
  const { listeners, store } = loadSw(); let p; listeners.install({ waitUntil: (x) => { p = x; } }); await p;
  const html = read('webapp/index.html');
  const refs = [...html.matchAll(/(?:href|src)="([^"#]+)"/g)].map((m) => m[1]).filter((r) => !/^(https?:|\/|data:)/.test(r));
  const manifest = JSON.parse(read('webapp/manifest.webmanifest')); manifest.icons.forEach((i) => refs.push(i.src));
  const added = new Set(store.added.map((u) => (u === './' ? 'index.html' : u)));
  for (const r of ['index.html', ...refs]) assert.ok(added.has(r), `${r} is not in the offline cache list`);
  for (const a of added) assert.ok(existsSync(path.join(WEBAPP, a)), `${a} is cached but missing from webapp/ (cache.addAll would reject)`);
});
test('service worker serves from cache when offline, ignores writes and other origins, drops old caches', async () => {
  const { listeners, store } = loadSw(); let p;
  listeners.install({ waitUntil: (x) => { p = x; } }); await p;
  const respond = async (req) => { let r; listeners.fetch({ request: req, respondWith: (x) => { r = x; } }); return r === undefined ? undefined : await r; };
  // online path is not exercised here; offline (fetch rejects) must fall back to the cache:
  store.caches.get('hq-v4').set('https://fendezy-hq-app.onrender.com/app.js', 'APPJS');
  assert.equal(await respond({ method: 'GET', url: 'https://fendezy-hq-app.onrender.com/app.js' }), 'APPJS');
  assert.equal(await respond({ method: 'POST', url: 'https://fendezy-hq-app.onrender.com/app.js' }), undefined);
  assert.equal(await respond({ method: 'GET', url: 'https://ihxzvpwbqydqtblvazbq.supabase.co/rest/v1/rpc/app_snapshot' }), undefined);
  store.caches.set('hq-v1-old', new Map()); let a; listeners.activate({ waitUntil: (x) => { a = x; } }); await a;
  assert.deepEqual([...store.caches.keys()], ['hq-v4']);
});
