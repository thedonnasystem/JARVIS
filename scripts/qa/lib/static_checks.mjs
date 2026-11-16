// Source-level checks on the shipped webapp/ directory (no browser): RPC names vs the safe allow-list, write verbs, DOM-injection sinks, service-worker precache list.
import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';

export function listFiles(dir, base = dir) {
  const out = [];
  for (const n of readdirSync(dir)) { const p = path.join(dir, n); if (statSync(p).isDirectory()) out.push(...listFiles(p, base)); else out.push(path.relative(base, p).split(path.sep).join('/')); }
  return out.sort();
}

// Shipped first-party JS (vendor/ is third-party and excluded from sink and verb scans, but reported).
export function firstPartyJs(webapp) {
  return listFiles(webapp).filter((f) => /\.(m?js)$/.test(f) && !f.startsWith('vendor/') && f !== 'sw.js');
}

const RPC_RES = [/\brpc\(\s*['"]([A-Za-z_]\w*)['"]/g, /\/rpc\/([A-Za-z_]\w*)/g];   // same two patterns as scripts/check_app_rpcs.py:js_rpc_names

export function rpcInventory(webapp, cfg) {
  const calls = new Map();   // name -> [files]
  const verbs = []; const kinds = new Set();
  for (const f of firstPartyJs(webapp)) {
    const t = readFileSync(path.join(webapp, f), 'utf8');
    for (const re of RPC_RES) for (const m of t.matchAll(re)) { if (!calls.has(m[1])) calls.set(m[1], []); calls.get(m[1]).push(f); }
    for (const m of t.matchAll(/\bact\(\s*'(\w+)'/g)) kinds.add(m[1]);
    for (const m of t.matchAll(/\bsend\(\s*[^,()]*,\s*'(\w+)'/g)) kinds.add(m[1]);
    for (const m of t.matchAll(/verb:\s*'(\w+)'/g)) verbs.push({ file: f, verb: m[1] });
  }
  const ro = new Set(cfg.rpc.readOnly); const low = new Set(cfg.rpc.lowRiskWrite); const deny = new RegExp(cfg.rpc.denyRe, 'i');
  const rows = [...calls.keys()].sort().map((name) => ({ name, files: [...new Set(calls.get(name))], cls: ro.has(name) ? 'read-only (allow-listed)' : low.has(name) ? 'low-risk write (allow-listed)' : deny.test(name) ? 'DENIED: changes a guard' : 'UNREVIEWED' }));
  const denyRe = new RegExp(cfg.controls.denyRe, 'i');
  const badKinds = [...kinds].filter((k) => denyRe.test(k) || new RegExp(cfg.rpc.denyRe, 'i').test(k));
  const badVerbs = [...new Set(verbs.filter((v) => denyRe.test(v.verb)).map((v) => v.file + ': verb ' + v.verb))];
  return { rows, kinds: [...kinds].sort(), badKinds, badVerbs };
}

export function sinkScan(webapp) {
  const sinks = []; const net = [];
  const files = listFiles(webapp).filter((f) => /\.(m?js|html)$/.test(f) && !f.startsWith('vendor/'));
  for (const f of files) {
    const t = readFileSync(path.join(webapp, f), 'utf8');
    for (const re of [/\.innerHTML\s*[+]?=/g, /\.outerHTML\s*=/g, /insertAdjacentHTML\s*\(/g, /document\.write(ln)?\s*\(/g, /\beval\s*\(/g, /new Function\s*\(/g, /setTimeout\(\s*['"`]/g, /\.srcdoc\s*=/g, /dangerouslySetInnerHTML/g])
      for (const m of t.matchAll(re)) sinks.push({ file: f, sink: m[0].trim() });
    for (const re of [/\bfetch\s*\(\s*['"`]https?:\/\/[^'"`)]+/g, /\bXMLHttpRequest\b/g, /\bsendBeacon\s*\(/g, /new WebSocket\s*\(/g, /new EventSource\s*\(/g, /importScripts\s*\(/g, /(?:src|href)=["']https?:\/\/[^"']+/g])
      for (const m of t.matchAll(re)) net.push({ file: f, ref: m[0].slice(0, 100) });
  }
  return { sinks, net };
}

export function precacheList(webapp, cfg) {
  const f = path.join(webapp, cfg.sw.file);
  if (!existsSync(f)) return { found: false, reason: cfg.sw.file + ' does not exist', list: [] };
  const t = readFileSync(f, 'utf8');
  let m = t.match(new RegExp('(?:' + cfg.sw.precacheNameRe + ')\\w*\\s*=\\s*\\[([^\\]]*)\\]', 'i')) || t.match(/addAll\(\s*\[([^\]]*)\]/);
  if (!m) return { found: true, parsed: false, reason: 'no precache array found in ' + cfg.sw.file, list: [] };
  return { found: true, parsed: true, list: [...m[1].matchAll(/['"]([^'"]+)['"]/g)].map((x) => x[1]) };
}
export const normAsset = (p) => { let s = p.replace(/^\.\//, '').replace(/^\//, '').split('?')[0].split('#')[0]; return s === '' || s === '.' ? 'index.html' : s; };
