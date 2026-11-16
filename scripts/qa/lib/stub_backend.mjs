// Answers the Supabase project the shipped (pre-demo) PWA talks to, from fixtures, so the signed-in screens can be exercised with no real backend.
// Used only when the app has no demo mode of its own. Every stubbed request is recorded and reported as "stubbed backend", never as a pass for "no external requests".
const now = Date.now();
const iso = (minAgo) => new Date(now - minAgo * 60000).toISOString();

export function fixtures() {
  return {
    app_snapshot: {
      state: { kill_switch: false, pause_reason: null, mode: 'dry_run', last_heartbeat: iso(2), cap_cents: 330 },
      capital: { available_cents: 12345, mode: 'normal', fund_cents: 20000, revenue_cents: 0, ai_spend_cents: 100, expense_cents: 0, reserved_cents: 0, recurring_monthly_cents: 0,
        week_spend_cents: 50, weekly_limit_cents: 5000, per_transaction_limit_cents: 2000, min_reserve_cents: 1000 },
      spend_today_cents: 42,
      needs_you: [{ id: 'm-appr', kind: 'proposal', body: 'Spend $5 on ads\nlonger text', options: null, needs_decision: true, created_at: iso(30) },
        { id: 'm-q', kind: 'proposal', body: 'Which city first?', options: ['Ottawa', 'Toronto'], needs_decision: false, created_at: iso(90) }],
      ventures: [{ slug: 'donna', name: 'Donna HVAC', status: 'active', agents: 3, leads: 4, in_cents: 0, out_cents: 0, expected_cents: 5000, ai_cents_7d: 120 }],
      venture_stage: { donna: 'prospecting' }, tasks: { todo: 2, doing: 1, blocked: 1, done_24h: 5 }, leads: { total: 4, due: 1 },
      due_leads: [{ sid: 7, name: 'Jane Doe', phone: '613-555-0101', notes: 'call back', due: '2026-11-13' }],
      drafts: [{ id: 'd1', to: 'a@b.ca', body: 'Hello there', agent: 'donna-division', status: 'draft', created_at: iso(10) }],
      dayjob: { today: { dials: 10, pitches: 1, submissions: 0, paid_deals: 0 }, targets: { dials_per_day: 250, pitches_per_day: 6, submissions_per_day: 1 }, week: 'Week: 40 dials' },
      missions: [{ id: 'mis-blocked', title: 'Mission: Cold email test', status: 'blocked', verdict: 'GO', budget_cents: 200, spent_cents: 50, objective: 'Test cold email', next_action: 'Blocked: step failed', updated_at: iso(300) },
        { id: 'mis-run', title: 'Mission: Map leads', status: 'executing', verdict: 'GO', budget_cents: 200, spent_cents: 20, objective: 'Map', updated_at: iso(20) }],
      ideas: [{ id: 'i1', name: 'Garage cleanouts', status: 'new', score: 7, cost_cents: 5000, kill_metric: '0 calls' }],
      agents: [{ slug: 'jarvis', title: 'Jarvis', role: 'ceo', status: 'active', tier: 'smart', venture: null, spent_today: 10, cap_cents: 100, open: 1, done_7d: 4, last_task: 'Plan day' }],
      scorecard: { jarvis: { flag: 'ok' } }, org_changes: [{ kind: 'agent', status: 'proposed', change: 'Hire a closer agent', gain: 'more calls', cost: '$3/mo' }],
      feed: [{ at: iso(5), type: 'task', who: 'jarvis', text: 'Planned the day', status: 'done' }],
      spend_7d: [{ d: '2026-11-12', c: 77 }], policy: [{ action: 'send_email', tier: 'red' }], systems: [{ name: 'Render', status: 'ok' }], pnl: null, bank_alerts: [],
    },
    app_messages: [{ id: 'c1', role: 'jarvis', kind: 'chat', body: 'Good morning. Two things need you.', created_at: iso(3) }, { id: 'c2', role: 'owner', kind: 'chat', body: 'ok', created_at: iso(2) }],
    app_office: [{ fn: 'executive', name: 'Executive Office', staffed: true, agents: [{ slug: 'jarvis', title: 'Jarvis', status: 'active', spent_today: 10, cap: 100 }], open: 1, blocked: 0, done_7d: 4, spent_7d: 90, headline: '2 live missions' }],
    app_payments: [{ id: 'p1', cents: 4200, payee: 'Hosting Co', purpose: 'Monthly hosting', status: 'approved', due: '2026-11-20' }],
    app_needs_you: [{ rank: 1, kind: 'approval', ref_id: 'm-appr', title: 'Spend $5 on ads', created_at: iso(30), why: 'Waiting for your Approve or Reject',
      actions: [{ verb: 'approve', label: 'Approve', kind: 'decision', payload: { msg_id: 'm-appr', approved: true } }] }],
    app_venture: { slug: 'donna', name: 'Donna HVAC', metric: 'booked jobs', budget_cents: 5000, goals: [], memory: [], tasks: [] },
    app_venture_extras: {}, app_push_public_key: null, app_save_push: null, app_send: 'stub-id',
  };
}

// Deep-copy `obj` appending an XSS payload to every renderable string (keys in `preserve` keep their value: the app branches on them).
export function injectPayload(obj, payloads, preserve = []) {
  const keep = new Set(preserve); const list = [].concat(payloads); let n = 0;
  const walk = (v, key) => {
    if (typeof v === 'string') return keep.has(key) || /^\d{4}-\d\d-\d\d/.test(v) ? v : v + ' ' + list[n++ % list.length];
    if (Array.isArray(v)) return v.map((x) => walk(x, key));
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x, k)]));
    return v;
  };
  return walk(obj, '');
}

const b64u = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
export function fakeSession(ref) {
  const exp = Math.floor(now / 1000) + 3.1e8;
  const jwt = `${b64u({ alg: 'HS256', typ: 'JWT' })}.${b64u({ sub: 'qa-stub-user', role: 'authenticated', exp, aud: 'authenticated' })}.${b64u('stub')}`;
  return { key: `sb-${ref}-auth-token`, value: { access_token: jwt, token_type: 'bearer', expires_in: 3.1e8, expires_at: exp, refresh_token: 'stub', user: { id: 'qa-stub-user', aud: 'authenticated', role: 'authenticated', email: 'qa@example.invalid' } } };
}

// Route handler for requests to the stubbed backend host. `log` receives {kind:'rpc'|'auth', name, method, body}.
export function makeStubHandler({ data, log }) {
  return async (route) => {
    const req = route.request(); const u = new URL(req.url());
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    const m = u.pathname.match(/\/rest\/v1\/rpc\/([\w]+)/);
    if (m) {
      let body = null; try { body = req.postDataJSON(); } catch (e) { /* none */ }
      log({ kind: 'rpc', name: m[1], method: req.method(), body });
      const v = Object.prototype.hasOwnProperty.call(data, m[1]) ? data[m[1]] : null;
      return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(v) });
    }
    log({ kind: 'auth', name: u.pathname, method: req.method() });
    return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: '{}' });
  };
}
