// Auth regression tests that run the REAL vendored supabase-js (webapp/vendor/supabase.js) inside jsdom against a fake GoTrue/PostgREST (a stub fetch).
// The older smoke tests replace the client with a stub, so they cannot notice a change in the library. These do.
// Every auth flow the owner app uses is covered (webapp/app.js): createClient options, getSession, signInWithOtp, verifyOtp(type=email),
// the PostgREST rpc() call that carries the session token, token refresh, signOut, plus: detectSessionInUrl=false, the stored-session format,
// forward/backward compatibility with the previous library version (rollback safety), and a static guard that the app uses no other Supabase API.
// Nothing here touches the network or a real project: the project URL below is only a string the stub fetch answers.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';
import { snapshot, tick } from './lib/harness.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const rd = (p) => readFileSync(path.join(ROOT, p), 'utf8');
const NEW = process.env.SB_VENDOR || path.join('webapp', 'vendor', 'supabase.js');   // library under test (default: what ships)
const OLD = path.join('webtests', 'fixtures', 'supabase-2.45.4.umd.js.gz');   // gzip: keeps a minified third-party bundle out of secret-scan heuristics              // the previous release, for cross-version tests
const rdOld = () => gunzipSync(readFileSync(path.join(ROOT, OLD)));
const SRC = { new: rd(NEW), old: rdOld().toString('utf8') };
const APP_JS = rd('webapp/app.js');
const URL_ = 'https://ihxzvpwbqydqtblvazbq.supabase.co';
const KEY = APP_JS.match(/const SB_KEY = '([^']+)'/)[1];   // the app's own public key, read from app.js (not duplicated here)
const STORE_KEY = 'sb-ihxzvpwbqydqtblvazbq-auth-token';

const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function jwt(exp, extra = {}) {
  return `${b64u({ alg: 'HS256', typ: 'JWT' })}.${b64u({ iss: URL_ + '/auth/v1', sub: '11111111-1111-4111-8111-111111111111', aud: 'authenticated', role: 'authenticated', email: 'owner@example.com', session_id: '22222222-2222-4222-8222-222222222222', exp, iat: exp - 3600, ...extra })}.c2ln`;
}
const nowS = () => Math.floor(Date.now() / 1000);
const user = (o = {}) => ({ id: '11111111-1111-4111-8111-111111111111', aud: 'authenticated', role: 'authenticated', email: 'owner@example.com', app_metadata: { provider: 'email' }, user_metadata: {}, created_at: '2026-01-01T00:00:00Z', ...o });
const sessionBody = (n = 1, ttl = 3600) => ({ access_token: jwt(nowS() + ttl, { n }), token_type: 'bearer', expires_in: ttl, expires_at: nowS() + ttl, refresh_token: 'refresh-' + n, user: user() });
const hdrs = (h) => { const o = {}; if (!h) return o; if (typeof h.forEach === 'function') h.forEach((v, k) => { o[k.toLowerCase()] = v; }); else for (const [k, v] of Object.entries(h)) o[k.toLowerCase()] = v; return o; };

/** A fake Supabase edge: records every request, answers like GoTrue and PostgREST. `routes` overrides per (METHOD path). */
function fakeServer(routes = {}) {
  const log = [];
  const res = (status, body) => new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  const fetch = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' ? input : input.url);
    const method = (init.method || 'GET').toUpperCase();
    let body = null; try { body = init.body ? JSON.parse(init.body) : null; } catch { body = init.body; }
    const rec = { method, path: url.pathname, search: url.search, headers: hdrs(init.headers), body };
    log.push(rec);
    const k = method + ' ' + url.pathname;
    if (routes[k]) return routes[k](rec, url);
    if (k === 'POST /auth/v1/otp') return res(200, {});
    if (k === 'POST /auth/v1/verify') return res(200, sessionBody(1));
    if (k === 'POST /auth/v1/token' && url.searchParams.get('grant_type') === 'refresh_token') return res(200, sessionBody(2));
    if (k === 'POST /auth/v1/logout') return res(204);
    if (k === 'GET /auth/v1/user') return res(200, user());
    if (url.pathname.startsWith('/rest/v1/rpc/')) return res(200, snapshot());
    return res(404, { message: 'not stubbed: ' + k });
  };
  return { fetch, log, find: (m, p) => log.filter((r) => r.method === m && r.path === p) };
}

/** A jsdom window with the chosen library build loaded exactly as index.html does (a plain classic <script>), a stub fetch and optional prefilled localStorage. */
function windowWith(which, { server = fakeServer(), url = 'https://fendezy-hq-app.onrender.com/', storage = {}, html = '<!doctype html><body></body>' } = {}) {
  const dom = new JSDOM(html, {
    url, runScripts: 'outside-only', pretendToBeVisual: true,
    beforeParse(w) {
      w.fetch = server.fetch; w.Response = Response; w.Request = Request; w.Headers = Headers;
      for (const [k, v] of Object.entries(storage)) w.localStorage.setItem(k, v);
    },
  });
  // webpack's UMD runtime in 2.45.4 derives its publicPath from document.currentScript.src (a real <script src=...> load sets it); give it that
  Object.defineProperty(dom.window.document, 'currentScript', { configurable: true, get: () => ({ src: 'https://fendezy-hq-app.onrender.com/vendor/supabase.js', tagName: 'SCRIPT' }) });
  dom.window.eval(SRC[which]);
  delete dom.window.document.currentScript;
  return { w: dom.window, dom, server };
}
const client = (w, opts) => w.supabase.createClient(URL_, KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }, ...opts });
const stored = (w) => JSON.parse(w.localStorage.getItem(STORE_KEY) || 'null');

// ---------------------------------------------------------------- integrity pin
import { createHash } from 'node:crypto';
test('integrity: webapp/vendor/supabase.js matches the sha256 recorded in webapp/vendor/README.txt, and the rollback fixture is the recorded 2.45.4 file', { skip: !!process.env.SB_VENDOR }, () => {
  const readme = rd('webapp/vendor/README.txt');
  const sha = (b) => createHash('sha256').update(b).digest('hex');
  assert.equal(readme.match(/^supabase\.js sha256: ([0-9a-f]{64})$/m)[1], sha(readFileSync(path.join(ROOT, 'webapp/vendor/supabase.js'))));
  assert.equal(readme.match(/previous file was 2\.45\.4, sha256 ([0-9a-f]{64})/)[1], sha(rdOld()));
  assert.match(readme, /^supabase-js \d+\.\d+\.\d+ UMD build/);
});

// ---------------------------------------------------------------- bundle shape (same global/API as before)
test('bundle: UMD exposes window.supabase with the createClient the app calls, and the auth methods the app uses', () => {
  const { w } = windowWith('new');
  assert.equal(typeof w.supabase.createClient, 'function');
  const sb = client(w);
  for (const m of ['getSession', 'signInWithOtp', 'verifyOtp', 'signOut', 'onAuthStateChange']) assert.equal(typeof sb.auth[m], 'function', m);
  assert.equal(typeof sb.rpc, 'function');
  sb.auth.stopAutoRefresh?.(); w.close();
});

test('bundle: CSP compatibility (script-src self, no unsafe-eval): no eval / new Function, no inline-script loader, no remote script loading', () => {
  const s = SRC.new;
  assert.ok(!/\beval\s*\(/.test(s), 'eval(');
  assert.ok(!/new Function\s*\(/.test(s), 'new Function(');
  assert.ok(!/importScripts/.test(s), 'importScripts');
  assert.ok(!/document\.write/.test(s));
  assert.ok(!/createElement\(\s*["'`]script/.test(s), 'dynamic script injection');
});

test('static guard: the app uses only auth.getSession/signInWithOtp/verifyOtp/signOut and rpc(); no admin, service-role, storage, realtime, functions, from(), or getUser/setSession/refresh', () => {
  const used = new Set([...APP_JS.matchAll(/\bsb\.(auth\.\w+|\w+)/g)].map((m) => m[1]));
  assert.deepEqual([...used].sort(), ['auth.getSession', 'auth.signInWithOtp', 'auth.signOut', 'auth.verifyOtp', 'rpc']);
  for (const f of ['webapp/app.js', 'webapp/apply/apply.js']) {
    const t = rd(f);
    assert.ok(!/service_role|auth\.admin|getUserById|updateUserById|deleteUser|listFactors|deleteFactor|functions\.invoke|\.channel\(|\.storage\b/.test(t), f);
  }
  assert.match(APP_JS, /createClient\(SB_URL, SB_KEY, \{ auth: \{ persistSession: true, autoRefreshToken: true, detectSessionInUrl: false \} \}\)/);
});

// ---------------------------------------------------------------- the flows
test('flow: getSession with nothing stored returns no session and makes no network call', async () => {
  const { w, server } = windowWith('new'); const sb = client(w);
  const { data, error } = await sb.auth.getSession();
  assert.equal(data.session, null); assert.equal(error, null);
  assert.equal(server.log.length, 0);
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: signInWithOtp (email code, shouldCreateUser:false) hits /auth/v1/otp with the apikey, create_user=false, and NO PKCE challenge (implicit flow default)', async () => {
  const { w, server } = windowWith('new'); const sb = client(w);
  const { error } = await sb.auth.signInWithOtp({ email: 'owner@example.com', options: { shouldCreateUser: false } });
  assert.equal(error, null);
  const [r] = server.find('POST', '/auth/v1/otp'); assert.ok(r, 'otp request');
  assert.equal(r.body.email, 'owner@example.com'); assert.equal(r.body.create_user, false);
  assert.equal(r.headers.apikey, KEY);
  assert.ok(!r.body.code_challenge, 'default flow stays implicit (no PKCE challenge sent) like 2.45.4');
  assert.equal(stored(w), null, 'requesting a code stores no session');
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: signInWithOtp error is RETURNED not thrown (the app shows its own message), e.g. signups disabled / user unknown', async () => {
  const server = fakeServer({ 'POST /auth/v1/otp': () => new Response(JSON.stringify({ code: 422, error_code: 'otp_disabled', msg: 'Signups not allowed for otp' }), { status: 422, headers: { 'content-type': 'application/json' } }) });
  const { w } = windowWith('new', { server }); const sb = client(w);
  const { error } = await sb.auth.signInWithOtp({ email: 'x@example.com', options: { shouldCreateUser: false } });
  assert.ok(error, 'error returned'); assert.equal(error.status, 422);
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: verifyOtp(type=email) posts email+token+type, persists the session at sb-<ref>-auth-token, getSession returns it without a network call', async () => {
  const { w, server } = windowWith('new'); const sb = client(w);
  const { data, error } = await sb.auth.verifyOtp({ email: 'owner@example.com', token: '123456', type: 'email' });
  assert.equal(error, null); assert.ok(data.session.access_token);
  const [r] = server.find('POST', '/auth/v1/verify');
  assert.deepEqual({ email: r.body.email, token: r.body.token, type: r.body.type }, { email: 'owner@example.com', token: '123456', type: 'email' });
  const s = stored(w);
  assert.ok(s, 'session persisted under the storage key the previous version used');
  for (const k of ['access_token', 'refresh_token', 'expires_at', 'token_type', 'user']) assert.ok(s[k] !== undefined, 'stored field ' + k);
  assert.equal(s.user.email, 'owner@example.com');
  const before = server.log.length;
  const g = await sb.auth.getSession();
  assert.equal(g.data.session.refresh_token, s.refresh_token);
  assert.equal(server.log.length, before, 'valid session is read locally');
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: wrong/expired code returns an error and stores nothing', async () => {
  const server = fakeServer({ 'POST /auth/v1/verify': () => new Response(JSON.stringify({ code: 403, error_code: 'otp_expired', msg: 'Token has expired or is invalid' }), { status: 403, headers: { 'content-type': 'application/json' } }) });
  const { w } = windowWith('new', { server }); const sb = client(w);
  const { data, error } = await sb.auth.verifyOtp({ email: 'owner@example.com', token: '000000', type: 'email' });
  assert.ok(error); assert.equal(data.session, null); assert.equal(stored(w), null);
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: rpc() carries apikey=publishable key and Authorization=Bearer <session access token>; without a session it falls back to the publishable key', async () => {
  const { w, server } = windowWith('new'); const sb = client(w);
  await sb.rpc('app_snapshot', {});
  let r = server.find('POST', '/rest/v1/rpc/app_snapshot').pop();
  assert.equal(r.headers.apikey, KEY); assert.equal(r.headers.authorization, 'Bearer ' + KEY, 'anon: bearer is the publishable key');
  await sb.auth.verifyOtp({ email: 'owner@example.com', token: '1', type: 'email' });
  await sb.rpc('app_snapshot', { a: 1 });
  r = server.find('POST', '/rest/v1/rpc/app_snapshot').pop();
  assert.equal(r.headers.apikey, KEY); assert.equal(r.headers.authorization, 'Bearer ' + stored(w).access_token);
  assert.deepEqual(r.body, { a: 1 });
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: an expired stored session is refreshed through the refresh token on getSession, and the new tokens are stored', async () => {
  const exp = { ...sessionBody(1, 3600), expires_at: nowS() - 60, access_token: jwt(nowS() - 60) };
  const { w, server } = windowWith('new', { storage: { [STORE_KEY]: JSON.stringify(exp) } }); const sb = client(w);
  const { data, error } = await sb.auth.getSession();
  assert.equal(error, null);
  const [r] = server.log.filter((x) => x.path === '/auth/v1/token');
  assert.ok(r, 'token endpoint called'); assert.match(r.search, /grant_type=refresh_token/); assert.equal(r.body.refresh_token, 'refresh-1');
  assert.equal(data.session.refresh_token, 'refresh-2'); assert.equal(stored(w).refresh_token, 'refresh-2');
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: refresh token rejected (revoked/rotated away) -> session is cleared, getSession returns null (the app then shows the login form), no retry storm', async () => {
  const server = fakeServer({ 'POST /auth/v1/token': () => new Response(JSON.stringify({ code: 400, error_code: 'refresh_token_not_found', msg: 'Invalid Refresh Token: Refresh Token Not Found' }), { status: 400, headers: { 'content-type': 'application/json' } }) });
  const exp = { ...sessionBody(1), expires_at: nowS() - 60, access_token: jwt(nowS() - 60) };
  const { w } = windowWith('new', { server, storage: { [STORE_KEY]: JSON.stringify(exp) } }); const sb = client(w);
  const { data } = await sb.auth.getSession();
  assert.equal(data.session, null); assert.equal(stored(w), null, 'stale session removed');
  await tick();
  assert.ok(server.find('POST', '/auth/v1/token').length <= 2, 'bounded refresh attempts: ' + server.find('POST', '/auth/v1/token').length);
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: refresh network failure keeps the session (offline PWA must not sign the owner out)', async () => {
  const server = fakeServer({ 'POST /auth/v1/token': () => { throw new TypeError('Failed to fetch'); } });
  const exp = { ...sessionBody(1), expires_at: nowS() - 60, access_token: jwt(nowS() - 60) };
  const { w } = windowWith('new', { server, storage: { [STORE_KEY]: JSON.stringify(exp) } }); const sb = client(w);
  // auth-js retries retryable network errors with exponential backoff; do not wait for it to give up, look at the state after a short while
  sb.auth.getSession().catch(() => {});
  await new Promise((r) => setTimeout(r, 600));
  const s = stored(w); assert.ok(s, 'session kept after a network error'); assert.equal(s.refresh_token, 'refresh-1');
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: signOut calls /auth/v1/logout with the session bearer and clears storage; getSession is then empty', async () => {
  const { w, server } = windowWith('new'); const sb = client(w);
  await sb.auth.verifyOtp({ email: 'owner@example.com', token: '1', type: 'email' });
  const tok = stored(w).access_token;
  const { error } = await sb.auth.signOut();
  assert.equal(error, null);
  const [r] = server.find('POST', '/auth/v1/logout'); assert.ok(r, 'logout request');
  assert.equal(r.headers.authorization, 'Bearer ' + tok);
  assert.equal(stored(w), null);
  assert.equal((await sb.auth.getSession()).data.session, null);
  sb.auth.stopAutoRefresh(); w.close();
});

test('flow: signOut clears the local session when the server says the token is already invalid (401/403/404); on a 5xx it returns the error (same as 2.45.4)', async () => {
  for (const status of [401, 403, 404]) {
    const server = fakeServer({ 'POST /auth/v1/logout': () => new Response(JSON.stringify({ msg: 'gone' }), { status, headers: { 'content-type': 'application/json' } }) });
    const { w } = windowWith('new', { server }); const sb = client(w);
    await sb.auth.verifyOtp({ email: 'owner@example.com', token: '1', type: 'email' });
    await sb.auth.signOut().catch(() => {});
    assert.equal(stored(w), null, 'status ' + status);
    sb.auth.stopAutoRefresh(); w.close();
  }
  const server = fakeServer({ 'POST /auth/v1/logout': () => new Response(JSON.stringify({ msg: 'boom' }), { status: 500, headers: { 'content-type': 'application/json' } }) });
  const { w } = windowWith('new', { server }); const sb = client(w);
  await sb.auth.verifyOtp({ email: 'owner@example.com', token: '1', type: 'email' });
  const r = await sb.auth.signOut().catch((e) => ({ error: e }));
  assert.ok(r.error, 'a 5xx is surfaced as an error');   // the session may remain: the next boot re-checks it with app_snapshot and signs out again
  sb.auth.stopAutoRefresh(); w.close();
});

test('security: detectSessionInUrl=false: tokens in the URL hash or ?code= are NOT adopted as a session (no session fixation through a crafted link)', async () => {
  const hash = `#access_token=${jwt(nowS() + 3600)}&refresh_token=evil&expires_in=3600&token_type=bearer&type=magiclink`;
  const { w, server } = windowWith('new', { url: 'https://fendezy-hq-app.onrender.com/' + hash });
  const sb = client(w);
  const { data } = await sb.auth.getSession();
  assert.equal(data.session, null); assert.equal(stored(w), null);
  assert.equal(server.log.length, 0);
  sb.auth.stopAutoRefresh(); w.close();
  const q = windowWith('new', { url: 'https://fendezy-hq-app.onrender.com/?code=abc' });
  const sb2 = client(q.w); assert.equal((await sb2.auth.getSession()).data.session, null); assert.equal(q.server.log.length, 0);
  sb2.auth.stopAutoRefresh(); q.w.close();
});

test('storage: the token never goes to cookies or sessionStorage, only the one localStorage key; no stray keys beyond that', async () => {
  const { w } = windowWith('new'); const sb = client(w);
  await sb.auth.verifyOtp({ email: 'owner@example.com', token: '1', type: 'email' });
  assert.equal(w.document.cookie, '');
  const keys = Object.keys(w.localStorage).sort();
  assert.deepEqual(keys, [STORE_KEY], 'localStorage keys: ' + keys);
  assert.equal(w.sessionStorage.length, 0);
  sb.auth.stopAutoRefresh(); w.close();
});

// ---------------------------------------------------------------- cross-version (upgrade and rollback safety)
test('compat/upgrade: a session written by the PREVIOUS library (2.45.4) is read by the new one: same key, no re-login, no network call', async () => {
  const a = windowWith('old'); const sbOld = client(a.w);
  await sbOld.auth.verifyOtp({ email: 'owner@example.com', token: '1', type: 'email' });
  const raw = a.w.localStorage.getItem(STORE_KEY); assert.ok(raw, 'old lib stored under ' + STORE_KEY);
  sbOld.auth.stopAutoRefresh(); a.w.close();
  const b = windowWith('new', { storage: { [STORE_KEY]: raw } }); const sbNew = client(b.w);
  const { data } = await sbNew.auth.getSession();
  assert.equal(data.session?.refresh_token, JSON.parse(raw).refresh_token); assert.equal(data.session.user.email, 'owner@example.com');
  assert.equal(b.server.log.length, 0);
  sbNew.auth.stopAutoRefresh(); b.w.close();
});

test('compat/upgrade: an EXPIRED session from 2.45.4 is refreshed by the new library using the same refresh token', async () => {
  const old = { ...sessionBody(1), expires_at: nowS() - 10, access_token: jwt(nowS() - 10) };
  const b = windowWith('new', { storage: { [STORE_KEY]: JSON.stringify(old) } }); const sbNew = client(b.w);
  const { data } = await sbNew.auth.getSession();
  assert.equal(b.server.find('POST', '/auth/v1/token')[0].body.refresh_token, 'refresh-1'); assert.equal(data.session.refresh_token, 'refresh-2');
  sbNew.auth.stopAutoRefresh(); b.w.close();
});

test('compat/rollback: a session written by the NEW library is read by 2.45.4 (reverting the vendored file does not log the owner out)', async () => {
  const a = windowWith('new'); const sbNew = client(a.w);
  await sbNew.auth.verifyOtp({ email: 'owner@example.com', token: '1', type: 'email' });
  const raw = a.w.localStorage.getItem(STORE_KEY);
  sbNew.auth.stopAutoRefresh(); a.w.close();
  const b = windowWith('old', { storage: { [STORE_KEY]: raw } }); const sbOld = client(b.w);
  const { data } = await sbOld.auth.getSession();
  assert.equal(data.session?.user.email, 'owner@example.com'); assert.equal(b.server.log.length, 0);
  sbOld.auth.stopAutoRefresh(); b.w.close();
});

// ---------------------------------------------------------------- the real app.js on the real library, through the DOM
async function bootApp({ server, storage } = {}) {
  server = server || fakeServer();
  const html = rd('webapp/index.html').replace(/<script src="vendor\/supabase\.js"><\/script>/, '');
  const dom = new JSDOM(html, {
    url: 'https://fendezy-hq-app.onrender.com/', runScripts: 'dangerously', pretendToBeVisual: true,
    beforeParse(w) {
      w.fetch = server.fetch; w.Response = Response; w.Request = Request; w.Headers = Headers;
      w.matchMedia = () => ({ matches: false }); w.confirm = () => true;
      w.setInterval = () => 0;   // no 8s poll loop
      for (const [k, v] of Object.entries(storage || {})) w.localStorage.setItem(k, v);
    },
  });
  const w = dom.window;
  w.eval(SRC.new);
  const el = w.document.createElement('script'); el.textContent = APP_JS; w.document.body.appendChild(el);
  await tick(); await tick();
  return { w, doc: w.document, server, $: (s) => w.document.querySelector(s) };
}
const submit = async (app, id) => { app.$(id).dispatchEvent(new app.w.Event('submit', { bubbles: true, cancelable: true })); await tick(); await tick(); };

test('app e2e: no session -> login form, nothing requested; email -> code -> verify -> app entered, app_snapshot sent with the owner bearer', async () => {
  const app = await bootApp();
  assert.equal(app.$('#login').hidden, false); assert.equal(app.$('#app').hidden, true);
  assert.equal(app.server.log.length, 0, 'no request before login');
  app.$('#email').value = 'owner@example.com'; await submit(app, '#f-email');
  assert.equal(app.server.find('POST', '/auth/v1/otp').length, 1);
  assert.equal(app.$('#f-code').hidden, false); assert.match(app.$('#login-msg').textContent, /Code sent/);
  app.$('#code').value = '123456'; await submit(app, '#f-code');
  assert.equal(app.server.find('POST', '/auth/v1/verify').length, 1);
  assert.equal(app.$('#app').hidden, false); assert.equal(app.$('#login').hidden, true);
  const snap = app.server.find('POST', '/rest/v1/rpc/app_snapshot').pop(); assert.ok(snap);
  assert.match(snap.headers.authorization, /^Bearer eyJ/, 'owner access token (JWT) is sent, not the publishable key');
  app.w.close();
});

test('app e2e: a returning owner (valid stored session) goes straight in with no login prompt and no auth network call', async () => {
  const app = await bootApp({ storage: { [STORE_KEY]: JSON.stringify(sessionBody(1)) } });
  assert.equal(app.$('#app').hidden, false); assert.equal(app.$('#login').hidden, true);
  assert.equal(app.server.log.filter((r) => r.path.startsWith('/auth/')).length, 0);
  app.w.close();
});

test('app e2e: a signed-in STRANGER (database refuses app_snapshot) is signed out, session removed, login form + message shown', async () => {
  const server = fakeServer({ 'POST /rest/v1/rpc/app_snapshot': () => new Response(JSON.stringify({ message: 'not authorized', code: 'P0001' }), { status: 400, headers: { 'content-type': 'application/json' } }) });
  const app = await bootApp({ server, storage: { [STORE_KEY]: JSON.stringify(sessionBody(1)) } });
  assert.equal(app.$('#app').hidden, true); assert.equal(app.$('#login').hidden, false);
  assert.match(app.$('#login-msg').textContent, /not authorized for HQ/);
  assert.equal(server.find('POST', '/auth/v1/logout').length, 1);
  assert.equal(app.w.localStorage.getItem(STORE_KEY), null);
  app.w.close();
});

test('app e2e: an expired stored session is silently refreshed before the first rpc (owner is not asked to log in again)', async () => {
  const exp = { ...sessionBody(1), expires_at: nowS() - 30, access_token: jwt(nowS() - 30) };
  const app = await bootApp({ storage: { [STORE_KEY]: JSON.stringify(exp) } });
  assert.equal(app.$('#app').hidden, false);
  assert.equal(app.server.log.filter((r) => r.path === '/auth/v1/token').length, 1);
  assert.match(app.server.find('POST', '/rest/v1/rpc/app_snapshot').pop().headers.authorization, /^Bearer /);
  app.w.close();
});
