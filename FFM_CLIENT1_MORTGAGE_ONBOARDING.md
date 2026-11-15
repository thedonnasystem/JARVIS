# Client 1: Ontario mortgage broker (FF Marketing onboarding)

Status: process and data model only. Budget, geography, CRM, brokerage identity and dates are NOT set and must come from the owner/client. Compliance notes below are items to CONFIRM with the client and their principal broker. They are not legal advice.

## Hard rule
The AI never touches mortgage applications, banking, credit, ID or sensitive financial information. The AI works only with marketing material (ad copy, audiences described in words, public landing pages) and the minimum lead contact fields. Enforcement: `ffm_guard` refuses such text in every table; `ffm_routing_rules.allowed_fields` can only hold name, email, phone, source, campaign_id, stage, created_at. If a client or lead sends a document or a number in chat, the human stops and handles it outside the AI.

## Step-by-step
1. Owner creates the workspace (vertical `mortgage`, status stays `draft`). Run `ffm_instantiate_onboarding` (13 items: 9 generic + 4 mortgage; 11 required).
2. Owner sets the monthly budget (owner-only `ffm_set_budget`). Until then it is `unset` and all spend is refused.
3. Collect each required input from the right party (table below). Record with `ffm_provide_input(ws, key, value, who)`. If waiting, `ffm_block_input` with a reason.
4. Client confirms in writing the no-sensitive-files rule (`no_sensitive_files_confirmed`) and the exact lead-field list (`lead_fields_agreed`).
5. Draft campaign, ad sets, creatives (`ffm_add_*`). Creative goes to `in_review`; the brokerage signs off per its own process; the owner marks it approved (owner-only).
6. Owner reviews `ffm_readiness` / `hq_ffm.plan_for`, approves activation (owner-only), then `ffm_activate`. Any later change to an input or the budget makes the approval stale and requires re-approval.
7. Routing rule(s) drafted with the agreed fields only, owner approves, `ffm_route_preview` shows exactly what would be passed (dry run).
8. Going live (real ad spend, real lead delivery, any outreach) is a SEPARATE owner gate not covered by this build.

## What the owner/client must provide
| Key | Provider | Required | Notes |
|---|---|---|---|
| monthly_budget | owner | yes | also set the numeric budget via owner-only function |
| service_geography | client | yes | as the client states it; not assumed |
| crm_destination | client | yes | name and intake address; credentials stay with client |
| booking_link | client | yes | |
| consent_wording | client | yes | exact text next to the form |
| compliance_contact | client | yes | |
| ad_account_access | client | yes | client connects; no passwords in chat |
| licence_details | client | yes | brokerage and broker details as they must appear |
| ad_review_signoff | client | yes | who approves copy, how |
| no_sensitive_files_confirmed | client | yes | |
| lead_fields_agreed | client | yes | |
| brand_assets | client | no | |
| launch_deadline | owner | no | left pending, not invented |

## What the AI may and may not touch
| May | May not |
|---|---|
| Draft ad copy, headlines, CTAs, landing text for review | Receive or store applications, banking, credit, ID, income/financial documents |
| Describe audiences in words; draft ad sets | Publish, launch, change budgets on an ad platform |
| Route allow-listed contact fields (dry run) | Pass notes/free text to the client's systems |
| Produce counts-only weekly reports | Contact leads or the client without an owner gate |
| Flag missing inputs | Guess geography, budget, CRM, dates |

## Compliance guardrails to confirm with the client (sources verified in this build)
1. Ontario mortgage advertising (FSRA): rules under the Mortgage Brokerages, Lenders and Administrators Act, 2006 cover ads, emails, web pages and other materials; misleading or incomplete information is prohibited; the brokerage's authorized name and licence number must be shown clearly and prominently; agents/brokers show licensed name, approved title, and the sponsoring brokerage's name and licence number; team names cannot be used in ads; FSRA does not pre-approve ads, so review goes through the brokerage/principal broker; email signatures and websites carry the same identifiers. Source: https://www.fsrao.ca/industry/mortgage-brokering/mortgage-industry-public-relations-and-advertising-requirements . CONFIRM: exact wording, titles and where identifiers must appear in each ad format, including small mobile ad units.
2. CASL (Canada's anti-spam law): commercial electronic messages need express or (limited, expiring) implied consent, sender identification and an unsubscribe mechanism honoured within 10 business days; the sender must be able to prove consent. Source: https://crtc.gc.ca/eng/com500/guide.htm . CONFIRM: consent wording on forms, who keeps consent records, and that no outreach is sent before the owner gate. The current data model has no consent log; decide whether to add one before any messaging.
3. Meta special ad categories: advertisers targeting Canada with housing, employment or credit ads must declare the category, and these categories restrict targeting (fixed age range, no gender targeting, no lookalikes, no ZIP targeting, minimum location radius). Source: https://developers.facebook.com/docs/marketing-api/audiences/special-ad-category . NOT VERIFIED: whether mortgage ads fall under credit and/or housing in Meta's current policy (the policy page could not be retrieved). CONFIRM in Meta Ads policy / with Meta before building audiences, and plan creative for the restricted targeting.
4. Privacy of lead data (PIPEDA / Ontario): not researched in this build. CONFIRM with the client how lead data is collected, retained and shared, and add the notice to the form.
5. Client's own brokerage policies (compliance manual, approval steps) override this list.

## Campaign architecture (starter, all drafts)
Campaign (one goal, e.g. renewal-season awareness) -> Ad sets (audience described in words, optional daily budget cents, NULL by default) -> Creatives (headline up to 120, body up to 1000, CTA up to 60 chars). Statuses: draft -> in_review -> approved (owner). Campaign `approved` requires an active workspace and at least one approved creative. Nothing reaches `running`.

## Reporting spec
Weekly (`ffm_weekly_report`, rendered by `hq_ffm.render_weekly_report`): readiness; leads created in the period by current stage; lead-to-booked rate (booked + handed_off over leads); spend in period, month-to-date, budget, remaining, % used (shows `unset` if no budget); campaigns by status; creatives awaiting review; cost per booked (derived, none if zero booked). Counts only, no lead-level data. Limitation: no stage history.

## Integrations
| Connection | Direction | Owner/client credential needed | Status |
|---|---|---|---|
| Meta ad account | HQ drafts -> client publishes | Client grants access | Not built |
| Landing page / lead form | public -> `ws_add_lead` | Hosting/domain from owner | Not built |
| Broker CRM / inbox | rule payload -> client system | Client intake address or webhook; client holds credentials | Not built (preview only) |
| Booking calendar | link only | Client link | Value recorded only |
| HQ spend gateway / executor gate | cost control | none new | Exists |
| Owner approvals | PWA | owner login | Wrapper not built |

## Open items for the owner
Budget; geography; CRM; brokerage identity and licence display text; sign-off route; consent wording; decision on a consent-log table; Meta category confirmation; go-live gate.
