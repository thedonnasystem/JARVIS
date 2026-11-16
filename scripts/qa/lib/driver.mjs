// Playwright driver: serves a webapp/ directory, walks every navigation target it can discover and records the evidence for each check.
// It never clicks anything except navigation targets, and aborts every request that is not to the local server (or the stubbed backend in stub mode).
import { createRequire } from 'node:module';
import { readFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { startServer } from './server.mjs';
import { fixtures, injectPayload, fakeSession, makeStubHandler } from './stub_backend.mjs';
import * as P from './pagechecks.mjs';
import * as S from './static_checks.mjs';

export function loadPlaywright() {
  const req = createRequire(import.meta.url);
  for (const id of ['playwright', '/opt/npm-tools/node_modules/playwright', 'playwright-core']) { try { return req(id); } catch (e) { /* next */ } }
  throw new Error('playwright is not installed (expected a system-wide install; this harness adds no npm dependency)');
}
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'x';
const worst = (arr) => (arr.includes('FAIL') ? 'FAIL' : arr.includes('WARN') ? 'WARN' : arr.includes('SKIP') && !arr.includes('PASS') ? 'SKIP' : 'PASS');
const uniq = (a) => [...new Set(a)];

export async function runQA(o) {
  const cfg = o.config; const webapp = path.resolve(o.webapp);
  const outDir = path.resolve(o.outDir); mkdirSync(outDir, { recursive: true });
  const features = new Set(o.features || ['walk', 'xss', 'sw']);
  const R = { meta: { webapp, branch: o.branch || 'unknown', sha: o.sha || 'unknown', startedAt: new Date().toISOString(), mode: null, requestedMode: o.mode || 'auto', outDir }, checks: [], screens: [], notTested: [], stubLog: [], info: {} };
  const add = (c) => { R.checks.push({ evidence: [], perScreen: null, ...c }); };
  const notTested = (t) => R.notTested.push(t);
  const srv = await startServer(webapp);
  const pw = loadPlaywright(); const ownBrowser = !o.browser; const browser = o.browser || await pw.chromium.launch();
  R.meta.browser = 'chromium ' + browser.version();
  const start = cfg.startPath === 'index.html' ? srv.url : srv.url + cfg.startPath;
  const demoUrl = cfg.demo.query.startsWith('#') ? start + cfg.demo.query : start + cfg.demo.query;
  const localOrigin = srv.origin;

  // ---- static facts ----
  const appJs = S.firstPartyJs(webapp).map((f) => readFileSync(path.join(webapp, f), 'utf8')).join('\n');
  const refM = appJs.match(/https:\/\/([a-z0-9]+)\.supabase\.co/);
  const stubInfo = refM ? { ref: refM[1], hostRe: new RegExp('^' + refM[1] + '\\.supabase\\.co$') } : null;

  async function newCtx(vpName, { stub, data, swAllow, log }) {
    const vp = cfg.viewports[vpName];
    const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 1, serviceWorkers: swAllow ? 'allow' : 'block', hasTouch: vpName === 'phone', acceptDownloads: false });
    const reqs = []; ctx.on('request', (r) => reqs.push({ url: r.url(), method: r.method(), type: r.resourceType() }));
    if (stub && stubInfo) {
      const sess = fakeSession(stubInfo.ref);
      await ctx.addInitScript(([k, v]) => { try { if (!localStorage.getItem(k)) localStorage.setItem(k, v); } catch (e) { /* none */ } }, [sess.key, JSON.stringify(sess.value)]);
    }
    const handler = stub && stubInfo ? makeStubHandler({ data: data || fixtures(), log: log || ((e) => R.stubLog.push(e)) }) : null;
    await ctx.route((u) => u.origin !== localOrigin, async (route) => {
      const h = new URL(route.request().url()).hostname;
      if (handler && stubInfo.hostRe.test(h)) return handler(route);
      return route.abort('blockedbyclient');
    });
    return { ctx, reqs };
  }
  const isLocal = (u) => /^(data|blob|about):/.test(u) || u.startsWith(localOrigin);
  const settle = async (page, ms) => { if (cfg.nav.waitIdle !== false) await page.waitForLoadState('networkidle', { timeout: 3000 }).catch(() => {}); await page.waitForTimeout(ms ?? cfg.nav.settleMs); };
  const attachEvents = (page) => {
    const ev = { console: [], pageerror: [], reqfail: [], http: [], dialogs: [] };
    page.on('console', (m) => { if (m.type() === 'error') ev.console.push(m.text()); });
    page.on('pageerror', (e) => ev.pageerror.push(String((e && e.message) || e)));
    page.on('requestfailed', (r) => { if (isLocal(r.url())) ev.reqfail.push(r.method() + ' ' + r.url().replace(localOrigin, '') + ' ' + ((r.failure() || {}).errorText || '')); });
    page.on('response', (r) => { if (r.status() >= 400 && isLocal(r.url())) ev.http.push(r.status() + ' ' + r.url().replace(localOrigin, '')); });
    page.on('dialog', (d) => { ev.dialogs.push(d.type() + ': ' + d.message().slice(0, 80)); d.dismiss().catch(() => {}); });
    return ev;
  };

  // ---- 1. demo detection ----
  let mode = null; let demoState = { present: false, reason: '', marker: false };
  if (features.has('walk')) {
    const { ctx, reqs } = await newCtx('phone', { stub: false });
    const page = await ctx.newPage(); attachEvents(page);
    await page.goto(demoUrl, { waitUntil: 'load', timeout: 15000 }).catch(() => {}); await settle(page, 600);
    const navs = await page.evaluate(P.discoverNav, { selectors: cfg.nav.selectors, origin: localOrigin }).catch(() => []);
    const marker = await page.evaluate(({ sels, globals, re }) => sels.some((s) => document.querySelector(s)) || globals.some((g) => window[g]) || new RegExp(re).test(document.body ? document.body.innerText : ''), { sels: cfg.demo.markerSelectors, globals: cfg.demo.markerGlobals, re: cfg.demo.markerTextRe }).catch(() => false);
    demoState = { present: navs.length >= cfg.nav.minTargets, marker, navCount: navs.length, reason: navs.length >= cfg.nav.minTargets ? '' : `with ${cfg.demo.query} only ${navs.length} visible navigation target(s) rendered (min ${cfg.nav.minTargets}); the app most likely shows its login screen instead of demo data` };
    R.demoExternal = reqs.filter((r) => !isLocal(r.url)).map((r) => r.url);
    await ctx.close();
  }
  const want = R.meta.requestedMode;
  if (want === 'stub') mode = 'stub'; else if (want === 'demo') mode = 'demo'; else mode = demoState.present ? 'demo' : 'stub';
  R.meta.mode = mode; R.demo = demoState;
  if (features.has('walk')) {
    add({ id: 'demo-mode-available', title: `Demo mode reachable at "${cfg.demo.query}" (renders navigation with no sign-in)`, status: demoState.present ? 'PASS' : 'FAIL',
      detail: demoState.present ? `rendered ${demoState.navCount} navigation targets; demo marker ${demoState.marker ? 'found' : 'NOT found (nothing says "demo"/"simulated" on the page or in the DOM markers from qa.config.json)'}` : demoState.reason,
      evidence: demoState.present && !demoState.marker ? ['no demo marker: add data-demo / meta hq-demo / visible DEMO text so a user cannot mistake demo data for live'] : [] });
    if (mode === 'stub' && !stubInfo) { notTested('Signed-in screens: app has no demo mode and no recognisable Supabase project URL to stub, so nothing past the login could be exercised.'); }
    if (mode === 'stub') notTested('Demo-mode behaviour: this run used the harness stub backend (fixtures answering the app\'s own RPC calls), not a demo mode. "No external requests" is therefore only partially testable.');
  }
  const baseUrl = mode === 'demo' ? demoUrl : start;
  const useStub = mode === 'stub' && !!stubInfo;
  const canWalk = features.has('walk') && (mode === 'demo' ? demoState.present : useStub);

  // ---- 2. the walk (once per viewport) ----
  const allExternal = []; const allReqs = [];
  async function walk(vpName, { inject, shots }) {
    const data = inject ? injectPayload(fixtures(), cfg.xss.payloads, cfg.xss.preserveKeys) : fixtures();
    const { ctx, reqs } = await newCtx(vpName, { stub: useStub, data });
    let jsonInjected = 0;
    if (inject && mode === 'demo') {
      await ctx.route((u) => u.origin === localOrigin && /\.json$/i.test(u.pathname) && !/manifest/i.test(u.pathname), async (route) => {
        try { const resp = await route.fetch(); const j = await resp.json(); jsonInjected++; await route.fulfill({ response: resp, json: injectPayload(j, cfg.xss.payloads, cfg.xss.preserveKeys) }); } catch (e) { await route.continue(); }
      });
    }
    const page = await ctx.newPage(); const ev = attachEvents(page);
    await page.goto(baseUrl, { waitUntil: 'load', timeout: 15000 }).catch((e) => ev.pageerror.push('goto: ' + e.message));
    await settle(page, 700);
    const screens = []; const visited = new Set(); const pending = []; let discovered = new Map();
    const rediscover = async () => {
      const navs = await page.evaluate(P.discoverNav, { selectors: cfg.nav.selectors, origin: localOrigin }).catch(() => []);
      discovered = new Map(navs.map((n) => [n.key, n]));
      for (const n of navs) if (!visited.has(n.key) && !pending.includes(n.key)) pending.push(n.key);
      return navs;
    };
    const mark = () => ({ c: ev.console.length, p: ev.pageerror.length, f: ev.reqfail.length, h: ev.http.length, d: ev.dialogs.length });
    const record = async (label, m0, clickNote) => {
      await settle(page, cfg.nav.settleMs);
      await page.evaluate(() => document.querySelectorAll('details').forEach((d) => { d.open = true; })).catch(() => {});
      const n = screens.length + 1; const s = { index: n, label, vp: vpName, clickNote: clickNote || '', url: page.url().replace(localOrigin, '') };
      s.events = { console: ev.console.slice(m0.c), pageerror: ev.pageerror.slice(m0.p), reqfail: ev.reqfail.slice(m0.f), http: ev.http.slice(m0.h), dialogs: ev.dialogs.slice(m0.d) };
      if (shots) { const f = path.join(outDir, `${vpName}-${String(n).padStart(2, '0')}-${slug(label)}.png`); await page.screenshot({ path: f, fullPage: true }).then(() => { s.shot = f; }).catch((e) => { s.shotError = e.message; }); }
      if (!inject) {
        s.a11y = await page.evaluate(P.evalA11y, { tapFail: cfg.a11y.tapFailBelow, tapWarn: cfg.a11y.tapWarnBelow, contrastFail: cfg.a11y.contrastFailBelow, contrastWarn: cfg.a11y.contrastWarnBelow, maxSamples: cfg.a11y.maxContrastSamples, checkTap: vpName === 'phone' }).catch((e) => ({ issues: [], error: e.message }));
        s.overflow = await page.evaluate(P.evalOverflow).catch((e) => ({ overflow: false, error: e.message }));
        s.badges = await page.evaluate(P.evalBadges, { screenSel: cfg.screenSelector, panelSel: cfg.panelSelector, badgeRe: cfg.badges.textRe, attrSel: cfg.badges.attrSelector, screenScopeSel: cfg.badges.screenScopeSelector, numericRe: cfg.badges.numericRe, ageRe: cfg.badges.ignoreAgeTokensRe }).catch((e) => ({ panels: [], error: e.message }));
        s.leaks = await page.evaluate(P.evalLeaks).catch(() => []);
        s.controls = await page.evaluate(P.evalControls, { denyRe: cfg.controls.denyRe }).catch(() => []);
      }
      s.xss = await page.evaluate(P.evalXss).catch(() => ({ fired: 0, injectedNodes: [], literalVisible: false }));
      screens.push(s); visited.add(label); return s;
    };
    let m0 = mark();
    const first = await rediscover();
    const sel = first.find((x) => x.selected);
    const firstLabel = sel ? sel.label : '(initial screen)';
    await record(firstLabel, { c: 0, p: 0, f: 0, h: 0, d: 0 });
    if (sel) visited.add(sel.key);
    let guard = 0;
    while (pending.length && screens.length < cfg.nav.maxScreens && guard++ < cfg.nav.maxScreens * 3) {
      const key = pending.shift(); if (visited.has(key)) continue; visited.add(key);
      const navs = await rediscover(); const t = navs.find((x) => x.key === key);
      if (!t) { screens.push({ index: screens.length + 1, label: key.split('|')[1] || key, vp: vpName, missing: true, events: { console: [], pageerror: [], reqfail: [], http: [], dialogs: [] }, xss: {} }); continue; }
      m0 = mark();
      let note = '';
      await page.click(`[data-qa-nav="${t.tag}"]`, { timeout: 3000 }).catch((e) => { note = 'click failed: ' + e.message.split('\n')[0]; });
      if (!page.url().startsWith(localOrigin)) { note += ' navigated off-origin to ' + page.url(); await page.goBack().catch(() => {}); }
      await record(t.label, m0, note);
      await rediscover();
    }
    // keep-alive: collect everything the page asked for
    allReqs.push(...reqs.map((r) => ({ ...r, vp: vpName, inject: !!inject })));
    const out = { screens, reqs, jsonInjected, ev };
    await ctx.close(); return out;
  }

  let walks = {};
  if (canWalk) {
    for (const vp of Object.keys(cfg.viewports)) walks[vp] = await walk(vp, { inject: false, shots: true });
    R.screens = walks.phone.screens; R.desktopScreens = walks.desktop ? walks.desktop.screens : [];
    R.shots = [...walks.phone.screens, ...(walks.desktop ? walks.desktop.screens : [])].filter((s) => s.shot).map((s) => s.shot);
  }

  // ---- aggregate per-screen checks ----
  const phoneScreens = R.screens.filter((s) => !s.missing);
  const perScreen = (fn, scr = phoneScreens) => Object.fromEntries(scr.map((s) => [s.label, fn(s)]));
  const lines = (s, key) => ((s.events || {})[key] || []);
  if (canWalk) {
    const all = [...phoneScreens, ...(R.desktopScreens || []).filter((s) => !s.missing)];
    add({ id: 'walk-discovered-screens', title: 'Navigation targets discovered and every one opened', status: phoneScreens.length >= cfg.nav.minTargets && !R.screens.some((s) => s.missing || s.clickNote) ? 'PASS' : phoneScreens.length >= 1 ? 'WARN' : 'FAIL',
      detail: `${phoneScreens.length} screens: ${phoneScreens.map((s) => s.label).join(', ')}`, evidence: R.screens.filter((s) => s.missing || s.clickNote).map((s) => `${s.label}: ${s.missing ? 'target vanished' : s.clickNote}`) });
    const errsOf = (s) => [...lines(s, 'console').map((x) => 'console.error: ' + x), ...lines(s, 'pageerror').map((x) => 'uncaught: ' + x)].filter((x) => !/Failed to load resource/.test(x));
    add({ id: 'no-console-or-uncaught-errors', title: 'No console errors or uncaught exceptions on any screen (390 and 1440)', status: all.some((s) => errsOf(s).length) ? 'FAIL' : 'PASS',
      detail: `${all.reduce((n, s) => n + errsOf(s).length, 0)} error(s) over ${all.length} screen views`, evidence: uniq(all.flatMap((s) => errsOf(s).map((e) => `[${s.vp}] ${s.label}: ${e}`))).slice(0, 15),
      perScreen: perScreen((s) => (errsOf(s).length || (R.desktopScreens.find((d) => d.label === s.label && errsOf(d).length)) ? 'FAIL' : 'PASS')) });
    const failedOf = (s) => [...lines(s, 'reqfail'), ...lines(s, 'http')];
    add({ id: 'no-failed-or-http-error-requests', title: 'No failed requests or HTTP >= 400 responses (local assets)', status: all.some((s) => failedOf(s).length) ? 'FAIL' : 'PASS',
      detail: `${all.reduce((n, s) => n + failedOf(s).length, 0)} failing local request(s)`, evidence: uniq(all.flatMap((s) => failedOf(s).map((e) => `[${s.vp}] ${s.label}: ${e}`))).slice(0, 15), perScreen: perScreen((s) => (failedOf(s).length ? 'FAIL' : 'PASS')) });
    const dlg = all.filter((s) => lines(s, 'dialogs').length);
    add({ id: 'no-unexpected-dialogs', title: 'No alert/confirm/prompt dialogs fired while merely navigating', status: dlg.length ? 'FAIL' : 'PASS', detail: `${dlg.length} screen(s) opened a dialog`, evidence: dlg.flatMap((s) => lines(s, 'dialogs').map((d) => `${s.label}: ${d}`)) });

    // external requests
    const ext = uniq(allReqs.filter((r) => !isLocal(r.url)).map((r) => { try { return new URL(r.url).origin; } catch (e) { return r.url; } }));
    const demoExt = uniq((R.demoExternal || []).map((u) => { try { return new URL(u).origin; } catch (e) { return u; } }));
    const allowed = new Set(cfg.externalAllowHosts);
    const bad = ext.filter((x) => !allowed.has(new URL(x).hostname) && !(useStub && stubInfo.hostRe.test(new URL(x).hostname)));
    const stubbedHosts = ext.filter((x) => useStub && stubInfo.hostRe.test(new URL(x).hostname));
    if (mode === 'demo') add({ id: 'no-external-requests', title: 'Demo mode makes NO non-local network request', status: ext.length || demoExt.length ? 'FAIL' : 'PASS', detail: ext.length ? `attempted: ${ext.join(', ')}` : 'every request went to the local static server', evidence: uniq([...ext, ...demoExt]) });
    else add({ id: 'no-external-requests', title: 'No non-local network request other than the app\'s own backend (stubbed in this run)', status: bad.length ? 'FAIL' : stubbedHosts.length ? 'WARN' : 'PASS',
      detail: bad.length ? `unexpected external origins: ${bad.join(', ')}` : stubbedHosts.length ? `only the backend host ${stubbedHosts.join(', ')} was contacted (answered by the harness stub). A real demo mode must contact nothing.` : 'no external requests', evidence: [...bad, ...stubbedHosts.map((h) => 'backend (stubbed): ' + h)] });

    // a11y
    const issuesOf = (s, rules) => ((s.a11y || {}).issues || []).filter((i) => rules.test(i.rule));
    const mk = (id, title, rules, failSev = 'fail') => {
      const all2 = phoneScreens.flatMap((s) => issuesOf(s, rules).map((i) => ({ s, i })));
      const f = all2.filter((x) => x.i.severity === 'fail'), w = all2.filter((x) => x.i.severity === 'warn');
      add({ id, title, status: f.length ? 'FAIL' : w.length ? 'WARN' : 'PASS', detail: `${f.length} failing, ${w.length} warning over ${phoneScreens.length} screens`,
        evidence: uniq(all2.map((x) => `${x.i.severity.toUpperCase()} ${x.s.label}: ${x.i.rule} ${x.i.node}`)).slice(0, 25),
        perScreen: perScreen((s) => { const l = issuesOf(s, rules); return l.some((i) => i.severity === 'fail') ? 'FAIL' : l.length ? 'WARN' : 'PASS'; }) });
    };
    mk('a11y-names', 'Every visible control/image has an accessible name', /^(name-|img-alt)/);
    mk('tap-targets-390', `Tap targets >= ${cfg.a11y.tapWarnBelow}px (fail < ${cfg.a11y.tapFailBelow}px) at 390x844`, /^tap-/);
    mk('contrast', `Text contrast >= ${cfg.a11y.contrastWarnBelow}:1 (fail < ${cfg.a11y.contrastFailBelow}:1; solid backgrounds only)`, /^contrast-/);
    const docIssues = await documentChecks();
    add({ id: 'a11y-document', title: 'Document basics: lang, title, viewport, main/nav/header landmarks, a heading', status: docIssues.some((d) => !d.ok) ? 'FAIL' : 'PASS', detail: docIssues.map((d) => `${d.rule}:${d.ok ? 'ok' : 'MISSING'}`).join(' '), evidence: docIssues.filter((d) => !d.ok).map((d) => d.rule) });
    const ov = (list, id, vpLabel) => add({ id, title: `No horizontal overflow at ${vpLabel}`, status: list.some((s) => s.overflow && s.overflow.overflow) ? 'FAIL' : 'PASS', detail: `${list.filter((s) => s.overflow && s.overflow.overflow).length} of ${list.length} screens overflow`,
      evidence: list.filter((s) => s.overflow && s.overflow.overflow).map((s) => `${s.label}: scrollWidth ${s.overflow.scrollWidth} > ${s.overflow.innerWidth}; ${s.overflow.offenders.join('; ')}`), perScreen: perScreen((s) => (s.overflow && s.overflow.overflow ? 'FAIL' : 'PASS'), list) });
    ov(phoneScreens, 'no-overflow-390', '390x844'); ov((R.desktopScreens || []).filter((s) => !s.missing), 'no-overflow-1440', '1440x900');
    add({ id: 'screenshots', title: 'Screenshot captured for each screen at 390x844 and 1440x900', status: R.shots.length === phoneScreens.length + (R.desktopScreens || []).filter((s) => !s.missing).length && R.shots.length ? 'PASS' : 'FAIL', detail: `${R.shots.length} files in ${outDir}`, evidence: [] });

    // badges
    const panelsAll = phoneScreens.flatMap((s) => ((s.badges || {}).panels || []).map((p) => ({ s, p })));
    const unb = panelsAll.filter((x) => !x.p.covered);
    add({ id: 'badges-on-numeric-panels', title: 'Every panel showing numbers/money carries a SIMULATED / NOT CONNECTED / INCOMPLETE / LIVE badge', status: !panelsAll.length ? 'SKIP' : unb.length ? 'FAIL' : 'PASS',
      detail: `${panelsAll.length - unb.length} of ${panelsAll.length} numeric panels badged`, evidence: unb.map((x) => `${x.s.label} > ${x.p.label} ("${x.p.sample}")`).slice(0, 40),
      perScreen: perScreen((s) => { const l = ((s.badges || {}).panels || []); return !l.length ? 'PASS' : l.some((p) => !p.covered) ? 'FAIL' : 'PASS'; }) });
    const leaks = phoneScreens.flatMap((s) => (s.leaks || []).map((l) => `${s.label}: ${l}`));
    add({ id: 'no-placeholder-leaks', title: 'No literal "null" / "undefined" / "NaN" / "[object Object]" visible on any screen', status: leaks.length ? 'FAIL' : 'PASS', detail: `${leaks.length} leak(s)`, evidence: uniq(leaks).slice(0, 20), perScreen: perScreen((s) => ((s.leaks || []).length ? 'FAIL' : 'PASS')) });
    // guard controls (DOM)
    const ctl = uniq(R.screens.flatMap((s) => (s.controls || []).map((c) => `${c.control} "${c.text}" (${c.visibleNow ? 'visible' : 'hidden'} on ${s.label})`)));
    add({ id: 'no-guard-controls-dom', title: 'No control in the DOM can change the kill switch, spend caps, permissions or financial limits', status: ctl.length ? 'FAIL' : 'PASS', detail: `${ctl.length} matching control(s)`, evidence: ctl.slice(0, 25) });
  } else if (features.has('walk')) {
    for (const t of ['screens', 'accessibility', 'overflow', 'badges', 'DOM guard-control scan']) notTested(`Per-screen ${t}: no screen could be opened (demo mode absent and no stub possible).`);
  }
  async function documentChecks() {
    const { ctx } = await newCtx('phone', { stub: useStub });
    const page = await ctx.newPage(); await page.goto(baseUrl, { waitUntil: 'load' }).catch(() => {}); await settle(page, 600);
    const r = await page.evaluate(P.evalDocument); await ctx.close(); return r;
  }

  // ---- 3. static checks ----
  const inv = S.rpcInventory(webapp, cfg);
  const badRpc = inv.rows.filter((r) => r.cls.startsWith('DENIED') || r.cls === 'UNREVIEWED');
  add({ id: 'rpc-allow-list', title: 'Shipped JS calls only allow-listed RPCs; no write RPC that changes kill switch, caps, permissions or limits', status: badRpc.length || inv.badKinds.length || inv.badVerbs.length ? 'FAIL' : 'PASS',
    detail: `${inv.rows.length} RPC name(s) called; ${badRpc.length} not on the safe list`, evidence: [...inv.rows.map((r) => `${r.name} [${r.cls}] in ${r.files.join(',')}`), ...inv.badKinds.map((k) => 'app_send kind: ' + k), ...inv.badVerbs.map((v) => 'verb: ' + v)] });
  const sk = S.sinkScan(webapp);
  add({ id: 'static-dom-sinks', title: 'No innerHTML/outerHTML/insertAdjacentHTML/document.write/eval in first-party JS', status: sk.sinks.length ? 'FAIL' : 'PASS', detail: `${sk.sinks.length} sink use(s)`, evidence: sk.sinks.slice(0, 15).map((x) => `${x.file}: ${x.sink}`) });
  add({ id: 'static-external-references', title: 'No hard-coded external script/link/fetch/WebSocket targets in shipped source', status: sk.net.length ? 'WARN' : 'PASS', detail: `${sk.net.length} reference(s)`, evidence: sk.net.slice(0, 15).map((x) => `${x.file}: ${x.ref}`) });

  // ---- 4. XSS ----
  if (canWalk && features.has('xss')) {
    const w = await walk('phone', { inject: true, shots: false });
    const fired = w.screens.reduce((n, s) => n + (s.xss.fired || 0), 0) + w.ev.dialogs.length;
    const nodes = uniq(w.screens.flatMap((s) => (s.xss.injectedNodes || []).map((x) => `${s.label}: ${x}`)));
    const visible = w.screens.filter((s) => s.xss.literalVisible).length;
    const injectedInto = mode === 'demo' ? w.jsonInjected : R.stubLog.length;
    if (mode === 'demo' && !w.jsonInjected) { add({ id: 'xss-data-fields', title: 'Payloads injected into demo data fields are rendered as inert text', status: 'SKIP', detail: 'demo data is not served as a local .json file, so the harness could not substitute payloads', evidence: [] });
      notTested('XSS via demo data fields: demo data is embedded in JS (or not fetched as .json). Ask the builder to expose it as a JSON file, or to honour window.__QA_PAYLOAD__.'); }
    else add({ id: 'xss-data-fields', title: 'Payloads injected into data fields (HTML/script/SVG/javascript:) are rendered as inert text', status: fired || nodes.length ? 'FAIL' : !visible ? 'WARN' : 'PASS',
      detail: `payload executed ${fired}x, ${nodes.length} live injected node(s); payload text visible literally on ${visible}/${w.screens.length} screens${visible ? '' : ' (positive control missing: payloads never reached the page, result inconclusive)'}`, evidence: [...nodes, ...w.ev.dialogs.map((d) => 'dialog: ' + d)] });
    // url params
    const { ctx } = await newCtx('phone', { stub: useStub }); const page = await ctx.newPage(); const ev = attachEvents(page); const hits = []; let echoed = 0;
    for (const pay of cfg.xss.payloads) {
      const q = cfg.xss.urlParams.map((k) => `${k}=${encodeURIComponent(pay)}`).join('&');
      for (const url of [`${start}${cfg.demo.query.startsWith('?') && mode === 'demo' ? cfg.demo.query + '&' : '?'}${q}`, `${baseUrl.split('#')[0]}#${encodeURIComponent(pay)}`, `${baseUrl.split('#')[0]}#${pay}`]) {
        await page.goto(url, { waitUntil: 'load', timeout: 10000 }).catch(() => {}); await settle(page, 300);
        const r = await page.evaluate(P.evalXss).catch(() => ({ fired: 0, injectedNodes: [] }));
        if (r.fired || r.injectedNodes.length) hits.push(`${url.slice(0, 90)} -> fired ${r.fired} ${r.injectedNodes.join(',')}`);
        if (r.literalVisible) echoed++;
      }
    }
    const dl = ev.dialogs.slice(); await ctx.close();
    add({ id: 'xss-url-params', title: 'XSS payloads in query-string parameters and the URL fragment are not executed or injected', status: hits.length || dl.length ? 'FAIL' : 'PASS', detail: `${cfg.xss.payloads.length * 3} URL probes (params: ${cfg.xss.urlParams.join(',')}), ${hits.length} executed; ${echoed} probe(s) echoed the payload as visible text`, evidence: [...hits, ...dl.map((d) => 'dialog: ' + d)] });
  } else if (features.has('xss')) { notTested('XSS probes: nothing could be rendered.'); }

  // ---- 5. service worker / offline ----
  if (features.has('sw')) {
    const pre = S.precacheList(webapp, cfg); const swFile = existsSync(path.join(webapp, cfg.sw.file));
    if (!swFile) add({ id: 'sw-precache-covers-assets', title: 'Every asset used is in the service worker precache list', status: 'FAIL', detail: `${cfg.sw.file} does not exist: no offline support`, evidence: [] });
    else if (!canWalk) { add({ id: 'sw-precache-covers-assets', title: 'Every asset used is in the service worker precache list', status: 'SKIP', detail: 'app could not be loaded', evidence: [] }); }
    else {
      const { ctx, reqs } = await newCtx('phone', { stub: useStub, swAllow: true });
      const page = await ctx.newPage(); const ev = attachEvents(page);
      await page.goto(baseUrl, { waitUntil: 'load', timeout: 15000 }).catch(() => {}); await settle(page, 700);
      const ready = await page.evaluate(() => (navigator.serviceWorker ? Promise.race([navigator.serviceWorker.ready.then(() => true), new Promise((r) => setTimeout(() => r(false), 4000))]) : false)).catch(() => false);
      await page.waitForTimeout(cfg.sw.offlineSettleMs);
      // walk the nav once so lazily loaded assets are requested too
      const navs = await page.evaluate(P.discoverNav, { selectors: cfg.nav.selectors, origin: localOrigin }).catch(() => []);
      for (const n of navs.slice(0, 12)) { await page.click(`[data-qa-nav="${n.tag}"]`, { timeout: 2000 }).catch(() => {}); await page.waitForTimeout(150); await page.evaluate(P.discoverNav, { selectors: cfg.nav.selectors, origin: localOrigin }).catch(() => {}); }
      const loaded = uniq(reqs.filter((r) => r.method === 'GET' && r.url.startsWith(localOrigin)).map((r) => S.normAsset(new URL(r.url).pathname)).filter((a) => a !== cfg.sw.file));
      const cached = await page.evaluate(async () => { const o = {}; for (const k of await caches.keys()) o[k] = (await (await caches.open(k)).keys()).map((r) => new URL(r.url).pathname); return o; }).catch(() => ({}));
      const preN = new Set(pre.list.map(S.normAsset)); const missing = loaded.filter((a) => !preN.has(a));
      const absentOnDisk = [...preN].filter((a) => !existsSync(path.join(webapp, a)));
      const cachedFlat = new Set(Object.values(cached).flat().map((p) => S.normAsset(p)));
      const notCachedLive = loaded.filter((a) => !cachedFlat.has(a));
      R.info.sw = { ready, precache: [...preN], loaded, cachedKeys: Object.keys(cached), cachedCount: cachedFlat.size, missing, notCachedLive };
      add({ id: 'sw-precache-covers-assets', title: 'Every asset the app loads is in the service worker precache list (and every listed file exists)', status: !pre.parsed ? 'FAIL' : missing.length || absentOnDisk.length ? 'FAIL' : 'PASS',
        detail: pre.parsed ? `${loaded.length} assets loaded, ${preN.size} precached, ${missing.length} loaded-but-not-precached, ${absentOnDisk.length} listed-but-missing-on-disk; SW ready=${ready}` : pre.reason, evidence: [...missing.map((a) => 'not precached: ' + a), ...absentOnDisk.map((a) => 'precache lists missing file: ' + a)] });
      // offline reload
      let offline = { ok: false, why: '' };
      await ctx.setOffline(true); const m0 = ev.reqfail.length;
      try { await page.reload({ waitUntil: 'load', timeout: 8000 }); await page.waitForTimeout(700);
        const r = await page.evaluate(() => ({ text: (document.body.innerText || '').trim().length, title: document.title, hasApp: !!document.querySelector('main, #app, [role=main]') }));
        const fails = ev.reqfail.slice(m0);
        offline = { ok: r.text > 0 && r.hasApp && !fails.length, why: `rendered text=${r.text} chars, title="${r.title}", app shell=${r.hasApp}, ${fails.length} failed local request(s): ${fails.join('; ')}` };
      } catch (e) { offline = { ok: false, why: 'offline reload threw: ' + e.message.split('\n')[0] }; }
      add({ id: 'offline-reload-renders', title: 'With the network off, reloading renders the app shell with no failed local request', status: !ready ? 'FAIL' : offline.ok ? 'PASS' : 'FAIL', detail: !ready ? 'service worker never became active' : offline.why, evidence: [] });
      await ctx.close();
    }
  }

  // ---- 6. finish ----
  R.meta.finishedAt = new Date().toISOString(); R.meta.serverHits = srv.served.length;
  R.info.rpc = inv.rows; R.info.stubRpcCalls = uniq(R.stubLog.filter((e) => e.kind === 'rpc').map((e) => e.name + (e.method !== 'POST' ? ' ' + e.method : '')));
  R.info.allRequests = allReqs.length;
  notTested('Authenticated production behaviour, real backend data, push notifications, microphone/speech input and any control that needs a click beyond navigation (the harness never presses action buttons).');
  notTested('Real iOS Safari / installed-PWA rendering (Chromium only), screen-reader output, keyboard-only traversal, and colour contrast over gradients/images (solid backgrounds only).');
  await srv.close(); if (ownBrowser) await browser.close();
  R.summary = Object.fromEntries(['PASS', 'FAIL', 'WARN', 'SKIP'].map((k) => [k, R.checks.filter((c) => c.status === k).length]));
  return R;
}
