#!/usr/bin/env node
// Independent acceptance harness for the HQ PWA.   node scripts/qa/run.mjs --help
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { runQA } from './lib/driver.mjs';
import { renderReport } from './lib/report.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url)); const ROOT = path.resolve(HERE, '..', '..');
const HELP = `usage: node scripts/qa/run.mjs [options]
  --webapp <dir>     directory holding index.html (default: <repo>/webapp)
  --ref <git-ref>    test the webapp/ of a git ref without checking it out (e.g. origin/build/hq-experience); implies --branch <ref>
  --branch <name>    label for the report and the report file name (default: current git branch)
  --mode auto|demo|stub   auto = use the app's demo mode if it renders, else the harness stub backend (default)
  --demo-query <q>   how the app switches to demo mode (default from qa.config.json: ?demo=1)
  --report <file>    report path (default: /home/claude/QA_REPORT_<branch with / as ->.md)
  --out <dir>        screenshot dir (default: /home/claude/qa_out/<branch>)
  --only a,b         subset of: walk,xss,sw
  --config <file>    alternative config json (merged over qa.config.json)
exit code 1 when any check FAILs (use --no-fail-exit to always exit 0)`;
const a = process.argv.slice(2); const opt = {};
for (let i = 0; i < a.length; i++) { const k = a[i]; if (k === '--help' || k === '-h') { console.log(HELP); process.exit(0); } else if (k === '--no-fail-exit') opt.noFail = true; else if (k.startsWith('--')) opt[k.slice(2)] = a[++i]; }
const git = (...args) => { try { return execFileSync('git', ['-C', ROOT, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch (e) { return ''; } };
let webapp = opt.webapp ? path.resolve(opt.webapp) : path.join(ROOT, 'webapp'); let branch = opt.branch; let sha = '';
if (opt.ref) { const tmp = mkdtempSync(path.join(os.tmpdir(), 'qa-ref-')); execFileSync('sh', ['-c', `git -C '${ROOT}' archive '${opt.ref}' webapp | tar -x -C '${tmp}'`]); webapp = path.join(tmp, 'webapp'); branch = branch || opt.ref; sha = git('rev-parse', opt.ref); }
else if (!opt.webapp) sha = git('rev-parse', 'HEAD');
branch = branch || git('rev-parse', '--abbrev-ref', 'HEAD') || 'unknown';
const safe = branch.replace(/[^A-Za-z0-9._-]+/g, '-');
let cfg = JSON.parse(readFileSync(path.join(HERE, 'qa.config.json'), 'utf8'));
if (opt.config) { const over = JSON.parse(readFileSync(opt.config, 'utf8')); const merge = (x, y) => { for (const k of Object.keys(y)) x[k] = y[k] && typeof y[k] === 'object' && !Array.isArray(y[k]) && x[k] ? merge(x[k], y[k]) : y[k]; return x; }; cfg = merge(cfg, over); }
if (opt['demo-query']) cfg.demo.query = opt['demo-query'];
const outDir = opt.out || `/home/claude/qa_out/${safe}`; const report = opt.report || `/home/claude/QA_REPORT_${safe}.md`;
const R = await runQA({ webapp, config: cfg, branch, sha: sha || 'n/a', mode: opt.mode || 'auto', outDir, features: opt.only ? opt.only.split(',') : undefined });
mkdirSync(path.dirname(report), { recursive: true }); writeFileSync(report, renderReport(R));
console.log(`QA ${branch}: ${R.summary.PASS} pass, ${R.summary.FAIL} fail, ${R.summary.WARN} warn, ${R.summary.SKIP} not tested (mode ${R.meta.mode}). Report: ${report}`);
process.exit(R.summary.FAIL && !opt.noFail ? 1 : 0);
