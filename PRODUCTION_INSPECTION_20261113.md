# Production read-only inspection, 2026-11-13 (Supabase `ihxzvpwbqydqtblvazbq`)
Method: Supabase connector, `list_migrations` and SELECT-only queries (no writes, no temp tables, no migrations). Lead addresses were counted, never read out.
| Check | Expected | Actual | Result |
|---|---|---|---|
| Migration ledger | through `lockdown_v1` (20261112222010), none of the 6 pending | last three: `phase1_repair_v1`, `mission_guard_v1`, `lockdown_v1`; none pending present | MATCH |
| `ops/preflight_sprint12.sql` (19-name, 4-table version) | all rows BEFORE-OK | all 9 rows BEFORE-OK | MATCH |
| Phase 1 functions | 8 of 8 | 8 | MATCH |
| Function count | 99 | 99 | MATCH |
| Security rows (exec_leak, public_exec, service_missing, table_grants_anon_auth, rls_off) | none | none x5 | MATCH |
| Mode / pause / kill / focus | dry_run / kill false / focus off | `dry_run / pause=api_credits / kill=false / focus=off` | MATCH (pause is the known credits pause; unpausing is an owner action) |
| Outbox triggers | `outbox_rules`, `outbox_send_policy` | both present | MATCH |
| Emails ever sent / send allowances used | 0 / 0 | 0 sent of 19 outbox rows; 0 `send_email allow` rows | MATCH |
| Leads: strict address rule impact | none rejected | 19 with email, 0 fail the strict form; 19 do-not-contact, 19 with consent_basis | NO IMPACT |
Not run: the function-md5 drift comparison against `ops/live_functions_baseline_20261112.txt` (needs the baseline diffed locally; `ops/verify_live.sql` produces it) and `ops/preflight_live.sql` (writes a temp table). Mismatches found: none. Limitation: a point-in-time read; production can change before the owner approves, so re-run `ops/preflight_sprint12.sql` immediately before applying.
