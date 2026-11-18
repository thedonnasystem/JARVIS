# FF Marketing OS: overview (branch build/ffm-os, NOT deployed)

FF Marketing is one reusable marketing-agency OS run per client "workspace". Built on `client_workspaces` (migration 20261117) and extended by `migrations/20261118_ffm_onboarding_v1.sql`. Local replica only: nothing pushed, merged, applied to production, activated, spent or sent.

## What exists
| Layer | Object | What it does |
|---|---|---|
| Onboarding | `ffm_onboarding_templates` (generic, mortgage, insurance) -> `ffm_onboarding_items` | Checklist copied per workspace by `ffm_instantiate_onboarding`. Each item: provider (owner/client/ai), required, status pending/provided/blocked, value, blocked_until |
| Gate | `ffm_readiness`, `ffm_activate` | Activation refused until every required item holds a real value, a budget is set, and a current owner approval exists. Placeholders (unset, tbd, n/a...) are rejected |
| Owner-only | `ffm_set_budget`, `ffm_owner_approve`, `ffm_revoke_approval`, creative approval | Check `is_app_owner()`. The bot (service_role) has no signed-in owner, so it is refused |
| Campaigns | `ws_campaigns` -> `ffm_ad_sets` -> `ffm_creatives` | Plain-text drafts. `dry_run` is a CHECK-constrained true: nothing can launch. Campaign status can reach `approved`, never `running`, from this code |
| Routing | `ffm_routing_rules`, `ffm_route_preview`, `ffm_route_log` | A rule starts with no fields. Only name, email, phone, source, campaign_id, stage, created_at are allowed; free-text notes never are. Preview only, logged |
| Reporting | `ffm_funnel`, `ffm_lead_booked_rate`, `ffm_spend_report`, `ffm_weekly_report`, views `ffm_funnel_v`, `ffm_spend_v` | Always per workspace_id |
| Guard | `ffm_guard` (uses `ws_sensitive_hits`, the same detector as `ws_guard`) | Refuses SIN/card/account-like numbers, ID, banking, credit, application and income terms on every text column of every new table. ids and timestamps are skipped (they can compact into false digit runs) |
| Engine | `hq_ffm_engine.py`, `prompts/ffm/`, `ffm_engine_briefs` / `ffm_engine_packs` (migration 20261125) | Owner-triggered (`/ffm new|pack|show|list|queue`) draft campaign pack per workspace: cheap model via the spend gateway, per-pack ceiling, every string screened, drafts only. See OWNER_GUIDE_JARVIS_V2.md section 12 |
| App code | `hq_ffm.py` | `onboarding_plan`, `render_weekly_report`, `cost_per_booked` (pure) plus `_rpc` wrappers that turn refusals into typed exceptions |

## Safety model
- Default deny: budget NULL, routing fields empty, workspace `draft`, dry_run true, all tables RLS-on with no policy, service_role read-only on tables, writes only via functions.
- Sensitive-data rule is structural for the mortgage client: there is no free-form column, the guard is fail-closed, and `hq_ffm.provide_input` and `weekly_report_text` screen text before it leaves the module. Detection is a heuristic backstop, not a reason to relax the process rules in the client docs.
- Isolation: composite foreign keys (workspace_id, id) make cross-client references impossible; every report filters by workspace.
- Nothing here contacts anyone or spends: sending, ad platform calls and real spend remain separate owner gates (HQ spend gateway, executor gate).

## Per-client docs
- `FFM_CLIENT1_MORTGAGE_ONBOARDING.md` (Ontario mortgage broker)
- `FFM_CLIENT2_INSURANCE_ONBOARDING.md` (life-insurance professional; recruiting model NOT finalised)

## Not built (needs owner decision or credentials)
Owner-facing PWA screens for budget and approvals (the 7 `app_ffm_*` owner wrappers exist but are CLOSED like `app_needs_you`; opening them needs owner sign-off, see ops/pending_signoff/ffm_open_app_ffm.txt); ad-platform and CRM connectors; real lead-to-client delivery; lead stage history (reports use current stage of leads created in the period); consent log table (see Client 1 doc, item to decide).
