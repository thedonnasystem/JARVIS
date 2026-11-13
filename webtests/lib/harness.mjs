// Browser-less harness for the HQ PWA: loads the real webapp/index.html + app.js into jsdom with a stubbed supabase client.
// Nothing here talks to the network or to Supabase; every database call is answered by the test's own handler.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { JSDOM } from 'jsdom';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const WEBAPP = path.join(ROOT, 'webapp');
export const read = (rel) => readFileSync(path.join(ROOT, rel), 'utf8');

// Let promise chains AND the app's (zero-delay) timers drain; real timers as well as setImmediate so a loaded CI machine cannot reorder them.
export const tick = async (n = 12) => { for (let i = 0; i < n; i++) { await new Promise((r) => setTimeout(r, 3)); await new Promise((r) => setImmediate(r)); } };

export const NOW = Date.now();
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();

export function snapshot(over = {}) {
  return {
    state: { kill_switch: false, pause_reason: null, mode: 'dry_run', last_heartbeat: iso(2), cap_cents: 330 },
    capital: { available_cents: 12345, mode: 'normal', fund_cents: 20000, revenue_cents: 0, ai_spend_cents: 100, expense_cents: 0, reserved_cents: 0,
      recurring_monthly_cents: 0, week_spend_cents: 50, weekly_limit_cents: 5000, per_transaction_limit_cents: 2000, min_reserve_cents: 1000 },
    spend_today_cents: 42,
    needs_you: [
      { id: 'm-appr', kind: 'proposal', body: 'Spend $5 on ads\nlonger text', options: null, needs_decision: true, created_at: iso(30) },
      { id: 'm-q', kind: 'proposal', body: 'Which city first?', options: ['Ottawa', 'Toronto'], needs_decision: false, created_at: iso(90) },
    ],
    ventures: [{ slug: 'donna', name: 'Donna HVAC', status: 'active', agents: 3, leads: 4, in_cents: 0, out_cents: 0, expected_cents: 5000, ai_cents_7d: 120 }],
    venture_stage: { donna: 'prospecting' },
    tasks: { todo: 2, doing: 1, blocked: 1, done_24h: 5 }, leads: { total: 4, due: 1 },
    due_leads: [{ sid: 7, name: 'Jane Doe', phone: '613-555-0101', notes: 'call back', due: '2026-11-13' }],
    drafts: [{ id: 'd1', to: 'a@b.ca', body: 'Hello there', agent: 'donna-division', status: 'draft', created_at: iso(10) }],
    dayjob: { today: { dials: 10, pitches: 1, submissions: 0, paid_deals: 0 }, targets: { dials_per_day: 250, pitches_per_day: 6, submissions_per_day: 1 }, week: 'Week: 40 dials' },
    missions: [
      { id: 'mis-blocked', title: 'Mission: Cold email test', status: 'blocked', verdict: 'GO', budget_cents: 200, spent_cents: 50, objective: 'Test cold email', next_action: 'Blocked: step failed', updated_at: iso(300) },
      { id: 'mis-run', title: 'Mission: Map leads', status: 'executing', verdict: 'GO', budget_cents: 200, spent_cents: 20, objective: 'Map', updated_at: iso(20) },
    ],
    ideas: [{ id: 'i1', name: 'Garage cleanouts', status: 'new', score: 7, cost_cents: 5000, kill_metric: '0 calls' }],
    agents: [{ slug: 'jarvis', title: 'Jarvis', role: 'ceo', status: 'active', tier: 'smart', venture: null, spent_today: 10, cap_cents: 100, open: 1, done_7d: 4, last_task: 'Plan day' }],
    scorecard: { jarvis: { flag: 'ok' } }, org_changes: [{ kind: 'agent', status: 'proposed', change: 'Hire a closer agent', gain: 'more calls', cost: '$3/mo' }],
    feed: [{ at: iso(5), type: 'task', who: 'jarvis', text: 'Planned the day', status: 'done' }],
    spend_7d: [{ d: '2026-11-12', c: 77 }], policy: [{ action: 'send_email', tier: 'red' }], systems: [{ name: 'Render', status: 'ok' }],
    pnl: null, bank_alerts: [],
    ...over,
  };
}
export const office = () => [{ fn: 'executive', name: 'Executive Office', staffed: true, agents: [{ slug: 'jarvis', title: 'Jarvis', status: 'active', spent_today: 10, cap: 100 }], open: 1, blocked: 0, done_7d: 4, spent_7d: 90, headline: '2 live missions' }];
export const serverInbox = () => [
  { rank: 1, kind: 'approval', ref_table: 'owner_messages', ref_id: 'm-appr', title: 'Spend $5 on ads', created_at: iso(30), age_minutes: 30, why: 'Waiting for your Approve or Reject', score: 80, expires_at: null, action: 'approve_or_reject',
    actions: [{ verb: 'approve', label: 'Approve', kind: 'decision', payload: { msg_id: 'm-appr', approved: true } }, { verb: 'reject', label: 'Reject', kind: 'decision', payload: { msg_id: 'm-appr', approved: false } }], command: null },
  { rank: 2, kind: 'question', ref_table: 'owner_messages', ref_id: 'm-q', title: 'Which city first?', created_at: iso(90), age_minutes: 90, why: 'A task is paused until you pick an option', score: 65, action: 'answer',
    actions: [{ verb: 'answer', label: 'Ottawa', kind: 'answer', payload: { msg_id: 'm-q', idx: 0 } }, { verb: 'answer', label: 'Toronto', kind: 'answer', payload: { msg_id: 'm-q', idx: 1 } }], command: null },
  { rank: 3, kind: 'mission', ref_table: 'missions', ref_id: 'mis-blocked', title: 'Cold email test', created_at: iso(300), age_minutes: 300, why: 'Blocked: step failed', score: 60, action: 'resume_or_abandon',
    actions: [{ verb: 'resume', label: 'Resume', kind: 'mission', payload: { verb: 'resume', id: 'mis-blocked' } }, { verb: 'abandon', label: 'Abandon', kind: 'mission', confirm: true, payload: { verb: 'abandon', id: 'mis-blocked' } }], command: '/mission retry mis-bloc' },
  { rank: 4, kind: 'payment', ref_table: 'payment_instructions', ref_id: 'p1', title: '$15.00 to Twilio', created_at: iso(600), age_minutes: 600, why: 'Approved: pay it in RBC yourself', score: 75, action: 'pay', actions: [], command: '/pay done p1 <amount> <reference>' },
];

/** opts.rpc(name,args) -> data (or throw) ; opts.session ; returns {win, doc, calls, $ , click, text, stop} */
export async function boot(opts = {}) {
  const calls = []; const state = { signedOut: false };
  const handler = { rpc: opts.rpc };
  const client = {
    auth: {
      getSession: async () => ({ data: { session: opts.session === undefined ? { user: { email: 'owner@example.com' } } : opts.session } }),
      signOut: async () => { state.signedOut = true; },
      signInWithOtp: async () => ({ error: null }), verifyOtp: async () => ({ error: null }),
    },
    rpc: async (name, args) => {
      calls.push({ name, args: JSON.parse(JSON.stringify(args || {})) });   // plain objects: jsdom objects have another realm's prototypes
      try { return { data: await handler.rpc(name, args || {}), error: null }; } catch (e) { return { data: null, error: { message: String(e.message || e) } }; }
    },
  };
  const dom = new JSDOM(read('webapp/index.html'), {
    url: 'https://fendezy-hq-app.onrender.com/', runScripts: 'dangerously', pretendToBeVisual: true,
    beforeParse(w) {
      w.supabase = { createClient: () => client };
      w.matchMedia = () => ({ matches: false });
      w.confirm = (...a) => { (opts.confirms = opts.confirms || []).push(a[0]); return opts.confirmAnswer !== false; };
      const realTO = w.setTimeout.bind(w);
      w.setTimeout = (fn, ms, ...a) => realTO(fn, 0, ...a);   // the app waits seconds between polls; the test must not
      w.setInterval = () => 0;                                  // no background refresh loop: tests trigger refresh themselves
    },
  });
  const w = dom.window; const doc = w.document;
  const el = doc.createElement('script'); el.textContent = read('webapp/app.js'); doc.body.appendChild(el);
  await tick();
  const api = {
    win: w, doc, calls, handler, state,
    $: (sel) => doc.querySelector(sel), all: (sel) => [...doc.querySelectorAll(sel)],
    text: (sel) => (doc.querySelector(sel)?.textContent || ''),
    button: (sel, label) => [...doc.querySelectorAll(sel + ' button')].find((b) => b.textContent.trim() === label),
    click: async (node) => { node.dispatchEvent(new w.Event('click', { bubbles: true })); await tick(); },
    tab: async (k) => { await api.click(doc.getElementById('t-' + k)); },
    refresh: async () => { doc.dispatchEvent(new w.Event('visibilitychange')); await tick(); },
    callsTo: (name) => calls.filter((c) => c.name === name),
    stop: () => w.close(),
  };
  return api;
}

/** A well-behaved fake backend for the stubbed client. */
export function backend(over = {}) {
  const sent = [];
  const fn = (name, args) => {
    if (over[name] !== undefined) { const v = over[name]; return typeof v === 'function' ? v(args) : v; }
    switch (name) {
      case 'app_snapshot': return snapshot();
      case 'app_messages': return sent.map((s) => ({ id: 'r-' + s.id, role: 'jarvis', kind: 'system', reply_to: s.id, body: 'Saved: ' + s.kind }));
      case 'app_office': return office();
      case 'app_payments': return [];
      case 'app_needs_you': return serverInbox();
      case 'app_send': { const id = 'sent-' + (sent.length + 1); sent.push({ id, kind: args.p_kind }); return id; }
      case 'app_venture': case 'app_venture_extras': return {};
      default: return null;
    }
  };
  fn.sent = sent;
  return fn;
}
