// Markdown report generator: PASS/FAIL per check, per-screen matrix, screenshot paths, honest "could not test" list.
const ICON = { PASS: 'PASS', FAIL: 'FAIL', WARN: 'WARN', SKIP: 'NOT TESTED' };

export function renderReport(R) {
  const L = []; const m = R.meta;
  L.push(`# QA acceptance report: ${m.branch}`, '');
  L.push(`- Branch: \`${m.branch}\` @ \`${m.sha}\``, `- Webapp dir: \`${m.webapp}\``, `- Run: ${m.startedAt} to ${m.finishedAt || '?'} (${m.browser})`);
  L.push(`- Mode: **${m.mode || 'none'}** (requested: ${m.requestedMode}). ${m.mode === 'demo' ? 'The app\'s own demo mode was used; any non-local request is a failure.' : m.mode === 'stub' ? 'The app has no usable demo mode on this branch, so the HARNESS answered the app\'s backend calls from fixtures. Findings below are about the app\'s UI/code, not about a demo mode.' : 'No screens could be opened.'}`);
  L.push(`- Screenshots: \`${m.outDir}\``, '');
  const s = R.summary || {};
  L.push(`## Verdict`, '', `**${s.FAIL ? 'FAIL' : 'PASS'}**: ${s.PASS || 0} pass, ${s.FAIL || 0} fail, ${s.WARN || 0} warn, ${s.SKIP || 0} not tested (of ${R.checks.length} checks).`, '');
  L.push('This harness only observes. A PASS means "the check found no defect on the screens it could open", not that the feature is correct end to end. Items under "Could not test" are NOT covered.', '');
  L.push('## Checks', '', '| Check | Result | Detail |', '|---|---|---|');
  for (const c of R.checks) L.push(`| \`${c.id}\` ${c.title} | **${ICON[c.status]}** | ${String(c.detail).replace(/\|/g, '/').replace(/\n/g, ' ')} |`);
  const scr = (R.screens || []).filter((x) => !x.missing);
  const per = R.checks.filter((c) => c.perScreen);
  if (scr.length && per.length) {
    L.push('', '## Per-screen matrix (390x844)', '', `| Screen | ${per.map((c) => c.id).join(' | ')} |`, `|---|${per.map(() => '---').join('|')}|`);
    for (const x of scr) L.push(`| ${x.label} | ${per.map((c) => ICON[(c.perScreen || {})[x.label] || 'PASS'].replace('NOT TESTED', 'n/t')).join(' | ')} |`);
  }
  const bad = R.checks.filter((c) => (c.status === 'FAIL' || c.status === 'WARN') && c.evidence.length);
  if (bad.length) { L.push('', '## Evidence for failures and warnings'); for (const c of bad) { L.push('', `### ${c.status}: \`${c.id}\``, c.detail, ''); for (const e of c.evidence.slice(0, 30)) L.push(`- ${String(e).replace(/\n/g, ' ')}`); if (c.evidence.length > 30) L.push(`- ... ${c.evidence.length - 30} more`); } }
  const ok = R.checks.filter((c) => c.status === 'PASS' && c.evidence.length);
  if (ok.length) { L.push('', '## Evidence for passes (what was actually seen)'); for (const c of ok) { L.push('', `### \`${c.id}\``); for (const e of c.evidence.slice(0, 12)) L.push(`- ${e}`); } }
  if (R.info && R.info.rpc) { L.push('', '## RPC inventory (shipped JS)', ''); for (const r of R.info.rpc) L.push(`- \`${r.name}\`: ${r.cls} (${r.files.join(', ')})`); }
  if (R.info && R.info.sw) { const w = R.info.sw; L.push('', '## Service worker', '', `- active: ${w.ready}; precache list (${w.precache.length}): ${w.precache.join(', ')}`, `- loaded by the app (${w.loaded.length}): ${w.loaded.join(', ')}`, `- not precached: ${w.missing.join(', ') || 'none'}`, `- cache storages after activation: ${w.cachedKeys.join(', ') || 'none'} (${w.cachedCount} entries)`); }
  if (R.stubLog && R.stubLog.length) L.push('', '## Stubbed backend', '', `RPCs the app called during the passive walk (all answered by the harness, none real): ${(R.info.stubRpcCalls || []).join(', ')}. No write RPC is fired by navigation alone${(R.info.stubRpcCalls || []).some((x) => /app_(send|set_|save)/.test(x)) ? ' (NOTE: a write-looking RPC WAS called during navigation, see list)' : ''}.`);
  if (R.shots && R.shots.length) { L.push('', '## Screenshots', ''); for (const f of R.shots) L.push(`- \`${f}\``); }
  L.push('', '## Could not test', ''); for (const t of [...new Set(R.notTested)]) L.push(`- ${t}`);
  return L.join('\n') + '\n';
}
