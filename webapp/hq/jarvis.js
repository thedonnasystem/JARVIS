'use strict';
// FENDEZY HQ: OFFLINE JARVIS PLANNER + SIMULATED MISSION STORE (window.HQJarvis).
// Deterministic and rule-based: keyword routing to divisions and offices, task templates per objective type. Zero AI cost, no network,
// no LLM. It never runs an agent, never researches, never contacts anyone and never marks a task done on its own: every status change
// below is a function the Chairman triggers by hand, and every change is appended to the activity history.
// AI cost figures are PLANNING ASSUMPTIONS per task type (see COST), not measurements, and are always shown as estimates.
(function (root) {
  const SIM_NOTE = 'SIMULATED. Planned by the offline planner. No agent has run. No research was performed.';
  const CAP_CENTS = 330;
  const UNASSIGNED = "Unassigned — awaiting Chairman's appointment.";

  // ---------- routing rules (regex fragments matched on word boundaries; a phrase with a space counts double) ----------
  const DIV_RULES = {
    'b2b-records': ['music', 'songs?', 'albums?', 'artists?', 'record label', 'labels?', 'beats?', 'tracks?', 'studio', 'rappers?', 'producers?', 'mixtapes?', 'singles?', 'streaming', 'royalt\\w*', 'music release', 'artist development'],
    donna: ['ai agency', 'automat\\w*', 'workflows?', 'chatbots?', 'crm', 'business process\\w*', 'ai receptionists?', 'agency', 'integrations?', 'voice agents?', 'process systems?'],
    'the-trap': ['e-?commerce', 'shopify', 'online store', 'stores?', 'products?', 'dropship\\w*', 'merch\\w*', 'inventory', 'etsy', 'prototypes?', 'packaging', 'manufactur\\w*', 'suppliers?', 'product development'],
    'wolf-squad': ['prospect\\w*', 'leads?', 'sales', 'sell\\w*', 'cold call\\w*', 'outreach', 'pipeline', 'close deals?', 'quota', 'appointments?', 'revenue', 'door to door', 'booked calls?'],
    'pimp-ai': ['ai models?', 'ai influencers?', 'virtual influencers?', 'virtual models?', 'ai personas?', 'avatars?', 'content monetization', 'monetiz\\w*', 'subscribers?', 'creators?'],
    monopoly: ['real estate', 'property', 'properties', 'houses?', 'homes?', 'land', 'wholesal\\w*', 'acquisitions?', 'acquire', 'rentals?', 'landlords?', 'probate', 'flip\\w*', 'duplex\\w*', 'condos?', 'buildings?'],
    'ff-marketing': ['ads?', 'advertis\\w*', 'campaigns?', 'marketing', 'social media', 'tiktok', 'instagram', 'youtube', 'followers?', 'audience', 'brand awareness', 'seo', 'newsletters?', 'content', 'posts?', 'reels?'],
    'fruition-factory': ['research', 'new venture', 'new business', 'launch\\w*', 'ideas?', 'validat\\w*', 'innovation', 'feasibility', 'market', 'business plan', 'proposals?', 'explore', 'opportunit\\w*', 'experiments?'],
  };
  const OFFICE_RULES = {
    'business-development': ['partnerships?', 'launch\\w*', 'proposals?', 'expan\\w*', 'new markets?', 'deals?', 'opportunit\\w*', 'business plan', 'joint venture', 'new business', 'new venture'],
    'marketing-growth': ['releases?', 'marketing', 'campaigns?', 'ads?', 'advertis\\w*', 'audience', 'brand\\w*', 'social media', 'content', 'followers?', 'growth'],
    'sales-revenue': ['sales', 'sell\\w*', 'revenue', 'leads?', 'prospect\\w*', 'customers?', 'clients?', 'outreach', 'pricing', 'close deals?'],
    'operations-automation': ['automat\\w*', 'process\\w*', 'workflows?', 'operations?', 'sops?', 'logistics', 'fulfil\\w*', 'inventory', 'suppliers?'],
    'finance-capital': ['budgets?', 'costs?', 'pricing', 'prices?', 'funding', 'capital', 'cash', 'profit\\w*', 'financ\\w*', 'invest\\w*', 'tax\\w*', 'spend\\w*', 'roi', 'acquisitions?', 'acquire'],
    'legal-risk-compliance': ['legal', 'contracts?', 'licen[cs]\\w*', 'permits?', 'complian\\w*', 'regulat\\w*', 'terms', 'privacy', 'insurance', 'incorporat\\w*', 'risks?'],
    'intelligence-research': ['research', 'market', 'competitors?', 'analy[sz]\\w*', 'study', 'survey\\w*', 'data', 'trends?', 'feasibility', 'investigat\\w*'],
    'technology-security': ['websites?', 'apps?', 'software', 'security', 'tech\\w*', 'integrations?', 'hosting', 'domains?', 'build (a|an|the)? ?(site|app|tool|system)', 'chatbots?'],
  };

  // ---------- task templates per objective type ----------
  // kind: internal (planning/drafting only) | spend (money beyond AI) | external (contact/publish) | production (live systems)
  // COST: planning assumption of AI cents per task, by task size. NOT measured. Gated (non-internal) tasks are human actions: 0.
  const COST = { s: 5, m: 20, l: 40 };
  const INTENTS = [
    { id: 'research', label: 'research', re: /\b(research\w*|investigat\w*|stud(y|ies)|analy[sz]\w*|competitors?|feasibility|market|trends?|survey\w*)\b/,
      tasks: [['Desk research from public sources', 'intelligence-research', 'internal', 'l', 'Research agent'], ['Summarize findings with a source for every claim', 'intelligence-research', 'internal', 'm', 'Analyst agent']],
      deliverables: ['Research summary with sources'] },
    { id: 'plan', label: 'proposal / plan', re: /\b(proposals?|business plan|plans?|strateg\w*|launch\w*|pitch deck|roadmap)\b/,
      tasks: [['Draft the proposal or plan document', 'business-development', 'internal', 'm', 'Planning agent'], ['Rough cost and revenue outline (no spending)', 'finance-capital', 'internal', 'm', 'Finance analyst agent']],
      deliverables: ['Proposal / plan document', 'Cost and revenue outline'] },
    { id: 'outreach', label: 'sales outreach', re: /\b(prospect\w*|leads?|outreach|cold|sales|sell\w*|contact\w*|call\w*|emails?|appointments?|close deals?)\b/,
      tasks: [['Build a prospect list from public sources', 'sales-revenue', 'internal', 'l', 'Prospecting agent'], ['Draft outreach messages for Chairman review', 'sales-revenue', 'internal', 'm', 'Sales writer agent'], ['Contact prospects (send, call or message)', 'sales-revenue', 'external', null, UNASSIGNED]],
      deliverables: ['Prospect list (public sources)', 'Outreach drafts'] },
    { id: 'marketing', label: 'marketing campaign', re: /\b(ads?|advertis\w*|campaigns?|marketing|social media|tiktok|instagram|youtube|content|audience|followers?|subscribers?|posts?|reels?|brands?|influencers?)\b/,
      tasks: [['Draft campaign plan and creative briefs', 'marketing-growth', 'internal', 'm', 'Marketing agent'], ['Publish content or run paid ads', 'marketing-growth', 'external', null, UNASSIGNED]],
      deliverables: ['Campaign plan and creative briefs'] },
    { id: 'build', label: 'build / automation', re: /\b(automat\w*|build (a|an|the|our)? ?(website|site|app|tool|system|bot|dashboard)s?|websites?|apps?|software|workflows?|integrations?|chatbots?|receptionists?)\b/,
      tasks: [['Write a short technical spec', 'technology-security', 'internal', 'm', 'Engineering agent'], ['Build and test in a sandbox (no production)', 'operations-automation', 'internal', 'l', 'Builder agent'], ['Deploy to production', 'technology-security', 'production', null, UNASSIGNED]],
      deliverables: ['Technical spec', 'Sandbox build with test results'] },
    { id: 'product', label: 'product development', re: /\b(products?|prototypes?|e-?commerce|stores?|shopify|merch\w*|dropship\w*|inventory|suppliers?|packaging)\b/,
      tasks: [['Product and supplier shortlist', 'operations-automation', 'internal', 'l', 'Product research agent'], ['Order samples or inventory', 'finance-capital', 'spend', null, UNASSIGNED]],
      deliverables: ['Product and supplier shortlist'] },
    { id: 'acquisition', label: 'acquisition / deal', re: /\b(acqui\w*|buy|purchas\w*|property|properties|real estate|land|deals?|houses?)\b/,
      tasks: [['Screen opportunities against written criteria', 'intelligence-research', 'internal', 'l', 'Deal screening agent'], ['Make an offer or sign any agreement', 'legal-risk-compliance', 'external', null, UNASSIGNED]],
      deliverables: ['Screened opportunity list'] },
    { id: 'release', label: 'release', re: /\b(releases?|songs?|albums?|tracks?|music|artists?|singles?|mixtapes?)\b/,
      tasks: [['Release plan and timeline', 'marketing-growth', 'internal', 'm', 'Release planning agent'], ['Distribute or publish the release', 'marketing-growth', 'external', null, UNASSIGNED]],
      deliverables: ['Release plan and timeline'] },
  ];
  const GENERIC = { id: 'general', label: 'general objective', tasks: [['Investigate and outline options', 'intelligence-research', 'internal', 'l', 'Research agent'], ['Recommend next steps', 'business-development', 'internal', 'm', 'Planning agent']], deliverables: ['Options and recommendation'] };

  // ---------- helpers ----------
  function score(text, terms) {
    let n = 0; const hits = [];
    for (const t of terms) { const m = text.match(new RegExp('\\b(?:' + t + ')\\b', 'g')); if (m) { n += (t.includes(' ') ? 2 : 1) * m.length; hits.push(m[0]); } }
    return { n, hits };
  }
  // Activation approval text follows the division's status (org.js). Preparing divisions are still not authorized to operate or spend.
  const activationText = (d) => d.status === 'preparing'
    ? 'Activate ' + d.name + ' (activation order ' + d.activation_order + '): the division is PREPARING FOR ACTIVATION and is not authorized to spend, sign contracts, contact prospects or launch publicly.'
    : 'Activate ' + d.name + ': the division is DORMANT and not authorized to operate or spend.';
  const usd = (c) => '$' + ((Number(c) || 0) / 100).toFixed(2);
  const clean = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim().slice(0, 600);

  function route(text, org) {
    const t = ' ' + clean(text).toLowerCase() + ' ';
    const order = org.divisions.map((d) => d.id);
    const scored = order.map((id) => ({ id, ...score(t, DIV_RULES[id] || []) }));
    // highest score wins; on a tie the specialist beats Fruition Factory (the generalist), then org order
    scored.sort((a, b) => b.n - a.n || (a.id === 'fruition-factory') - (b.id === 'fruition-factory') || order.indexOf(a.id) - order.indexOf(b.id));
    const top = scored[0], second = scored[1];
    let division = top.id, confidence, why;
    if (top.n === 0) { division = 'fruition-factory'; confidence = 'low'; why = 'No division keyword matched. Defaulted to Fruition Factory (innovation, research and new venture development). Reassign if wrong.'; }
    else { confidence = top.n >= 3 && top.n - second.n >= 2 ? 'high' : 'medium'; why = 'Matched: ' + top.hits.join(', ') + '.'; }
    const offices = org.corporate_offices.map((o) => ({ id: o.id, ...score(t, OFFICE_RULES[o.id] || []) })).filter((o) => o.n > 0)
      .sort((a, b) => b.n - a.n || org.corporate_offices.findIndex((x) => x.id === a.id) - org.corporate_offices.findIndex((x) => x.id === b.id)).slice(0, 3).map((o) => o.id);
    if (!offices.length) offices.push('intelligence-research');
    return { division, confidence, why, offices, alternatives: scored.filter((s) => s.n > 0 && s.id !== division).map((s) => s.id) };
  }

  function plan(text, org, opts) {
    const objective = clean(text);
    if (objective.length < 8) return { error: 'Describe the objective in at least a short sentence.' };
    const t = objective.toLowerCase();
    const r = route(objective, org);
    if (opts && opts.division && opts.division !== r.division && org.divisions.some((d) => d.id === opts.division)) {
      r.alternatives = [r.division].concat(r.alternatives.filter((x) => x !== opts.division)); r.division = opts.division; r.confidence = 'set by the Chairman'; r.why = 'Division chosen by the Chairman.';
    }
    const div = org.divisions.find((d) => d.id === r.division);
    let intents = INTENTS.filter((i) => i.re.test(t));
    if (!intents.length) intents = [GENERIC];
    const tasks = [{ title: 'Confirm scope and success criteria with the Chairman', office: null, kind: 'internal', est_cents: COST.s, agent: 'Jarvis' }];
    const seen = new Set();
    for (const i of intents) for (const [title, office, kind, size, agent] of i.tasks) {
      if (seen.has(title) || tasks.length >= 9) continue; seen.add(title);
      tasks.push({ title, office, kind, est_cents: size ? COST[size] : 0, agent: kind === 'internal' ? agent + ' (proposed, not created)' : agent });
    }
    tasks.push({ title: 'Chairman reviews deliverables and decides next step', office: null, kind: 'internal', est_cents: 0, agent: 'Chairman' });
    const est = tasks.reduce((a, x) => a + x.est_cents, 0);
    const days = Math.max(1, Math.ceil(est / CAP_CENTS));
    // ---------- approvals: never empty (no division is authorized to operate and any agent run spends AI money) ----------
    const approvals = [
      { kind: 'activation', text: activationText(div) },
      { kind: 'money', text: 'Run agents for this mission: estimated ' + usd(est) + ' of AI spend, counted against the $3.30/day cap' + (days > 1 ? ' (over the cap: spread across ' + days + ' days).' : ' (fits within one day).') },
    ];
    const kinds = new Set(tasks.map((x) => x.kind));
    if (kinds.has('spend') || /\$\s?\d|\b(spend\w*|buy|pay\w*|purchas\w*|budgets?|ads?|hire|hiring|subscri\w*|invest\w*)\b/.test(t))
      approvals.push({ kind: 'money', text: 'Any spending beyond AI (per-transaction limit $25, weekly limit $75, no new subscriptions without approval).' });
    // a division preparing for activation is not authorized to contact prospects: external contact is always listed for it
    if (div.status === 'preparing' || kinds.has('external') || /\b(contact\w*|call\w*|emails?|outreach|messag\w*|post\w*|publish\w*|reach out|pitch\w*|text\w*|dm)\b/.test(t))
      approvals.push({ kind: 'external', text: 'External contact: anything sent, posted, published or signed on the company\'s behalf.' });
    if (kinds.has('production') || /\b(deploy\w*|production|go live|live site)\b/.test(t))
      approvals.push({ kind: 'production', text: 'Production action: any deploy or change to live systems.' });
    if (/\b(bank|rbc|kill switch|permissions?|credentials?|passwords?|legal|contracts?|sign\w*)\b/.test(t))
      approvals.push({ kind: 'protected', text: 'Protected area (bank, legal, credentials or controls): Chairman only.' });
    const deliverables = [...new Set(intents.flatMap((i) => i.deliverables))];
    const supporting = r.offices.map((id) => (org.corporate_offices.find((o) => o.id === id) || {}).name).filter(Boolean);
    const understanding = 'You want: ' + objective + (/[.!?]$/.test(objective) ? '' : '.') + ' I read this as ' + intents.map((i) => i.label).join(' + ') + ', owned by ' + div.name + ' with support from ' + supporting.join(' and ') + '.';
    return {
      objective, understanding, intents: intents.map((i) => i.id), division: r.division, confidence: r.confidence, why: r.why, offices: r.offices, alternatives: r.alternatives,
      tasks, est_cents: est, cap_cents: CAP_CENTS, within_cap: est <= CAP_CENTS, days_at_cap: days, approvals, deliverables, note: SIM_NOTE,
    };
  }

  // ---------- simulated mission store (pure functions on a plain state object; hq.js persists it) ----------
  function emptyState() { return { v: 1, seq: 0, missions: [], activity: [] }; }
  function log(st, mission, text, now) { st.activity.unshift({ at: now || new Date().toISOString(), mission_id: mission ? mission.id : null, text }); st.activity.length = Math.min(st.activity.length, 300); }

  function createMission(st, p, org, now) {
    if (!p || p.error) return null;
    now = now || new Date().toISOString();
    st.seq += 1; const id = 'SIM-' + String(st.seq).padStart(4, '0');
    const approvals = p.approvals.map((a, i) => ({ id: 'A' + (i + 1), kind: a.kind, text: a.text, status: 'pending' }));
    const tasks = p.tasks.map((t, i) => {
      // the opening scope talk and the final Chairman review need no approval; everything an agent or a person would execute does
      const free = i === 0 || i === p.tasks.length - 1;
      const g = (pred) => (approvals.find(pred) || {}).id;
      const act = g((a) => a.kind === 'activation'), run = g((a) => a.kind === 'money' && a.text.startsWith('Run agents'));
      const extra = { internal: run, spend: g((a) => a.kind === 'money' && a.text.startsWith('Any spending')) || run, external: g((a) => a.kind === 'external'), production: g((a) => a.kind === 'production') }[t.kind];
      const gates = free ? [] : [act, extra].filter(Boolean);
      return { id: 'T' + (i + 1), title: t.title, office: t.office, kind: t.kind, est_cents: t.est_cents, agent: t.agent, status: 'todo', gates: [...new Set(gates)] };
    });
    const m = { id, mode: 'simulated', title: p.objective.slice(0, 90), objective: p.objective, understanding: p.understanding, division: p.division, offices: p.offices,
      confidence: p.confidence, why: p.why, owner: 'Chairman', created_at: now, updated_at: now, cancelled: false, est_cents: p.est_cents, days_at_cap: p.days_at_cap,
      tasks, approvals, deliverables: p.deliverables.map((d) => ({ text: d, status: 'not started' })), notes: [], note: SIM_NOTE };
    st.missions.unshift(m); st.missions.length = Math.min(st.missions.length, 50);
    log(st, m, 'Mission ' + id + ' planned by the offline planner for ' + ((org.divisions.find((d) => d.id === m.division) || {}).name || m.division) + ' (' + tasks.length + ' tasks, ' + approvals.length + ' approvals pending). Nothing executed.', now);
    return m;
  }
  const find = (st, id) => st.missions.find((m) => m.id === id) || null;
  const pendingGates = (m, t) => t.gates.filter((g) => { const a = m.approvals.find((x) => x.id === g); return !a || a.status !== 'approved'; });
  function missionStatus(m) {
    if (m.cancelled) return 'cancelled';
    const live = m.tasks.filter((t) => t.status !== 'cancelled');
    if (live.length && live.every((t) => t.status === 'done')) return 'complete';
    if (live.some((t) => t.status === 'blocked')) return 'blocked';
    if (live.some((t) => t.status === 'doing' || t.status === 'done')) return 'in progress';
    return 'planned';
  }
  function progress(m) { const live = m.tasks.filter((t) => t.status !== 'cancelled'); return live.length ? Math.round(100 * live.filter((t) => t.status === 'done').length / live.length) : 0; }
  function blockers(m) {
    const out = [];
    m.tasks.forEach((t) => { if (t.status === 'blocked') out.push(t.id + ' ' + t.title + ': marked blocked' + (t.reason ? ' (' + t.reason + ')' : '') + '.');
      else if (t.status === 'todo' && pendingGates(m, t).length) out.push(t.id + ' ' + t.title + ': waiting for your approval ' + pendingGates(m, t).join(', ') + '.'); });
    return out;
  }
  function touch(st, m, text, now) { m.updated_at = now || new Date().toISOString(); log(st, m, text, m.updated_at); }
  // Chairman moves a task one step: todo -> doing -> done. Refused while its approvals are pending or the mission is cancelled.
  function advanceTask(st, mid, tid, now) {
    const m = find(st, mid); const t = m && m.tasks.find((x) => x.id === tid);
    if (!m || !t || m.cancelled) return { error: 'Not found or mission cancelled.' };
    if (t.status === 'done' || t.status === 'cancelled') return { error: 'Task is already ' + t.status + '.' };
    const pg = pendingGates(m, t); if (pg.length) return { error: 'Waiting for your approval: ' + pg.join(', ') + '.' };
    const from = t.status; t.status = from === 'todo' || from === 'blocked' ? 'doing' : 'done'; delete t.reason;
    touch(st, m, m.id + ' ' + t.id + ' moved ' + from + ' -> ' + t.status + ' by the Chairman (manual; nothing executed).', now);
    return { ok: true, status: t.status };
  }
  function blockTask(st, mid, tid, reason, now) {
    const m = find(st, mid); const t = m && m.tasks.find((x) => x.id === tid);
    if (!m || !t || m.cancelled || t.status === 'done' || t.status === 'cancelled') return { error: 'Cannot block this task.' };
    t.status = 'blocked'; t.reason = clean(reason).slice(0, 200) || null;
    touch(st, m, m.id + ' ' + t.id + ' marked blocked by the Chairman' + (t.reason ? ': ' + t.reason : '') + '.', now);
    return { ok: true };
  }
  function cancelTask(st, mid, tid, now) {
    const m = find(st, mid); const t = m && m.tasks.find((x) => x.id === tid);
    if (!m || !t || m.cancelled || t.status === 'done' || t.status === 'cancelled') return { error: 'Cannot cancel this task.' };
    t.status = 'cancelled'; touch(st, m, m.id + ' ' + t.id + ' cancelled by the Chairman.', now); return { ok: true };
  }
  function cancelMission(st, mid, now) {
    const m = find(st, mid); if (!m || m.cancelled) return { error: 'Not found or already cancelled.' };
    m.cancelled = true; m.tasks.forEach((t) => { if (t.status !== 'done') t.status = 'cancelled'; });
    touch(st, m, m.id + ' cancelled by the Chairman.', now); return { ok: true };
  }
  // Records the Chairman's decision in this browser only. It authorizes nothing anywhere else and executes nothing.
  function decide(st, mid, aid, approved, now) {
    const m = find(st, mid); const a = m && m.approvals.find((x) => x.id === aid);
    if (!m || !a || m.cancelled) return { error: 'Not found or mission cancelled.' };
    a.status = approved ? 'approved' : 'declined';
    touch(st, m, m.id + ' approval ' + a.id + ' recorded as ' + a.status + ' (simulated: recorded in this browser only, executes nothing).', now); return { ok: true };
  }
  function addNote(st, mid, kind, text, now) {
    const m = find(st, mid); const body = clean(text).slice(0, 2000);
    if (!m || !body) return { error: 'Nothing to add.' };
    if (!['finding', 'deliverable', 'recommendation'].includes(kind)) return { error: 'Bad note kind.' };
    m.notes.push({ kind, text: body, at: now || new Date().toISOString(), by: 'Chairman' });
    touch(st, m, m.id + ' ' + kind + ' added by the Chairman.', now); return { ok: true };
  }
  function reassign(st, mid, divisionId, org, now) {
    const m = find(st, mid); const d = org.divisions.find((x) => x.id === divisionId);
    if (!m || !d || m.cancelled || m.division === divisionId) return { error: 'Cannot reassign.' };
    m.division = divisionId; const a = m.approvals.find((x) => x.kind === 'activation');
    if (a) { a.text = activationText(d); a.status = 'pending'; }
    if (d.status === 'preparing' && !m.approvals.some((x) => x.kind === 'external'))
      m.approvals.push({ id: 'A' + (m.approvals.length + 1), kind: 'external', text: 'External contact: anything sent, posted, published or signed on the company\'s behalf.', status: 'pending' });
    touch(st, m, m.id + ' reassigned to ' + d.name + ' by the Chairman; activation approval reset to pending.', now); return { ok: true };
  }
  // Validate whatever came back from browser storage; anything malformed is dropped rather than rendered.
  function load(raw) {
    try {
      const s = JSON.parse(raw); if (!s || s.v !== 1 || !Array.isArray(s.missions) || !Array.isArray(s.activity)) return emptyState();
      s.missions = s.missions.filter((m) => m && typeof m.id === 'string' && Array.isArray(m.tasks) && Array.isArray(m.approvals) && Array.isArray(m.notes));
      s.activity = s.activity.filter((a) => a && typeof a.text === 'string'); s.seq = Number(s.seq) || s.missions.length; return s;
    } catch (e) { return emptyState(); }
  }

  root.HQJarvis = { SIM_NOTE, CAP_CENTS, UNASSIGNED, route, plan, emptyState, createMission, advanceTask, blockTask, cancelTask, cancelMission, decide, addNote, reassign, missionStatus, progress, blockers, pendingGates, load, usd };
})(typeof window !== 'undefined' ? window : globalThis);
