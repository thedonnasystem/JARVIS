# Owner decisions: one page (2026-11-13)
Legend: BLOCKS = blocks production release. Defaults are recommendations only; nothing is applied until you say so.

## A. Release gates (each is a separate authorization)
| # | Decision | What it does | Risk | Default | Blocks release? |
|---|---|---|---|---|---|
| A1 | Merge PR #3, then retarget and merge PR #4 | Publishes the PWA; code only, no DB change | PWA calls RPCs that don't exist until A2 | Approve, then do A2 immediately | Yes (it is the release) |
| A2 | Apply 4 migrations then `lockdown_v1` last | Adds backup helpers, venture engine, suppression/deals/replies, Needs-You inbox | DB changes are not fully reversible (tables/data stay; see package s5) | Approve after you run `ops/preflight_*.sql` | Yes |
| A3 | Deploy Railway (fast-forward) | Puts new bot code live; still dry-run | Bug in new code; `/kill` stops spend | Approve after A2 verifies | Yes |
Exact heads, checksums, order: `PRODUCTION_APPROVAL_PACKAGE.md`.

## B. Protected-control decisions
| # | Decision | What it does | Risk | Default | Blocks? | Can wait? |
|---|---|---|---|---|---|---|
| B1 | Send-policy patch (`ops/pending_signoff/send_policy_single_authorization.sql`) | One send consumes one allowance, not two | Edits a protected trigger | Approve, but only before any live email | No (no live send is possible today) | Yes, must precede live email |
| B2 | Dead `live()` gate (mode `live` forbidden by CHECK) | Decides how real sending is ever enabled | Wrong fix could open sending | Leave as is until you want live email | No | Yes |
| B3 | `app_needs_you()` access (`ops/pending_signoff/inbox_open_app_needs_you.txt`) | PWA inbox shows items | Opens one read RPC to the PWA role; leaks names/ids of open items | Approve (read-only, owner-only PWA) | No (inbox stays empty without it) | Yes |
| B5 | Protected spend/send hardening (`ops/pending_signoff/audit_spend_send_hardening.sql`, F2/F3/F7-F9/F12) | Rejects negative/re-settled LLM amounts, bounds settle_spend, blocks `sent_by=owner` bypass of kill switch/dry-run, blocks sent->draft, blocks API role adding policy rows | Edits protected spend/permission functions; F2 also needs a small `hq_commands.mark_sent` change | Approve before any live email or real spend; all findings are latent today | No | Yes, but before going live |
| B4 | Unsuppression policy | Today opt-outs are permanent | Re-mailing an opt-out breaks CASL | Keep permanent; any exception = written owner-signed re-consent record | No | Yes |

## C. Evidence verification D1-D8
Built and merged into PR #4 in **shadow mode** (audits, downgrades nothing; env `HQ_EVIDENCE_V2=off|shadow|enforce`). Migration `20261116_evidence_sources_v1` is part of the release. Flipping to enforce = D2.
D1 snapshot capture on (yes); D2 shadow 2 weeks then enforce material claims (yes); D3 judge off at first (off); D4 retention 90/180 days (yes); D5 corroboration 2 domains for money/legal/medical (yes); D6 judge ceiling min(10% budget, 30c), 6 calls (yes); D7 staleness 24 months (yes); D8 legacy evidence ok for non-material claims, flagged (yes). Risk: only that stricter checks downgrade more missions. Blocks release: **No.** Can wait: yes (build is on a dev branch).

## D. E1 agent tools D1-D12 (design only, nothing built live)
Defaults: 1 approve E1a first; 2 first live tool = `send_approved_email` for one prospect; 3 allow small engine hook (separately reviewed); 4 = B1; 5 one-by-one approvals for 2 weeks; 6 internal calendar only; 7 C-tier tools only for `donna-ops` + one agent per venture; 8 force approval after `fetch_url`; 9 `prepare_payment` only; 10 curated fetch hosts; 11 owner reconciles unknown states; 12 new grants default 0/day. Blocks release: **No.** Can wait: yes.

## E. Ventures and backup
| # | Decision | Default | Blocks? |
|---|---|---|---|
| E1 | Venture email config (CASL sender identity, address, offer/CTA) via `/setaddress` + `set_venture_config` | Do before any outreach; you enter it | No (blocks outreach, not release) |
| E2 | B2 backup setup (you, locally; free tier; stop if card requested) | Do after release; then run restore proof | No, but backup stays "not proven" until the real restore passes |

## F. First mission (dry-run, see `FIRST_MISSION.md`)
Approve creating it after A3. It spends AI budget (cap $10 hard max, default far lower) and the system is currently paused for `api_credits`; unpausing/adding credits is YOUR authorization. Blocks release: No.

## What I need from you, in order
1. Run `ops/preflight_live.sql`, `ops/verify_live.sql`, `ops/preflight_sprint12.sql` in the Supabase SQL editor and send me the result tables (no secrets in them), or reconnect the Supabase connector.
2. Say "approve A1-A3" (or each separately).
3. Optionally decide B1/B3 in the same message.

## G. Insurance wording classifier (20261122, PR #17; each item is an owner action, nothing is enabled by default)
| # | Decision | Default | Blocks release? |
|---|---|---|---|
| G1 | Approve, edit or reject the proposed insurance PRODUCT terms, FEATURE phrases and PLACE names (`FFM_CLIENT2_INSURANCE_ONBOARDING.md`); you add them with `ws_add_approved_term` (the bot cannot) | Approve the English and French product list for the client's workspace only | No (until you add terms, health wording is refused exactly as before) |
| G2 | Scope: workspace-only or vertical-wide (vertical-wide needs the explicit confirm flag and is audit-logged) | Workspace-only | No |
| G3 | Income-bearing product names (income protection, disability income insurance) | Approve for the client only if the client sells them | No |
| G4 | Vocabulary additions as real copy meets over-blocks (brand and agency words, "spend", "push", "Monday to Friday" wording); a person, narrative, claim or health word can never be added | Add on demand | No |
| G5 | CHANGED in round 4 (was "keep strict", which stored "takes <drug> daily", ages, income and beneficiaries in lead notes): in an insurance workspace lead notes, sources, names, routing rules and consent rows get the insurance screen. Notes are vocabulary-only, so most free-text notes are refused. Options: (a) accept as built; (b) no free-text note at all, fixed choices only (safest); (c) go back to the old deny-list (NOT recommended: it stores health and application details) | (a), and keep real notes in the client's CRM | No |
| G6 | Every free-text value in an insurance workspace (campaign, ad set, creative, ledger) is vocabulary-only; brand, agency and street names, bare numbers, ages and years are refused. Onboarding ANSWERS are screened by lists instead (third review): e-mail / link only for the business-contact keys, names only for `compliance_contact` | Accept; add vocabulary words, approve feature phrases or rephrase | No |
| G7 | Residual risks you accept: a vocabulary word that is also a name in a position the rule does not cover (see G10; "life insurance for will" and "Worker can not work" are now refused); up to three spelled-out numbers; feature phrases are generic only because you approved them; an insurance word in a language other than en/fr/de/es/it/pt in a NON-insurance workspace; free-text `provided_by`; no non-Latin approved terms | Accept | No |
| G8 | Hard-deny and name lists are code (migration), not owner data: new conditions, drugs or names need a migration | Accept | No |
| G9 | NEW OWNER LIST: fixed phrases (`ws_fixed_phrases`; add with `ws_add_fixed_phrase(lang, phrase)`, remove with `ws_remove_fixed_phrase(id)`; owner-only, soft removal, audit without the text). Seeded with about 60 en/fr phrases ("contact us", "our team", "notre equipe", "Mon-Fri" ...). Review the seed and add the client's own ("book a call", "get a quote"). The vocabulary seed (about 1,350 words) and this seed are agent-written and ship active: review them line by line rather than accepting them unseen (round 4 took `late`, `losing`, `job`, `cash` out) | Review, then accept | No |
| G10 | Residual risks you accept (third review): a name split into vocabulary words ("Brand on"); a season at the edge of a text ("Summer"); an unlisted single-word name as an actor tag or inside an onboarding value; onboarding values are list-screened, not default-deny; 6 of 205 (2.9%) avoidable refusals on the measured corpus, 34 of 205 (16.6%) in all on the AUTHOR'S OWN corpus. CORRECTED in round 4: on the independent reviewer's held-out corpus **83 of 127 lines (65.4%) are refused** with the proposed terms (67.7% before round 4), 92 (72.4%) as shipped; e-mails 13/15, social 15/15. Do not rely on 16.6% for new copy (policy 5a, round 4 limits) | Accept the residual risks; decide the over-blocking under G15 | No |
| G12 | Amounts in copy (round 4, B1): only a price per day / week / month with a lead word ("from $18 a month") and a round coverage ceiling ("up to $500,000") are accepted; every other amount, spelled-out magnitude, pay or debt figure is refused. Options: (a) keep; (b) no amounts at all; (c) widen (yearly prices, price lists): reopens part of B1 | (a) | No |
| G13 | Feature phrases (round 4, B2): approve only phrases that do not name a condition ("no medical exam", "examen médical") unless the client's compliance contact wants the condition list; a condition-naming phrase works only as a whole value or in a plain coverage template. "non smokers" / "non fumeurs" can no longer be approved | Approve "no medical exam" / "examen médical" only | No |
| G14 | Which workspaces get the insurance screen (round 4, S3): every workspace whose vertical is not exactly `mortgage`. Options: (a) keep (new non-insurance verticals arrive by migration); (b) an explicit owner flag per workspace (needs a column and an owner function: a follow-up) | (a) now, (b) when a third vertical exists | No |
| G15 | Over-blocking target. 65.4% of independent marketing lines are refused today. Proposals, NOT applied (each is your call): (1) review the seeded vocabulary (about 1,350 words, agent-written) and add the roughly 100 ordinary words the held-out copy needed (vs, welcome, subject, reminder, unsubscribe, privacy, information, merci, bonjour, demande ...); (2) decide whether we / our / us / notre / nos stay phrase-only (20 of the 83 refused lines) or become vocabulary: no evidence yet that they are safe alone ("our client has ...", "we lost ..."), so the recommendation is to keep them denied and add fixed phrases such as "we compare", "our licensed advisors", "call us"; (3) people / clients / parents / baby / someone stay denied (they introduce a person); (4) "no pressure", "top-rated", "did you know" as fixed phrases; (5) set a target (for example under 20% on a held-out corpus) before the client's copy is written in this system | Set a target; (1) and (4) after your review; keep (2) and (3) denied | No (but copywriting for e-mails and social is mostly rephrase-or-refuse until then) |
| G16 | How you run the list functions (N2). Today there is NO supported path: they need the signed-in owner AND `service_role`. Options: (a) owner-only `app_*` wrappers plus a screen in the app (like the budget screen); (b) a release-authorized SQL runbook that sets the owner identity for one session | (a), as its own reviewed change | Yes for G1 / G4 / G9 (nothing can be approved until this exists); not for the release of the guard itself |
| G11 | Decision taken, for your confirmation: a NON-insurance workspace (mortgage) is back to the exact previous screen. The identifier-next-to-an-insurance-word check that this migration had added there (`jane@acme.ca about home insurance`) is removed: it was new behaviour, person tables and insurance workspaces keep their identifier checks | Confirm | No |
