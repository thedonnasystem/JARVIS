'use strict';
// FENDEZY GROUP HQ: SYNTHETIC DEMO DATASET. Nothing in this file is real: not a number, not a name, not a client.
// It exists so the HQ screens can be opened and clicked through with no login and no backend (?demo=1), and so the UI has ONE data module to read.
// hq.js reads it only through HQ.model(); to go live later, replace the parts of that adapter that say "SIMULATED" with database reads.
//
// SCHEMA (field names follow the live app_snapshot / app_office shapes wherever one exists, so the swap is mechanical):
//   meta        { synthetic:true, schema:'hq-demo-1', group, note }
//   jarvis      { state:{mode,kill_switch,pause_reason,cap_cents,last_heartbeat_min}, pending_approvals:[{id,title,why,age_min,division_id}], policy:[{action,tier}], gateway:{...} }
//   offices     [{ fn, name, defined_in:'repo'|'inferred', head, headline, agents, open, blocked, done_7d, spent_7d_cents, charter }]
//   divisions   [{ id, name, charter, lifecycle:'active'|'incubating'|'planned', health:'green'|'amber'|'red'|'grey', manager_id, team_ids[], origin,
//                  budget:{monthly_cents, spent_cents}, money:{in_cents,out_cents,expected_cents}, kpis:[{name,value,target,unit}], risks[], mission_ids[] }]
//   managers    [{ id, title, division_id|office_fn, charter, authority, tier, status, reports_to, scorecard:{flag,done_7d,cents_per_done}, last_report }]
//   teams       [{ id, name, division_id, purpose, agent_ids[] }]
//   agents      [{ slug, title, role, status, tier, venture, team_id, cap_cents, spent_today, done_7d, open, last_task }]
//   missions    [{ id, title, status, verdict, division_id, budget_cents, spent_cents, expected_cad, objective, success, risks, next_action, gate, updated_min, steps:[{title,status,agent}] }]
//   feed        [{ min_ago, type, who, text, status, division_id }]
//   finance     { capital:{...as app_snapshot.capital}, spend_today_cents, spend_7d:[{d,c}], by_division:[{division_id,ai_cents_7d,in_cents,out_cents}], ledger:{...} }
//   health      { checks:[{name,status,checked_min,detail}], deployments:[{name,env,status,ref,age_min}], backups:{...}, consent_gate:{...} }
// Teams, managers, divisions, budgets and KPIs are an INFERRED proposal (the repo defines no division table): see HQ_WALKTHROUGH.md.
(function (root) {
  const D = {};
  D.meta = { synthetic: true, schema: 'hq-demo-1', group: 'FENDEZY GROUP', note: 'Synthetic demo data. Not connected to any database. No real clients, people or money.' };

  D.jarvis = {
    state: { mode: 'dry_run', kill_switch: false, pause_reason: null, cap_cents: 330, last_heartbeat_min: 2 },
    pending_approvals: [
      { id: 'a1', title: 'Approve $5.00 test ad spend for Client A pilot (demo)', why: 'Spend above the per-action green limit', age_min: 34, division_id: 'ffm' },
      { id: 'a2', title: 'Sign-off: open owner screens for FF Marketing budgets (demo)', why: 'Protected control change', age_min: 190, division_id: 'eng' },
      { id: 'a3', title: 'Which Ontario city should the wholesale test target first? (demo)', why: 'A task is paused until you pick an option', age_min: 420, division_id: 'wholesale' },
    ],
    policy: [
      { action: 'research / read-only web', tier: 'green' }, { action: 'draft outreach (never sent)', tier: 'yellow' },
      { action: 'send email / message to a person', tier: 'red' }, { action: 'spend money', tier: 'red' }, { action: 'change limits, kill switch, permissions', tier: 'prohibited' },
    ],
    gateway: { note: 'Every model call reserves budget first; the company cap and each agent cap are checked; the kill switch is checked in the engine, the gateway and the outbox.', reserve_floor_cents: 1000 },
  };

  // The nine corporate-office functions come from the repo (migration office_v1 / app_office). Legal, Security & Risk are INFERRED (docs exist, no office row).
  D.offices = [
    { fn: 'executive', name: 'Executive Office', defined_in: 'repo', head: 'jarvis', headline: '3 live missions, 1 open escalation', agents: 2, open: 4, blocked: 0, done_7d: 11, spent_7d_cents: 92, charter: 'Jarvis (COO). Plans the day, runs missions, is the only agent that may contact the Chairman.' },
    { fn: 'bizdev', name: 'Business Development', defined_in: 'repo', head: 'bizdev-lead', headline: '5 ideas in the lab, 1 venture awaiting approval', agents: 2, open: 3, blocked: 0, done_7d: 6, spent_7d_cents: 41, charter: 'Finds and scores new ventures so ideas stop dying in chats.' },
    { fn: 'research', name: 'Research & Intelligence', defined_in: 'repo', head: 'research-lead', headline: '14 facts learned this week', agents: 3, open: 5, blocked: 1, done_7d: 17, spent_7d_cents: 63, charter: 'Permanent research. Sources every claim; flags what it could not verify.' },
    { fn: 'engineering', name: 'Engineering & Technology', defined_in: 'repo', head: 'eng-lead', headline: '9 tasks shipped this week', agents: 3, open: 6, blocked: 1, done_7d: 9, spent_7d_cents: 55, charter: 'Builds and maintains HQ and client systems. Cannot deploy to production without release authorization.' },
    { fn: 'marketing', name: 'Marketing & Media', defined_in: 'repo', head: 'mktg-lead', headline: '6 tasks done this week', agents: 2, open: 2, blocked: 0, done_7d: 6, spent_7d_cents: 28, charter: 'Content and campaign drafting. Nothing publishes without approval.' },
    { fn: 'sales', name: 'Sales & Customer Acquisition', defined_in: 'repo', head: 'sales-lead', headline: '12 leads, 3 due for follow-up', agents: 2, open: 3, blocked: 0, done_7d: 5, spent_7d_cents: 19, charter: 'Lead follow-up and pipeline. Drafts only; a person sends.' },
    { fn: 'finance', name: 'Finance & Treasury', defined_in: 'repo', head: 'treasury', headline: 'Cash in $0.00, out $14.20 (30 days, received only)', agents: 1, open: 1, blocked: 0, done_7d: 3, spent_7d_cents: 12, charter: 'Capital controller, ledger, bank reconciliation. The bank balance is the source of truth.' },
    { fn: 'operations', name: 'Operations', defined_in: 'repo', head: 'ops-lead', headline: '2 blocked tasks, 7 tasks waiting', agents: 2, open: 7, blocked: 2, done_7d: 8, spent_7d_cents: 22, charter: 'Keeps the engine ticking: recovery, handoffs, system checks.' },
    { fn: 'agentmgmt', name: 'Agent Management', defined_in: 'repo', head: 'agent-mgr', headline: '24 agents, 3 paused', agents: 1, open: 1, blocked: 0, done_7d: 2, spent_7d_cents: 8, charter: 'Scorecards, hiring and retiring agents (proposals need the Chairman).' },
    { fn: 'legal', name: 'Legal & Compliance', defined_in: 'inferred', head: null, headline: 'Not staffed. Contracts and consent rules are handled by the Chairman.', agents: 0, open: 0, blocked: 0, done_7d: 0, spent_7d_cents: 0, charter: 'PROPOSED. Consent gate, client agreements, privacy rules.' },
    { fn: 'security', name: 'Security & Risk', defined_in: 'inferred', head: null, headline: 'Not staffed. Reviews exist as documents (security reviews).', agents: 0, open: 0, blocked: 0, done_7d: 0, spent_7d_cents: 0, charter: 'PROPOSED. Audit paths, access, spend-gateway integrity, backup proof.' },
  ];

  D.divisions = [
    { id: 'donna', name: 'Donna Systems', charter: 'AI automation agency: lead follow-up and booking systems for local service businesses.', lifecycle: 'active', health: 'amber', manager_id: 'm-donna', team_ids: ['t-donna-build', 't-donna-sales'], origin: 'AAA Adoption (Donna System)',
      budget: { monthly_cents: 4000, spent_cents: 1650 }, money: { in_cents: 0, out_cents: 1650, expected_cents: 25000 },
      kpis: [{ name: 'Qualified conversations / week', value: 4, target: 10, unit: '' }, { name: 'Pilot clients signed', value: 0, target: 1, unit: '' }, { name: 'Cost per booked call', value: 410, target: 300, unit: 'c' }],
      risks: ['No signed pilot yet', 'Outreach is draft-only until the Chairman approves sending'], mission_ids: ['ms-3'] },
    { id: 'ffm', name: 'FF Marketing', charter: 'Reusable marketing-agency OS run per client workspace (leads, ad drafts, reporting). Dry-run only.', lifecycle: 'incubating', health: 'amber', manager_id: 'm-ffm', team_ids: ['t-ffm-ops', 't-ffm-creative'], origin: 'FFM OS (client workspaces)',
      budget: { monthly_cents: 3000, spent_cents: 420 }, money: { in_cents: 0, out_cents: 420, expected_cents: 15000 },
      kpis: [{ name: 'Workspaces ready to activate', value: 1, target: 2, unit: '' }, { name: 'Onboarding items complete', value: 62, target: 100, unit: '%' }, { name: 'Campaigns approved (dry-run)', value: 1, target: 2, unit: '' }],
      risks: ['Consent gate must be on before any client data is stored', 'Client 2 recruiting model not finalised'], mission_ids: ['ms-2'] },
    { id: 'wholesale', name: 'Real Estate Wholesale (Canada)', charter: 'Find motivated-seller and buyer demand in Ontario and Alberta; assign contracts to cash buyers.', lifecycle: 'incubating', health: 'grey', manager_id: 'm-wholesale', team_ids: ['t-ws-research'], origin: 'Canada wholesaling plan',
      budget: { monthly_cents: 2000, spent_cents: 0 }, money: { in_cents: 0, out_cents: 0, expected_cents: 0 },
      kpis: [{ name: 'Provinces researched', value: 2, target: 4, unit: '' }, { name: 'Buyer list size', value: 0, target: 25, unit: '' }],
      risks: ['Legal rules differ by province: not yet reviewed', 'No deal pipeline connected to HQ yet'], mission_ids: [] },
    { id: 'energy', name: 'Energy Sales (Day Job)', charter: 'Supports the Chairman\'s commission sales job: follow-up reminders, daily numbers, lead notes.', lifecycle: 'active', health: 'green', manager_id: 'm-energy', team_ids: ['t-energy'], origin: 'Day-job department',
      budget: { monthly_cents: 500, spent_cents: 120 }, money: { in_cents: 0, out_cents: 120, expected_cents: 0 },
      kpis: [{ name: 'Dials today', value: 112, target: 250, unit: '' }, { name: 'Pitches today', value: 3, target: 6, unit: '' }, { name: 'Follow-ups due', value: 3, target: 0, unit: '' }],
      risks: ['Employer data must never enter HQ'], mission_ids: [] },
    { id: 'content', name: 'Digital Products & Content', charter: 'Automated content and low-cost digital products (renovation reels, coloring books).', lifecycle: 'planned', health: 'grey', manager_id: 'm-content', team_ids: [], origin: 'Venture ideas list',
      budget: { monthly_cents: 1500, spent_cents: 0 }, money: { in_cents: 0, out_cents: 0, expected_cents: 0 },
      kpis: [{ name: 'Pieces published / day', value: 0, target: 4, unit: '' }], risks: ['Not started: waiting for a green light'], mission_ids: [] },
    { id: 'lab', name: 'New Ventures Lab', charter: 'Idea intake, 7-day tests with a kill metric, then park or promote.', lifecycle: 'active', health: 'green', manager_id: 'm-lab', team_ids: ['t-lab'], origin: 'Idea lab (ideas table)',
      budget: { monthly_cents: 1000, spent_cents: 310 }, money: { in_cents: 0, out_cents: 310, expected_cents: 0 },
      kpis: [{ name: 'Ideas in test', value: 2, target: 3, unit: '' }, { name: 'Ideas decided (go/kill)', value: 3, target: 4, unit: '' }], risks: [], mission_ids: ['ms-4'] },
    { id: 'research', name: 'Research & Intelligence Division', charter: 'Standing research for every division; verifies facts before they enter memory.', lifecycle: 'active', health: 'green', manager_id: 'm-research', team_ids: ['t-research'], origin: 'Research department',
      budget: { monthly_cents: 1200, spent_cents: 560 }, money: { in_cents: 0, out_cents: 560, expected_cents: 0 },
      kpis: [{ name: 'Facts verified / week', value: 14, target: 15, unit: '' }, { name: 'Unsourced claims', value: 0, target: 0, unit: '' }], risks: [], mission_ids: [] },
    { id: 'eng', name: 'Engineering & Platform', charter: 'Builds HQ itself and the client systems. Release gates stay with the Chairman.', lifecycle: 'active', health: 'amber', manager_id: 'm-eng', team_ids: ['t-eng-core', 't-eng-qa'], origin: 'Engineering department',
      budget: { monthly_cents: 2500, spent_cents: 1180 }, money: { in_cents: 0, out_cents: 1180, expected_cents: 0 },
      kpis: [{ name: 'PRs awaiting review', value: 3, target: 0, unit: '' }, { name: 'CI green on main branch', value: 1, target: 1, unit: '' }, { name: 'Open defects', value: 4, target: 0, unit: '' }],
      risks: ['Production releases need release authorization', 'Backup restore proof not yet captured'], mission_ids: ['ms-1'] },
  ];

  const mg = (id, title, div, authority, tier, status, flag, done, cpd, report, charter, reports) => ({ id, title, division_id: div, authority, tier, status, reports_to: reports || 'jarvis', scorecard: { flag, done_7d: done, cents_per_done: cpd }, last_report: report, charter });
  D.managers = [
    mg('m-donna', 'Donna Division Manager', 'donna', 'Draft and plan. Cannot send or spend without approval.', 'smart', 'active', 'ok', 5, 18, 'Drafted 3 follow-up sequences; waiting on Chairman approval to test one.', 'Run the Donna System pilot: find one local service business, prove booked calls.'),
    mg('m-ffm', 'FF Marketing Manager', 'ffm', 'Onboarding, drafts, dry-run campaigns. No ad platform calls.', 'smart', 'active', 'ok', 4, 21, 'Client A onboarding checklist 62% complete; blocked on consent gate.', 'Operate client workspaces with strict per-client isolation.'),
    mg('m-wholesale', 'Wholesale Division Manager', 'wholesale', 'Research only.', 'cheap', 'paused', 'idle', 0, null, 'Paused until Chairman picks the first province.', 'Build the buyer-first wholesale funnel for Ontario and Alberta.'),
    mg('m-energy', 'Energy Sales Manager', 'energy', 'Reminders and logging only.', 'cheap', 'active', 'ok', 6, 6, 'Logged 112 dials; 3 follow-ups due this afternoon.', 'Keep the day job tight and measured.'),
    mg('m-content', 'Content Division Manager', 'content', 'None yet.', 'cheap', 'paused', 'idle', 0, null, 'Not started.', 'Run automated content products when approved.'),
    mg('m-lab', 'New Ventures Lead', 'lab', 'Run tests within the idea budget.', 'smart', 'active', 'ok', 3, 24, 'Two ideas in 7-day test; one parked.', 'Test ideas fast, kill on the metric.'),
    mg('m-research', 'Research Lead', 'research', 'Read-only research.', 'smart', 'active', 'ok', 14, 4, '14 facts verified; 1 task blocked on a source.', 'Verify before remembering.'),
    mg('m-eng', 'Engineering Lead', 'eng', 'Build on dev branches, open PRs. No production deploys.', 'smart', 'active', 'review', 9, 6, 'HQ experience prototype built; 3 PRs awaiting review.', 'Ship safely: tests, evidence, rollback.'),
  ];

  D.teams = [
    { id: 't-donna-build', name: 'Donna Build', division_id: 'donna', purpose: 'Booking and follow-up workflows', agent_ids: ['donna-builder', 'donna-qa'] },
    { id: 't-donna-sales', name: 'Donna Outreach', division_id: 'donna', purpose: 'Prospect research and draft sequences', agent_ids: ['donna-researcher', 'donna-division'] },
    { id: 't-ffm-ops', name: 'Client Onboarding', division_id: 'ffm', purpose: 'Checklists, consent, readiness', agent_ids: ['ffm-onboarder'] },
    { id: 't-ffm-creative', name: 'Creative Drafts', division_id: 'ffm', purpose: 'Plain-text ad sets and creatives (dry-run)', agent_ids: ['ffm-creative'] },
    { id: 't-ws-research', name: 'Province Research', division_id: 'wholesale', purpose: 'Rules, buyers, comps', agent_ids: ['ws-researcher'] },
    { id: 't-energy', name: 'Day-Job Support', division_id: 'energy', purpose: 'Follow-ups and daily numbers', agent_ids: ['energy-assist'] },
    { id: 't-lab', name: 'Idea Testing', division_id: 'lab', purpose: 'Scoring and 7-day tests', agent_ids: ['lab-scorer', 'lab-tester'] },
    { id: 't-research', name: 'Verification Desk', division_id: 'research', purpose: 'Source checks and fact memory', agent_ids: ['res-verifier', 'res-scout'] },
    { id: 't-eng-core', name: 'Core Platform', division_id: 'eng', purpose: 'HQ app, engine, database functions', agent_ids: ['eng-builder', 'eng-pwa'] },
    { id: 't-eng-qa', name: 'QA and Evidence', division_id: 'eng', purpose: 'Tests, drift checks, release evidence', agent_ids: ['eng-qa'] },
  ];

  const ag = (slug, title, role, status, team, cap, spent, done, open, last, tier) => ({ slug, title, role, status, tier: tier || 'cheap', venture: null, team_id: team, cap_cents: cap, spent_today: spent, done_7d: done, open, last_task: last });
  D.agents = [
    ag('jarvis', 'Jarvis', 'coo', 'active', null, 100, 31, 11, 4, 'Plan the day and rank the inbox', 'smart'),
    ag('donna-builder', 'Donna Builder', 'builder', 'active', 't-donna-build', 20, 6, 3, 1, 'Wire booking reminder flow (dry-run)'),
    ag('donna-qa', 'Donna QA', 'qa', 'active', 't-donna-build', 10, 2, 2, 0, 'Check reminder wording for banned claims'),
    ag('donna-researcher', 'Donna Researcher', 'researcher', 'active', 't-donna-sales', 15, 5, 4, 2, 'List HVAC companies in a demo city'),
    ag('donna-division', 'Donna Outreach Drafter', 'division', 'active', 't-donna-sales', 15, 3, 3, 1, 'Draft outreach (never sent)'),
    ag('ffm-onboarder', 'FFM Onboarder', 'ops', 'active', 't-ffm-ops', 12, 2, 4, 1, 'Instantiate onboarding checklist for Client A'),
    ag('ffm-creative', 'FFM Creative', 'creative', 'paused', 't-ffm-creative', 12, 0, 0, 0, 'Waiting on consent gate'),
    ag('ws-researcher', 'Wholesale Researcher', 'researcher', 'paused', 't-ws-research', 10, 0, 0, 0, 'Paused'),
    ag('energy-assist', 'Day-Job Assistant', 'assistant', 'active', 't-energy', 8, 1, 6, 3, 'Prepare follow-up list for 3pm'),
    ag('lab-scorer', 'Idea Scorer', 'analyst', 'active', 't-lab', 8, 2, 2, 1, 'Score idea: garage cleanouts'),
    ag('lab-tester', 'Idea Tester', 'tester', 'active', 't-lab', 10, 3, 1, 1, 'Run 7-day test plan'),
    ag('res-verifier', 'Fact Verifier', 'researcher', 'active', 't-research', 12, 4, 9, 2, 'Verify a funding claim against two sources', 'smart'),
    ag('res-scout', 'Research Scout', 'researcher', 'active', 't-research', 10, 3, 5, 3, 'Scan provincial rules (demo)'),
    ag('eng-builder', 'Platform Builder', 'engineer', 'active', 't-eng-core', 25, 9, 5, 3, 'Add org screens to the PWA', 'smart'),
    ag('eng-pwa', 'PWA Specialist', 'engineer', 'active', 't-eng-core', 15, 4, 2, 2, 'Service worker cache review'),
    ag('eng-qa', 'QA Engineer', 'qa', 'active', 't-eng-qa', 15, 5, 4, 1, 'Run drift check and web tests'),
  ];

  D.missions = [
    { id: 'ms-1', title: 'Build the FENDEZY HQ experience', status: 'executing', verdict: 'GO', division_id: 'eng', budget_cents: 600, spent_cents: 240, expected_cad: null, objective: 'A clickable headquarters inside the existing PWA, with honest simulated/live badges.', success: 'Chairman can open every screen and tell real from simulated.', risks: 'Could be mistaken for live numbers if badges are removed.', next_action: 'Review screenshots and walkthrough', gate: null, updated_min: 12,
      steps: [{ title: 'Inspect the PWA', status: 'done', agent: 'eng-builder' }, { title: 'Build demo dataset', status: 'done', agent: 'eng-builder' }, { title: 'Write web tests', status: 'doing', agent: 'eng-qa' }, { title: 'Chairman review', status: 'todo', agent: null }] },
    { id: 'ms-2', title: 'Onboard FF Marketing Client A (mortgage, synthetic)', status: 'blocked', verdict: 'GO', division_id: 'ffm', budget_cents: 300, spent_cents: 90, expected_cad: 150, objective: 'Get the first client workspace to ready-to-activate in dry-run.', success: 'All required onboarding items hold real values and the Chairman has approved.', risks: 'Sensitive financial data must never enter the workspace.', next_action: 'Blocked: consent gate not enabled', gate: 'Owner approval + consent gate', updated_min: 300,
      steps: [{ title: 'Create workspace', status: 'done', agent: 'ffm-onboarder' }, { title: 'Collect onboarding items', status: 'doing', agent: 'ffm-onboarder' }, { title: 'Draft first campaign (dry-run)', status: 'blocked', agent: 'ffm-creative' }, { title: 'Activation approval', status: 'todo', agent: null }] },
    { id: 'ms-3', title: 'Donna pilot: first booked call', status: 'executing', verdict: 'GO', division_id: 'donna', budget_cents: 400, spent_cents: 165, expected_cad: 250, days_to_cash: 30, objective: 'Prove the follow-up system books one call for a local service business.', success: 'One booked call from a real prospect with consent.', risks: 'Outreach is draft-only; the Chairman sends.', next_action: 'Chairman approves one draft', gate: 'Chairman sends manually', updated_min: 45,
      steps: [{ title: 'Research prospects', status: 'done', agent: 'donna-researcher' }, { title: 'Draft sequence', status: 'done', agent: 'donna-division' }, { title: 'Approve + send', status: 'todo', agent: null }] },
    { id: 'ms-4', title: 'Test idea: garage cleanouts (7 days)', status: 'planning', verdict: 'GO', division_id: 'lab', budget_cents: 200, spent_cents: 20, expected_cad: 80, objective: 'See if cheap local demand exists.', success: '3 enquiries in 7 days.', risks: 'Kill if 0 calls.', next_action: 'Awaiting start', gate: null, updated_min: 600, steps: [{ title: 'Landing draft', status: 'todo', agent: 'lab-tester' }] },
    { id: 'ms-5', title: 'Province buyer research (Ontario)', status: 'completed', verdict: 'GO', division_id: 'research', budget_cents: 150, spent_cents: 120, expected_cad: null, objective: 'Summarise wholesale assignment rules.', success: 'Sourced summary in memory.', risks: '', next_action: 'Done', gate: null, updated_min: 2900, steps: [{ title: 'Research', status: 'done', agent: 'res-scout' }, { title: 'Verify', status: 'done', agent: 'res-verifier' }] },
  ];

  D.feed = [
    { min_ago: 2, type: 'audit', who: 'engine', text: 'heartbeat ok, tick completed', status: 'log', division_id: null },
    { min_ago: 9, type: 'task', who: 'eng-qa', text: 'Ran drift check and web tests: all green (demo)', status: 'done', division_id: 'eng' },
    { min_ago: 18, type: 'message', who: 'jarvis', text: 'Plan for today: 3 approvals waiting, 1 blocked mission.', status: 'brief', division_id: null },
    { min_ago: 34, type: 'message', who: 'ffm-onboarder', text: 'Spend $5.00 test ads for Client A pilot? Waiting for you.', status: 'proposal', division_id: 'ffm' },
    { min_ago: 61, type: 'task', who: 'donna-division', text: 'Draft outreach (never sent): 3 sequences ready', status: 'done', division_id: 'donna' },
    { min_ago: 120, type: 'task', who: 'ffm-creative', text: 'Waiting on consent gate', status: 'blocked', division_id: 'ffm' },
    { min_ago: 240, type: 'audit', who: 'treasury', text: 'reconcile: ledger matches last recorded bank balance', status: 'log', division_id: null },
    { min_ago: 410, type: 'task', who: 'res-verifier', text: 'Verified 4 facts for the wholesale brief', status: 'done', division_id: 'research' },
    { min_ago: 900, type: 'audit', who: 'agent-mgr', text: 'scorecard: wholesale researcher idle', status: 'log', division_id: 'wholesale' },
  ];

  D.finance = {
    capital: { available_cents: 18420, mode: 'normal', fund_cents: 20000, revenue_cents: 0, ai_spend_cents: 1420, expense_cents: 0, reserved_cents: 160, recurring_monthly_cents: 0,
      week_spend_cents: 640, weekly_limit_cents: 5000, per_transaction_limit_cents: 2000, min_reserve_cents: 1000, bank_balance_cents: 18500, bank_age_days: 2, ledger_available_cents: 18420 },
    spend_today_cents: 188,
    spend_7d: [{ d: '6 days ago', c: 140 }, { d: '5 days ago', c: 211 }, { d: '4 days ago', c: 96 }, { d: '3 days ago', c: 305 }, { d: '2 days ago', c: 250 }, { d: 'yesterday', c: 190 }, { d: 'today', c: 188 }],
    by_division: [{ division_id: 'eng', ai_cents_7d: 520, in_cents: 0, out_cents: 0 }, { division_id: 'donna', ai_cents_7d: 310, in_cents: 0, out_cents: 0 }, { division_id: 'research', ai_cents_7d: 260, in_cents: 0, out_cents: 0 },
      { division_id: 'ffm', ai_cents_7d: 150, in_cents: 0, out_cents: 0 }, { division_id: 'lab', ai_cents_7d: 110, in_cents: 0, out_cents: 0 }, { division_id: 'energy', ai_cents_7d: 50, in_cents: 0, out_cents: 0 }],
    ledger: { cash_in_30d_cents: 0, cash_out_30d_cents: 1420, expected_not_cash_cents: 40000, rows_30d: 37, note: 'Ledger counts received money only. Expected revenue is never cash.' },
  };

  D.health = {
    checks: [
      { name: 'Engine heartbeat', status: 'ok', checked_min: 2, detail: 'Ticks every 5 minutes' },
      { name: 'Database', status: 'ok', checked_min: 4, detail: 'Reachable' },
      { name: 'Telegram bot', status: 'ok', checked_min: 6, detail: 'Delivering' },
      { name: 'Web app (this PWA)', status: 'ok', checked_min: 6, detail: 'Static site up' },
      { name: 'Wholesale deal pipeline', status: 'dormant', checked_min: 600, detail: 'Bridge key not set (by design)' },
      { name: 'Backups', status: 'warn', checked_min: 1400, detail: 'No restore proof recorded yet' },
    ],
    deployments: [{ name: 'Bot (Railway)', env: 'production', status: 'live', ref: 'overnight-build', age_min: 5200 }, { name: 'Web app (Render static)', env: 'production', status: 'live', ref: 'overnight-build', age_min: 5200 }, { name: 'build/hq-experience', env: 'none (draft PR)', status: 'not deployed', ref: 'dev branch', age_min: 30 }],
    backups: { last_run_min: 1400, status: 'configured, unproven', restore_proof: 'not captured', note: 'Backup activation and restore proof are owner-gated steps.' },
    consent_gate: { state: 'off', detail: 'Client data intake stays disabled until the Chairman turns the consent gate on. Display only.' },
  };

  root.HQ_DEMO = D;
})(typeof window !== 'undefined' ? window : globalThis);
