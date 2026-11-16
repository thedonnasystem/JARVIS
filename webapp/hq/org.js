'use strict';
// FENDEZY HQ: ORGANIZATION AND POLICY DATA (window.HQ_ORG).
// Source: owner-provided organization brief of 2026-11-16. Names and one-line descriptions are the Chairman's own words; nothing here is
// inferred from any other source. There are NO invented people, balances, KPIs or results in this file. Anything the owner has not
// defined yet is null and is shown as "Unassigned — awaiting owner".
// Shape follows ops/org/divisions.json (PR #26 contract): divisions[] / corporate_offices[] with id, name, kind, status, charter, manager.
(function (root) {
  const div = (n, id, name, text) => ({ n, id, name, kind: 'division', status: 'dormant', authorized_to_operate: false, authorized_to_spend: false,
    charter: { text, authored_by: 'owner' }, manager: { title: name + ' division manager', assigned: null, reports_to: 'jarvis' } });
  const off = (id, name) => ({ id, name, kind: 'office', status: 'dormant', head: { assigned: null, reports_to: 'jarvis' } });
  root.HQ_ORG = {
    meta: { schema: 'hq-org-2', source: 'owner-provided organization brief, 2026-11-16', note: 'All divisions DORMANT: not authorized to operate or spend.' },
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
        note: 'Permanent group-level capability, governed under Technology & Security. Recommendation: owner to confirm.' },
    ],
    // Read-only policy. Never editable from the app. Cents unless named otherwise.
    policy: {
      capital_framework_cents: 30000, reserve_cents: 5000, hard_stop_cents: 2000, low_cost_mode_cents: 10000,
      per_transaction_limit_cents: 2500, weekly_limit_cents: 7500, ai_daily_cap_cents: 330,
      automatic_reloads: false, new_subscriptions: 'Not without Chairman approval', tax_set_aside_pct: 33, operating_buffer_months: 1.5,
      reinvestment_pool: [60, 25, 15], max_active_revenue_ventures: 3, bank_reconciliation: 'manual',
    },
    bank: { name: 'RBC', status: 'Not connected — manual reconciliation required' },
    // System status as reported to the builder on this date. NOT read live.
    status_as_of: {
      date: '2026-11-16',
      items: [
        ['Production', 'Untouched by this build'],
        ['Railway bot', 'Running commit ecadb31'],
        ['Mode', 'Dry-run'],
        ['Kill switch', 'Off'],
        ['Executor registry', 'Empty'],
        ['Security PRs #16, #17, #20', 'In final verification'],
        ['Release', 'Awaiting Chairman authorization'],
      ],
    },
  };
})(typeof window !== 'undefined' ? window : globalThis);
