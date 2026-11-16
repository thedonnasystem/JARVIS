// Tests of the QA harness itself: a clean synthetic app must pass, and each deliberate defect must be caught by the check that is meant to catch it.
// Run: node --test scripts/qa/test/harness.test.mjs   (needs Chromium via the system-wide playwright; adds no npm dependency)
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, writeFileSync, rmSync, appendFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runQA, loadPlaywright } from '../lib/driver.mjs';
import { renderReport } from '../lib/report.mjs';
import { injectPayload } from '../lib/stub_backend.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const cfg0 = JSON.parse(readFileSync(path.join(HERE, '..', 'qa.config.json'), 'utf8'));
const cfg = { ...cfg0, nav: { ...cfg0.nav, settleMs: 100, waitIdle: false }, sw: { ...cfg0.sw, offlineSettleMs: 200 } };
const tmps = []; let browser;
before(async () => { browser = await loadPlaywright().chromium.launch(); });
after(async () => { await browser.close(); for (const t of tmps) rmSync(t, { recursive: true, force: true }); });

// copy the good fixture, apply edits [file, from, to] (to === null appends `from` to the file), run the harness against it
async function run(edits = [], features = ['walk'], over = {}) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'qa-fx-')); tmps.push(dir);
  cpSync(path.join(HERE, 'fixtures', 'good'), dir, { recursive: true });
  for (const [f, from, to] of edits) {
    const p = path.join(dir, f);
    if (to === null) appendFileSync(p, from);
    else { const t = readFileSync(p, 'utf8'); assert.ok(t.includes(from), `fixture edit target not found in ${f}: ${from}`); writeFileSync(p, t.replace(from, to)); }
  }
  return runQA({ webapp: dir, config: cfg, branch: 'fixture', sha: 'x', mode: 'demo', outDir: path.join(dir, '_shots'), browser, features, ...over });
}
const get = (R, id) => R.checks.find((c) => c.id === id);
const status = (R, id) => { const c = get(R, id); assert.ok(c, `check ${id} missing; have ${R.checks.map((x) => x.id)}`); return c.status; };

test('clean fixture passes every check (positive control)', async () => {
  const R = await run([], ['walk', 'xss', 'sw']);
  const fails = R.checks.filter((c) => c.status === 'FAIL' || c.status === 'WARN').map((c) => `${c.id}: ${c.detail} ${c.evidence.slice(0, 3)}`);
  assert.deepEqual(fails, []);
  assert.equal(R.meta.mode, 'demo');
  assert.deepEqual(R.screens.map((s) => s.label), ['Home', 'Feed', 'About']);
  assert.equal(R.shots.length, 6, 'one screenshot per screen per viewport');
  assert.equal(status(R, 'badges-on-numeric-panels'), 'PASS');
  assert.match(get(R, 'xss-data-fields').detail, /visible literally on [1-9]/, 'positive control: payload reached the page');
  const md = renderReport(R);
  assert.match(md, /## Could not test/); assert.match(md, /PASS/);
});

test('missing SIMULATED badge on a numeric panel is flagged', async () => {
  const R = await run([['index.html', '<span class="badge" data-badge>NOT CONNECTED</span><h2>Bank</h2>', '<h2>Bank</h2>']]);
  assert.equal(status(R, 'badges-on-numeric-panels'), 'FAIL');
  assert.ok(get(R, 'badges-on-numeric-panels').evidence.some((e) => /Bank/.test(e)));
  assert.equal(get(R, 'badges-on-numeric-panels').perScreen.Home, 'FAIL');
  assert.equal(get(R, 'badges-on-numeric-panels').perScreen.Feed, 'PASS');
});

test('external request is caught and blocked', async () => {
  const R = await run([['app.js', "fetch('https://tracker.example.invalid/beacon').catch(() => {});\n", null]]);
  assert.equal(status(R, 'no-external-requests'), 'FAIL');
  assert.ok(get(R, 'no-external-requests').evidence.some((e) => /tracker\.example\.invalid/.test(e)));
});

test('external script tag in the HTML is flagged statically too', async () => {
  const R = await run([['index.html', '<script src="app.js"></script>', '<script src="app.js"></script><script src="https://cdn.example.invalid/x.js"></script>']]);
  assert.equal(status(R, 'static-external-references'), 'WARN');
  assert.equal(status(R, 'no-external-requests'), 'FAIL');
});

test('unescaped data and URL param are caught as XSS', async () => {
  const R = await run([['app.js', "fetch('data.json').then((r) => r.json()).then((d) => { document.getElementById('note').innerHTML = d.note; });\nif (q) document.getElementById('q').innerHTML = q;\n", null]], ['walk', 'xss']);
  assert.equal(status(R, 'xss-data-fields'), 'FAIL');
  assert.equal(status(R, 'xss-url-params'), 'FAIL');
  assert.equal(status(R, 'static-dom-sinks'), 'FAIL');
});

test('escaped rendering passes XSS checks and payload is shown literally', async () => {
  const R = await run([], ['walk', 'xss']);
  assert.equal(status(R, 'xss-data-fields'), 'PASS'); assert.equal(status(R, 'xss-url-params'), 'PASS');
});

test('horizontal overflow at 390 is caught (and not at 1440)', async () => {
  const R = await run([['index.html', '<p id="note">No numbers here</p>', '<p id="note">No numbers here</p><div id="wide" style="width:700px;height:20px;background:#ccc">wide</div>']]);
  assert.equal(status(R, 'no-overflow-390'), 'FAIL');
  assert.equal(status(R, 'no-overflow-1440'), 'PASS');
  assert.ok(get(R, 'no-overflow-390').evidence.some((e) => /wide/.test(e)));
});

test('a control that can change the kill switch / caps and a write RPC are caught', async () => {
  const R = await run([['index.html', '<h2>Notes</h2>', '<h2>Notes</h2><button id="cap">Set spend cap</button>'], ['app.js', "async function rpc(n){return n}\nrpc('app_set_kill');\nrpc('app_set_limit');\nrpc('app_snapshot');\n", null]]);
  assert.equal(status(R, 'no-guard-controls-dom'), 'FAIL');
  assert.equal(status(R, 'rpc-allow-list'), 'FAIL');
  const ev = get(R, 'rpc-allow-list').evidence.join('\n');
  assert.match(ev, /app_set_kill \[DENIED/); assert.match(ev, /app_set_limit \[DENIED/); assert.match(ev, /app_snapshot \[read-only/);
});

test('an unknown RPC is UNREVIEWED and fails until classified', async () => {
  const R = await run([['app.js', "rpc('app_do_something_new');\n", null]]);
  assert.match(get(R, 'rpc-allow-list').evidence.join('\n'), /app_do_something_new \[UNREVIEWED/);
  assert.equal(status(R, 'rpc-allow-list'), 'FAIL');
});

test('asset used but missing from the sw precache list, and a listed file that does not exist', async () => {
  const R = await run([['index.html', '<script src="app.js"></script>', '<script src="app.js"></script><script src="extra.js"></script>'], ['sw.js', "'data.json']", "'data.json','ghost.png']"]], ['walk', 'sw']);
  // extra.js does not exist -> 404 and not precached
  assert.equal(status(R, 'sw-precache-covers-assets'), 'FAIL');
  const ev = get(R, 'sw-precache-covers-assets').evidence.join('\n');
  assert.match(ev, /not precached: extra\.js/); assert.match(ev, /missing file: ghost\.png/);
  assert.equal(status(R, 'no-failed-or-http-error-requests'), 'FAIL');
});

test('a literal null in the UI, a tiny unlabeled button, console error and uncaught exception are caught', async () => {
  const R = await run([['index.html', '<h2>Notes</h2>', '<h2>Notes</h2><p id="leak">null</p><button style="width:20px;height:20px"></button>'], ['app.js', "console.error('boom');\nsetTimeout(() => { throw new Error('uncaught boom'); }, 50);\n", null]]);
  assert.equal(status(R, 'no-placeholder-leaks'), 'FAIL');
  assert.equal(status(R, 'a11y-names'), 'FAIL');
  assert.equal(status(R, 'tap-targets-390'), 'FAIL');
  assert.equal(status(R, 'no-console-or-uncaught-errors'), 'FAIL');
  assert.match(get(R, 'no-console-or-uncaught-errors').evidence.join('\n'), /uncaught boom|boom/);
});

test('low contrast text is flagged', async () => {
  const R = await run([['styles.css', 'body{', 'body{--x:0;'], ['index.html', '<h2>Notes</h2>', '<h2>Notes</h2><p style="color:#bbb">pale grey text</p>']]);
  assert.equal(status(R, 'contrast'), 'FAIL');
});

test('no demo mode (only a login screen) is reported as absent, and walk-dependent checks are not silently passed', async () => {
  const R = await run([['index.html', '<main id="app">', '<main id="app" hidden>'], ['index.html', '<nav>', '<nav hidden>']], ['walk', 'xss', 'sw']);
  assert.equal(status(R, 'demo-mode-available'), 'FAIL');
  assert.equal(R.screens.length, 0);
  assert.equal(R.checks.find((c) => c.id === 'badges-on-numeric-panels'), undefined);
  assert.ok(R.notTested.some((t) => /no screen could be opened/.test(t)));
  assert.equal(status(R, 'sw-precache-covers-assets'), 'SKIP');
});

test('mode auto falls back to stub only when the app has a Supabase URL; otherwise says nothing could be exercised', async () => {
  const R = await run([['index.html', '<nav>', '<nav hidden>'], ['index.html', '<main id="app">', '<main id="app" hidden>']], ['walk'], { mode: 'auto' });
  assert.equal(R.meta.mode, 'stub');
  assert.ok(R.notTested.some((t) => /no demo mode and no recognisable Supabase/.test(t)));
});

test('injectPayload keeps routing keys and ids intact and rotates payloads', () => {
  const out = injectPayload({ id: 'a', status: 'ok', name: 'N', list: [{ body: 'B', kind: 'chat' }], n: 5 }, ['P1', 'P2'], ['id', 'status', 'kind']);
  assert.deepEqual(out, { id: 'a', status: 'ok', name: 'N P1', list: [{ body: 'B P2', kind: 'chat' }], n: 5 });
});

test('offline reload of the demo URL fails when the service worker cache lookup ignores the query string (?demo=1 is a different cache key)', async () => {
  const R = await run([['sw.js', ',{ignoreSearch:true}', '']], ['walk', 'sw']);
  assert.equal(status(R, 'sw-precache-covers-assets'), 'PASS');
  assert.equal(status(R, 'offline-reload-renders'), 'FAIL');
});
