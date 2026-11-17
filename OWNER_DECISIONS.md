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

## G. Backup redaction, round 8 (PR #16; details: `DATA_CLASSIFICATION_AND_BACKUP_POLICY.md` section 2, rule 15)
| # | Decision | Default | Blocks? |
|---|---|---|---|
| G1 | Accepted residuals for 3-4 letter client names: not redacted behind a 4+ letter prefix (`xxxxkhan`), before an unlisted suffix (`khanabc`), or when the glued form is an ordinary word in lower case, sentence-initial or capitals (`kings`, `Kings of the road`; `call the Kings` mid-sentence IS redacted); 2-letter names alone | Accept (closing them means blanking more columns) | No, but it is a stated limit of "no client data off-site" |
| G2 | Identifiers that hold a known client name are exported as keyed pseudonyms (`n1a2b3c4d5e-roofing`); a restored database shows the pseudonym, not the original slug. System slugs (`jarvis`, `idea-lab`, seeded ventures) are kept | Accept | No |
| G3 | `missions.objective` is no longer exported (blank after a restore), because the venture description is copied into it | Accept | No |
| G4 | Event trigger `ffm_backup_acl_sweep`: if the hosted database role cannot create it, the migration only warns. The preflight and the ACL manifest check then FAIL on purpose | Have the platform admin create it before activation | Yes, blocks backup activation |
| G5 | `BACKUP_GATEWAY_APIKEY` = the project's anon / publishable key (sent as `apikey`; the reader token stays in `Authorization`). Unverified against the real project | Set it, then run `/backup check` once | Yes, blocks backup activation until one check passes |
| G6 | Post-lockdown (`postlock`) migrations: the lint now refuses the known ways to hand privileges out, but it is a tripwire only | Every postlock file gets a human review before it is applied; you name the reviewer | No (process decision) |
| G7 | 12 new hash indexes on the client-name / email / phone columns (bounded write cost). Building them blocks writes to those tables briefly | Apply in a quiet minute | No |
| G8 | `ffm_phone_suppressions.phone` (opted-out numbers in plain text, consent PR) is NOT used as a redaction source; such a number is removed from exports by the generic phone patterns only | Accept, or ask for it to become a source (needs a migration ordered after the consent one) | No |
| G9 | A backup FAILS (nothing uploaded, you are told once a day) when the consent tables exist and the opt-out list cannot be exported; "suppression key not set yet" is not a failure | Accept | No, but set the suppression key before relying on a restore |

## What I need from you, in order
1. Run `ops/preflight_live.sql`, `ops/verify_live.sql`, `ops/preflight_sprint12.sql` in the Supabase SQL editor and send me the result tables (no secrets in them), or reconnect the Supabase connector.
2. Say "approve A1-A3" (or each separately).
3. Optionally decide B1/B3 in the same message.
