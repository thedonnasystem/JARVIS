# Operational-risk remediation plans (2026-11-13)
Rule used throughout: **controlled deployment** = the Sprint 1-2 release going live with dry_run, kill switch, all caps and default-deny untouched and no external action possible. **Live operations** = anything that sends, spends beyond today's engine, or lets an agent act externally. None of the five items below blocks controlled deployment. All five block live operations.
Why none blocks deployment: live email is impossible today (`hq_mail.live()` needs mode `live`, which the `system_state` CHECK forbids); Make/n8n need owner approval and respect the kill switch; the protected hardenings are latent (dry-run and caps stop them); `/build` exposure already exists in production today and the release only reduces it.

| # | Risk | Before controlled deployment | Before live operations |
|---|---|---|---|
| R-A | Caller-supplied owner identity | Nothing. Keep the service key only in Railway; rotate it if any doubt. | Plan A |
| R-B | F4: `/build` shares a uid with the bot | Nothing (release already mitigates). Optional: do not use `/build` until fixed. | Plan B |
| R-C | Email claim recovery / duplicate send | Nothing (no send path is live). | Plan C |
| R-D | Six protected send/spend hardenings + send-policy patch | Nothing (latent). | Plan D |
| R-E | Make/n8n dry-run enforcement | Nothing (approval + kill switch already apply). | Plan E |

## Plan A: owner identity is a caller-supplied string (`granted_by like 'owner%'`, `sent_by='owner'`, approvals decided by whoever holds the service key)
Goal: an engine bug or leaked key cannot approve its own actions.
1. Split database roles: `hq_engine` (the bot) gets no UPDATE/INSERT on `approval_requests` decisions, `action_policy`, `capital_policy`, `system_state.kill_switch/mode`; only a separate `hq_owner` path (the PWA through `is_app_owner()` JWT, and the Telegram handler through one SECURITY DEFINER function that checks the Telegram owner id server-side) can write them.
2. Approvals carry an HMAC over (action, ref, cents, expiry) made with a secret that only the owner path holds; `authorize_action` verifies it. A forged `owner` string then proves nothing.
3. Tests: engine role cannot decide approvals (replica, negative tests); rollback script; mutation test.
Effort 2-3 days. Protected-control change: separate owner approval, applied via migration with md5 drift expected-list update. Verify: `ops/verify_post_release.sql` row 5 changes only by the intended functions.

## Plan B: F4 process isolation for `/build`
1. Run build sessions as a separate unprivileged uid (or a throwaway container) with an empty environment, `HOME` in the workspace, and no read access to `/proc/<bot pid>` (hidepid mount, or a PID namespace).
2. Pass the model key through a pipe/file descriptor, not the environment, or use a scoped key with its own spend cap.
3. Until then: leave `/build` unused, or add a Railway variable switch that disables it (small code change, no protected control).
Effort 1-2 days; needs Railway service change (owner/infra). Verify: from inside a build session `cat /proc/*/environ` and `printenv` show no secrets (test, not just the string-gate).

## Plan C: email claim recovery and duplicate-send handling (`hq_mail.py`)
1. Send a provider idempotency key (the outbox row id) so a retried POST cannot create a second email.
2. Treat a timeout/OSError after the request left as AMBIGUOUS: keep the claim, mark the row `unknown`, alert the owner (Needs You), never auto-retry (same rule as the E1 design for tiers C-E).
3. Reaper: an `approved` row with `sent_at` older than 10 minutes and no `sent` status raises an owner alert and an audit row.
4. Fix the double authorization (Plan D item) at the same time so a send consumes one allowance.
5. Tests: kill between claim and mark; timeout after accept; 2 workers; replay.
Effort 1-2 days. Blocks the first live email (not deployment).

## Plan D: protected hardenings (`ops/pending_signoff/`)
Contents: `send_policy_single_authorization.sql` (double authorization); `audit_spend_send_hardening.sql` (F2 owner mark-sent bypass, F3 sent->draft, F7 negative LLM amounts and re-settle, F8 unbounded `settle_spend`, F9 green label in dry-run, F12 API role inserting `action_policy` rows).
Steps: (1) owner reviews the two files and the sqltests; (2) write `ops/rollback_signoff_hardening.sql` (restore the exact current bodies from `ops/live_function_md5_20261113.txt`-matching text) and test apply -> rollback -> reapply on a replica; (3) F2 also needs the `hq_commands.mark_sent` change (calls `owner_mark_sent`); (4) apply via `apply_migration` one file at a time; (5) re-run `verify_post_release.sql`: row 5 must now FAIL in exactly the changed functions and nowhere else, then update the pinned md5 once the owner accepts. Effort under 1 day after approval. Hard rule: no limit, cap, kill switch or default-deny value changes.

## Plan E: Make/n8n dry-run enforcement
1. In the trigger functions, refuse unless `system_state.mode` allows external actions AND a per-call owner approval exists (Make already needs one; add n8n).
2. Since `live()` is dead, this means both stay refused: correct until the owner designs the live-enable path (decision B2 in OWNER_DECISIONS.md).
3. Tests: dry_run refuses; kill switch refuses; approval-less refuses.
Effort under half a day. Blocks enabling Make/n8n (already disabled in practice).

## What this is not
No remediation above is started. Each is a separate owner approval; none changes a limit.
