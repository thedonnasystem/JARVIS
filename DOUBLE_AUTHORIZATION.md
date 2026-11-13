# Email double-authorization: reproduction and proposed fix (Nov 13, 2026)

Status: REPRODUCED locally; fix PREPARED, NOT APPLIED. It changes a permission-control trigger, so it needs the owner's explicit approval.
Reproduce: build a replica (`scripts/replica/run.sh` on a scratch DB), then `psql -d <db> -f scripts/repro/double_authorize.sql` (read-only, rolls back).

## The two paths for one send
1. Python `hq_mail.deliver_approved` calls `hq_policy.authorize(agent, "send_email", ref=<outbox id>)` -> SQL `authorize_action`. Each call writes one `action_log` row.
2. If allowed it posts the email (irreversible), then PATCHes the outbox row to `sent`.
3. That PATCH fires trigger `outbox_send_policy` (migration 20261112_permissions_v1.sql, lines 240-256), which calls `authorize_action` AGAIN for the same ref (agent sends only; `sent_by = 'owner'` is skipped).

## Measured results (local PostgreSQL replica, send_email = yellow, 20/day, mode `auto_in_caps`)
| Case | Result |
|---|---|
| One send | 2 `allow` rows in `action_log` |
| Daily allowance (limit 20) | 10 sends completed; 20 allow rows consumed |
| `approve_first`, one owner approval | Python consumes the approval; the trigger then refuses ("Approve-first mode: the owner OKs each external action"). The email was already posted; the row stays `approved` |
| Odd daily limit (5) | 2 sends completed, then the trigger refused AFTER Python allowed: 1 email posted but not marked sent |

Why: the daily counter is `count(*)` of `allow` rows for the action; the approval is single-use (`status -> used`).

## Real-world exposure today
- `hq_mail.live()` requires `system_state.mode == "live"`, but the database CHECK only allows `dry_run`, `approve_first`, `auto_in_caps`, `exceptions_only`. So the automated sender can never run today (it returns "not live"). Finding: dead gate, harmless now, must be resolved before enabling the sender.
- The trigger path still applies to any agent that marks an outbox row sent via the database. Nothing sends automatically today, so there is no production impact now.
- If the sender were enabled as written, it would (a) halve the daily allowance and (b) in `approve_first` / odd-limit cases post an email without being able to record it, risking a re-send after a later approval.

## Smallest safe correction (prepared: `ops/pending_signoff/send_policy_single_authorization.sql`)
Change only `outbox_send_policy()`. It re-checks kill switch and dry-run at mark time, then claims ONE unused `allow` row written for this very outbox row (same action, same ref, last 30 minutes, `result is null`) and marks it used. No claimable row (a direct SQL update by an agent) -> it authorizes exactly as today. `authorize_action`, `action_policy`, limits and the kill switch are unchanged.

Results on the scratch replica after the patch: 1 allow row per send; 20 sends at limit 20; approve_first mark-sent OK; odd limit 5 -> 5 sends and 0 stuck rows.
Negative tests (`scripts/repro/double_authorize_patch_negatives.sql`, 6 cases, all ok): a foreign allow row is not consumed; a stale (>30 min) row is not claimable; kill switch refuses even with a claimable row; dry-run flipped after the allow is refused at mark time; the claim works once; the claim is single-use. Mutation check: removing the ref filter, the age filter, the dry-run check or the single-use condition each fails a case.

Remaining risk of the fix: an allow row stays claimable for 30 minutes (same ref only). The posting step in Python is still before the mark; a crash between post and mark can still leave a posted-but-unmarked row (separate, pre-existing; mitigation is an idempotency key at the sender, E1 design).

## Owner decision
Approve or decline applying the patch (as a new migration registered before lockdown, with rollback to the current function text). Until then: leave the sender off (it cannot run anyway), and do not enable `mode = 'live'` handling in `hq_mail` without fixing this.
