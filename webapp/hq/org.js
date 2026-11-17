'use strict';
// FENDEZY HQ: ORGANIZATION AND POLICY DATA (window.HQ_ORG).
// Source: owner-provided organization brief of 2026-11-16 and the Chairman's decisions of 2026-11-16 (Engineering & Reliability approved;
// positions unassigned until the Chairman appoints; activation order Donna 1, Wolf Squad 2, FF Marketing 3). Names and one-line descriptions
// are the Chairman's own words. There are NO invented people, balances, KPIs or results in this file. Every position is unassigned (null)
// and is shown as "Unassigned — awaiting Chairman's appointment." Role descriptions under proposed_roles are drafts labelled
// "PROPOSED — for Chairman approval"; they grant nothing.
// Shape follows ops/org/divisions.json (PR #26 contract): divisions[] / corporate_offices[] with id, name, kind, status, charter, manager.
(function (root) {
  // status: 'preparing' (activation order set by the Chairman) or 'dormant'. Neither is authorized to operate or spend.
  const ORDER = { donna: 1, 'wolf-squad': 2, 'ff-marketing': 3 };
  const div = (n, id, name, text) => ({ n, id, name, kind: 'division', status: ORDER[id] ? 'preparing' : 'dormant', activation_order: ORDER[id] || null,
    authorized_to_operate: false, authorized_to_spend: false,
    charter: { text, authored_by: 'owner' }, manager: { title: name + ' division manager', assigned: null, reports_to: 'jarvis' } });
  const off = (id, name) => ({ id, name, kind: 'office', status: 'dormant', head: { assigned: null, reports_to: 'jarvis' } });
  const R = (role, responsibilities, criteria) => ({ role, responsibilities, selection_criteria: criteria });
  root.HQ_ORG = {
    meta: { schema: 'hq-org-2', source: 'owner-provided organization brief, 2026-11-16', note: 'Donna, Wolf Squad and FF Marketing are preparing for activation (order 1, 2, 3); the other five are dormant. None is authorized to operate or spend.' },
    unassigned_text: 'Unassigned — awaiting Chairman\'s appointment.',
    status_text: {
      preparing: 'Preparing for activation — not authorized to spend, sign contracts, contact prospects or launch publicly',
      dormant: 'Dormant',
    },
    chairman: { id: 'chairman', title: 'Chairman' },
    jarvis: { id: 'jarvis', title: 'Jarvis', reports_to: 'chairman', role: 'Group operator. Division managers report to Jarvis; Jarvis reports to the Chairman.' },
    divisions: [
      div(1, 'b2b-records', 'B2B Records', 'Music label, artist development, production and releases.'),
      div(2, 'donna', 'Donna', 'AI agency, automation and business process systems.'),
      div(3, 'the-trap', 'The Trap', 'E-commerce and product-development ventures.'),
      div(4, 'wolf-squad', 'Wolf Squad', 'Prospecting, sales and revenue generation.'),
      div(5, 'pimp-ai', 'Pimp AI', 'AI model brands and compliant content monetization.'),
      div(6, 'monopoly', 'Monopoly', 'Real estate ventures, acquisitions and property opportunities.'),
      div(7, 'ff-marketing', 'FF Marketing', 'Advertising, campaigns, content and audience growth.'),
      div(8, 'fruition-factory', 'Fruition Factory', 'Innovation, research and new venture development.'),
    ],
    corporate_offices: [
      off('business-development', 'Business Development'), off('marketing-growth', 'Marketing & Growth'), off('sales-revenue', 'Sales & Revenue'),
      off('operations-automation', 'Operations & Automation'), off('finance-capital', 'Finance & Capital'), off('legal-risk-compliance', 'Legal, Risk & Compliance'),
      off('intelligence-research', 'Intelligence & Research'), off('technology-security', 'Technology & Security'),
    ],
    standing_functions: [
      { id: 'engineering-reliability', name: 'Engineering & Reliability', kind: 'standing_function', governed_by: 'technology-security', permanent: true,
        status: 'approved', approved_by: 'Chairman', approved_on: '2026-11-16', head: { assigned: null, reports_to: 'technology-security' },
        note: 'APPROVED by the Chairman (2026-11-16) as a permanent group-level function under Technology & Security.',
        responsibilities: ['Platform reliability', 'Infrastructure and deployment health', 'Testing and release engineering', 'Incident detection and recovery',
          'Monitoring and rollback readiness', 'Technical documentation and system integrity'],
        constraint: 'Cannot independently approve its own critical production changes.' },
    ],
    // Drafts for the Chairman. PROPOSED — for Chairman approval. Nobody is appointed; nothing here grants a permission.
    proposed_label: 'PROPOSED — for Chairman approval',
    appointment_note: 'Jarvis may recommend candidates or agent configurations but cannot grant permissions. Only the Chairman appoints and authorizes.',
    reporting_lines: {
      division: 'Division manager -> Jarvis -> Chairman',
      office: 'Office head -> Jarvis -> Chairman',
      standing_function: 'Engineering & Reliability lead -> Technology & Security',
    },
    proposed_roles: {
      'b2b-records': R('Runs the music label: artist development, production schedule and releases.',
        ['Artist pipeline and development plans', 'Production and release calendar', 'Release budgets submitted for approval', 'Rights and splits records kept with Legal, Risk & Compliance'],
        ['Music industry or label operations knowledge', 'Can run a release on schedule and budget', 'Respects rights, licensing and approval gates']),
      donna: R('Runs the AI agency: automation and business process systems for clients.',
        ['Service offer and delivery standards', 'Client project plans and handover', 'Automation quality and client data handling', 'Activation readiness report to the Chairman (activation order 1)'],
        ['Has delivered automation or AI projects for clients', 'Clear written scoping and estimates', 'Strict on client data and consent']),
      'the-trap': R('Runs e-commerce and product-development ventures.',
        ['Product and supplier research', 'Store and listing plans', 'Unit economics before any inventory spend', 'Returns, fulfilment and customer-service standards'],
        ['E-commerce or product-launch experience', 'Works from numbers: margins, landed cost, payback', 'Keeps spend inside the approved limits']),
      'wolf-squad': R('Runs prospecting, sales and revenue generation.',
        ['Prospect lists and qualification rules', 'Sales scripts and follow-up cadence (drafts until contact is approved)', 'Pipeline and conversion reporting', 'Activation readiness report to the Chairman (activation order 2)'],
        ['Proven prospecting and closing record', 'Follows consent and anti-spam rules', 'Reports pipeline honestly, no inflated numbers']),
      'pimp-ai': R('Runs AI model brands and compliant content monetization.',
        ['Brand concepts and content calendars', 'Platform policy and content compliance checks', 'Monetization plans submitted for approval', 'Disclosure that content is AI-generated where required'],
        ['Content brand or creator-economy experience', 'Knows platform rules and stays inside them', 'Treats compliance as a hard gate']),
      monopoly: R('Runs real estate ventures, acquisitions and property opportunities.',
        ['Deal sourcing and screening criteria', 'Underwriting before any offer', 'Offer and contract packages sent to the Chairman (no signing)', 'Relationships with buyers and partners after contact is approved'],
        ['Real estate deal analysis experience', 'Disciplined underwriting', 'Never commits capital or signs without approval']),
      'ff-marketing': R('Runs advertising, campaigns, content and audience growth.',
        ['Campaign plans and creative briefs', 'Ad budgets submitted for approval', 'Audience growth and performance reporting', 'Activation readiness report to the Chairman (activation order 3)'],
        ['Paid and organic marketing experience', 'Measures results against spend', 'Nothing published without approval']),
      'fruition-factory': R('Runs innovation, research and new venture development.',
        ['Opportunity research and venture proposals', 'Validation plans with small, capped budgets', 'Kill or continue recommendations to the Chairman', 'Hands validated ventures to the right division'],
        ['Research and validation discipline', 'Comfortable recommending a stop', 'Writes clear, evidence-based proposals']),
      'business-development': R('Leads partnerships, new channels and deal flow for every division.',
        ['Partnership and channel pipeline', 'Proposal and pitch drafts', 'Opportunity hand-off to divisions'],
        ['Partnership or BD experience', 'Strong written proposals', 'No commitments without approval']),
      'marketing-growth': R('Leads shared brand, positioning and growth practice for every division.',
        ['Brand and messaging standards', 'Shared growth playbooks', 'Marketing reporting across divisions'],
        ['Brand and growth experience', 'Data-led', 'Keeps divisions consistent']),
      'sales-revenue': R('Leads shared sales process, pricing and revenue reporting.',
        ['Sales process and pricing standards', 'Revenue reporting across divisions', 'CRM and pipeline hygiene'],
        ['Sales leadership or revenue operations experience', 'Accurate reporting', 'Follows consent rules']),
      'operations-automation': R('Leads shared operations, workflows and automation for every division.',
        ['Standard operating procedures', 'Workflow automation backlog', 'Vendor and tool inventory'],
        ['Operations or automation experience', 'Documents everything', 'Cost-aware']),
      'finance-capital': R('Leads budgets, the waterfall, spend limits and reconciliation.',
        ['Budgets and spend tracking against policy', 'Manual bank reconciliation', 'Tax set-aside and buffer tracking', 'Monthly finance report to the Chairman'],
        ['Bookkeeping or finance experience', 'Accuracy over speed', 'Never moves money without approval']),
      'legal-risk-compliance': R('Leads legal review, contracts, risk and compliance.',
        ['Contract and terms review (drafts only)', 'Consent, privacy and advertising compliance', 'Risk register'],
        ['Legal or compliance background', 'Flags risk early and plainly', 'No signing authority']),
      'intelligence-research': R('Leads market research and competitive intelligence.',
        ['Research briefs on request', 'Source quality and citations', 'Market and competitor watch'],
        ['Research experience', 'Cites sources', 'Separates fact from estimate']),
      'technology-security': R('Leads platforms, security and access for the group; governs Engineering & Reliability.',
        ['Platform and tool architecture', 'Security, access and credentials policy (Chairman controls access)', 'Oversight of Engineering & Reliability', 'Second approval on critical production changes'],
        ['Engineering and security experience', 'Least-privilege mindset', 'Keeps production changes behind approval']),
      'engineering-reliability': R('Keeps the platform reliable: deployments, tests, monitoring, incidents and recovery.',
        ['Platform reliability', 'Infrastructure and deployment health', 'Testing and release engineering', 'Incident detection and recovery', 'Monitoring and rollback readiness', 'Technical documentation and system integrity'],
        ['Release and operations engineering experience', 'Tests and rollback before every change', 'Accepts that critical production changes need approval outside the function']),
    },
    // Read-only policy. Never editable from the app. Cents unless named otherwise.
    policy: {
      capital_framework_cents: 30000, reserve_cents: 5000, hard_stop_cents: 2000, low_cost_mode_cents: 10000,
      per_transaction_limit_cents: 2500, weekly_limit_cents: 7500, ai_daily_cap_cents: 330,
      automatic_reloads: false, new_subscriptions: 'Not without Chairman approval', tax_set_aside_pct: 33, operating_buffer_months: 1.5,
      reinvestment_pool: [60, 25, 15],
      // Current definitions = the existing ledger (migrations/20261112_finance_rules_v1.sql pool_best_pct / pool_research_pct / pool_deal_pct;
      // hq_waterfall.py). Not changed here.
      reinvestment_ledger: [{ pct: 60, label: 'Best venture' }, { pct: 25, label: 'Research and systems' }, { pct: 15, label: 'Held for a deal' }],
      reinvestment_proposed: { status: 'Proposed labels — conflict with ledger definitions, awaiting Chairman confirmation',
        labels: [{ pct: 60, label: 'Growth & Reinvestment' }, { pct: 25, label: 'Strategic Capital' }, { pct: 15, label: 'Innovation & New Ventures' }],
        conflict: 'The ledger puts 25% into research and systems and holds 15% for a deal; the proposal puts 25% into strategic capital and 15% into innovation and new ventures, so the 25% and 15% buckets change meaning.' }, max_active_revenue_ventures: 3, bank_reconciliation: 'manual',
    },
    bank: { name: 'RBC', status: 'Not connected — manual reconciliation required' },
    // Build/release status as reported on this date. NOT read live. Live controls (kill switch, mode, spend) are shown only from the backend.
    status_as_of: {
      date: '2026-11-16',
      items: [
        ['Production', 'Untouched by this build'],
        ['Security PRs #16, #17, #20', 'In final verification'],
        ['Release', 'Awaiting Chairman authorization'],
      ],
    },
  };
})(typeof window !== 'undefined' ? window : globalThis);
