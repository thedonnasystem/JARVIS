# Fendezy HQ: development progress (resumable)

Rule: every entry names a branch, commit, tests run and the exact next task. Planned is not done.

## Base
- Branch `integration/sprint1` @ 37c60e2 (local; push pending while GitHub returned 503 on Nov 13 08:00 ET). Draft PRs: #2 (backup), #3 (sprint 1). Nothing merged, deployed, migrated or activated.
- Gate: `scripts/gate.sh --strict` (7/7 on PG16 and PG17.11 at 37c60e2). Local DBs: PG16 `localhost:5432`, PG17.11 Docker `pg17` at `localhost:5433`, user postgres, password pw (scratch only).

## Workday shift (Nov 13) streams, all branched from 37c60e2
| Stream | Branch | Owns (files) | Status |
|---|---|---|---|
| P1 Mission A4/A5/A6 | stream/mission2 | hq_missions.py, hq_engine.py, tests, MISSION_ENGINE.md, migration `20261115_mission_*` | started |
| P2 Venture B5 etc. | stream/venture2 | hq_ventures.py, hq_mail.py, new hq_deals.py, migration `20261115_venture_*`, VENTURE_FACTORY.md | started |
| P3 HQ interface C2/D1 | stream/hq-ui | webapp/, new hq_inbox.py, migration `20261115_inbox_*` | started |
| P4 E1 design | stream/e1-design | docs only: E1_AGENT_ACTIONS.md | started |

hq_commands.py is shared: streams add commands only through small, clearly delimited blocks; integration resolves conflicts.

## Checkpoint (Nov 13, mid-shift)
- `integration/sprint2` = sprint1 + stream/mission2 (A4 evidence check, A5 tolerant parse + one repair, A6 due dates + opt-in recurrence) + stream/venture2 (B5 deals, replies, CASL suppression, venture config, funnel) + stream/e1-design (E1_AGENT_ACTIONS.md). Both streams independently reviewed; blockers/majors fixed and re-tested (mission2 d09acec, venture2 fe3da74).
- Gate: `scripts/gate.sh --strict` 7/7 on PG16 and PG17.11 (unit 449+, script tests, lint, bundle, replica incl. rollback drill, manifest, backup drill).
- stream/hq-ui merged (C2 PWA smoke tests + RPC drift checker, D1 `needs_you()` inbox, `/needs`, brief line, PWA Inbox tab). Reviewed; 5 minors fixed (c0e58f4).
- FINAL for the shift: `integration/sprint2` gate 9/9 on PG16 and PG17.11, 536 repo tests, 62 script tests, 27 JS tests.
- Owner sign-off pending: open `app_needs_you()` to the signed-in owner (edits applied lockdown list + lint allowlist); exact steps in `ops/pending_signoff/inbox_open_app_needs_you.txt`. Until then the PWA Inbox shows a reduced fallback.
- To verify in replica (sprint 3): one email send authorizes twice (Python hq_mail + outbox_send_policy trigger), each allow writes an action_log row and the daily limit counts them, so send_email/day is likely halved. Touches protected permission controls: owner decision.
- Known limits: evidence check proves a cited source appears in mission output, not that it supports the claim; a lone decorated `## Verified - yes` line counts when it is the only label; suppression list has no unsuppress path (owner decision).
- Refactor candidate (not started): REST helpers (_q/_get/_rpc/_patch) duplicated across up to 12 modules; extract hq_db.py after streams settle.

## Next task
Sprint 3 candidates: hq_db.py REST-helper consolidation; wire offer/CTA into the draft prompt (hq_engine); schedule weekly digest; fix double authorize (needs owner OK); E1a read-only tools (needs E1 design approval); real mission dry-run after owner authorization.

## Blockers / owner actions
See SPRINT report; none new yet.

## Checkpoint 2026-11-13 (hardening closed)
Sprint 2 hardening items 1-7 done. Code head f10228ee; PR #4 head 81a760ed (docs-only on top). CI green. PRODUCTION_APPROVAL_PACKAGE.md independently verified (5 corrections applied). Next: wait for owner authorization; Sprint 3 not started.
