# Phase 1 release runbook, M1 to M7 (owner only)

One sitting, top to bottom. Nothing here has been run against production. Every step needs your authorization at the moment you run it.

Release = 7 migrations, already in `migrations/APPLY_ORDER.txt` between `20261126_ffm_run_v1.sql` (live) and the lockdown:

| # | File | Milestone | Rollback |
|---|---|---|---|
| 1 | `20261127_org_access_v1.sql` | M1 org + access | `ops/rollback_org_access.sql` |
| 2 | `20261128_office_money_v1.sql` | M2 office money | `ops/rollback_office_money.sql` |
| 3 | `20261129_approvals_kernel_v1.sql` | M3 approvals | `ops/rollback_approvals_kernel.sql` |
| 4 | `20261130_security_hardening_v1.sql` | M4 security | `ops/rollback_security_hardening.sql` |
| 5 | `20261201_shared_services_v1.sql` | M5 shared services | `ops/rollback_shared_services.sql` |
| 6 | `20261202_monitoring_brain_v1.sql` | M6 monitoring + brain | `ops/rollback_monitoring_brain.sql` |
| 7 | `20261203_office_os_v1.sql` | M7 office OS | `ops/rollback_office_os.sql` |

The lockdown and the two postlock files after them are already applied in production, so the workflow skips them. Its lockdown re-run guard sees the earlier re-run. New functions get service_role execute from production's default privileges; check V4 confirms it.

## 0. Before the window: owner decisions

1. **PR owner marker.** Approve PRs #35 to #40 in order: M1, M2, M3, M4, M5 (#39), M6 (#41), M7 (#40). For each, use an APPROVED review on its head SHA or the label `owner-ok-<full head SHA>`. Merge them bottom-up.
2. **run.sh proposal** (`ops/proposals/office_os_run_sh.md`): approve or skip. Not needed for the release; the same drill already runs in `sqltests/office_os_check.sql`.
3. **Append-only audit_log / ledger** (`ops/proposals/AUDIT_LEDGER_APPEND_ONLY.md` + `.sql`): recommended YES. Apply after V1 to V6 pass. In the same transaction it rewrites the `hq-prune` cron job (jobid 2) so it stops deleting audit history.
4. **Brain access for office identities** (changes the M1 allowlist): recommended LATER, only after Donna is active and her manager token is minted. The statement is in `docs/architecture/PHASE1_M6_MONITORING_BRAIN.md` (owner decisions).
5. **Client invoicing** (`hq_invoices.py`, off by default): recommended YES to keep it in the release, OFF until you set the Stripe test key (checklist). Add its send route to `AUDIT_PATHS.md` and `test_audit_paths.py` (protected).
7. **Billing schedule** (`ops/proposals/billing_schedule.md`): one engine line, recommended YES once Donna has her first approved plan in test mode.
6. **CI timeout 75 to 110 min** (`ops/proposals/ci_timeout_110.md`): recommended **YES**. JARVIS is a public repo, its runs bill 0 minutes, and the exhausted minutes belong to another private repo. A split job is the alternative.

## 1. Pre-checks (stop if any fails)

1. **Backup.** In Supabase: Database, then Backups. A backup from the last 24 h must exist (or PITR must be on). Note its time.
2. **Freeze activity.** Send `/kill` in Telegram. `/hq` must show kill switch ON.
3. **Kill switch and mode.** In the SQL editor (read-only):
   `select kill_switch, mode, daily_spend_cap_cents from public.system_state;`
   Expect `true | dry_run | 330`. Write down all three values.
4. **Last migration:**
   `select name from supabase_migrations.schema_migrations order by version desc limit 1;`
   Expect `ffm_run_v1` (or an earlier file listed before `20261127` in APPLY_ORDER).
5. **Money fingerprint, before.** From a machine with psql and the DB URL (Claude/Jarvis can run this with your authorization; it changes nothing and runs inside a rolled-back transaction):
   `psql "$PROD_DB_URL" -At -v ON_ERROR_STOP=1 -c begin -f sqltests/include/money_fingerprint.sql -c "select k||' '||md5(v) from pg_temp.fz_money_fp() order by k" -c rollback > fp_before.txt`
   Expect 300 or more lines.

## 2. Apply (existing release/prod-db workflow)

1. On branch `release/prod-db`, edit `.github/workflows/prod-db-release.yml`: set `START_AT: 20261127_org_access_v1.sql`. Then bring the merged M7 head's `migrations/` folder onto the branch. This is a protected file, so you make the edit.
2. Repository settings: add the secret `PROD_DB_URL`.
3. Push `release/prod-db`. The job applies files 1 to 7, one transaction each, and stops at the first error.
4. Read the job log. It must show `applied:` for all 7 files, and `kill_switch=true mode=dry_run cap=330` in Verify.
5. **Delete the `PROD_DB_URL` secret** as soon as the job finishes.

If the job stops on an error: the failed file was rolled back by its own transaction. Do not re-push. Go to section 4 for the files that did apply.

## 3. Post-apply verification (read-only, SQL editor). Every line must match.

```sql
-- V1 all seven recorded, in order
select string_agg(name, ',' order by version) from supabase_migrations.schema_migrations
 where name in ('org_access_v1','office_money_v1','approvals_kernel_v1','security_hardening_v1','shared_services_v1','monitoring_brain_v1','office_os_v1');
-- V2 controls unchanged: true | dry_run | 330 (as noted in pre-check 3)
select kill_switch, mode, daily_spend_cap_cents from public.system_state;
-- V3 8 offices, all dormant, no manager; nothing unregistered or unclassified
select count(*) filter (where kind = 'office'), count(*) filter (where kind = 'office' and status <> 'dormant') from public.fz_offices;   -- 8 | 0
select jsonb_array_length(public.office_os_status()), (select count(*) from jsonb_array_elements(public.office_os_status()) e where e->>'status' <> 'dormant' or e->>'manager' is not null);   -- 8 | 0
select count(*) from public.fz_unregistered_tables();                       -- 0
select public.backup_export_policy() -> 'unclassified';                     -- []
-- V4 the bot can call the read functions; anon / authenticated cannot call any new function
select has_function_privilege('service_role', 'public.office_os_status(text)', 'execute');   -- true
select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and (p.proname like 'fz\_%' or p.proname like 'office\_os\_%')
   and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));   -- 0
-- V5 security and health
select (public.fz_security_report() -> 'chain' ->> 'ok');                   -- true
select public.fz_health_report() ->> 'overall';                             -- note it; if bad, read /health before /resume (warn is expected: kill switch on)
-- V6 office money at $0
select count(*) from public.fz_office_money where available_cents <> 0;     -- 0
```

Then the money fingerprint after:
`psql "$PROD_DB_URL" -At -v ON_ERROR_STOP=1 -c begin -f sqltests/include/money_fingerprint.sql -c "select k||' '||md5(v) from pg_temp.fz_money_fp() order by k" -c rollback > fp_after.txt && diff fp_before.txt fp_after.txt`
It must print nothing. Then send `/resume` in Telegram, and `/hq` must show kill switch OFF. Check `/offices`, `/approvals`, `/security`, `/services`, `/health`, `/office donna`.

## 4. Rollback (only if V1 to V6 fail or something breaks)

Freeze first (`/kill`). Run newest first, each with psql. Each file is one transaction and idempotent. Run only the files whose migration was applied.
`for f in office_os monitoring_brain shared_services security_hardening approvals_kernel office_money org_access; do psql "$PROD_DB_URL" -v ON_ERROR_STOP=1 -f ops/rollback_$f.sql || break; done`

That order is M7, M6, M5, M4, M3, M2, M1. Each rollback archives its rows into `fz_archive*` (no API access) and writes one export row to `audit_log`. Then remove the rolled-back names from `supabase_migrations.schema_migrations` (owner SQL), re-run the fingerprint diff against `fp_before.txt`, and `/resume`. Last resort: restore the backup from pre-check 1.

## 5. Activate Donna (after V1 to V6 pass; one office at a time)

SQL editor, each statement with your app user id:
`begin; select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true); select ...; commit;`

1. `select public.office_os_set_manager('donna', 'Donna lead');`
2. `select public.office_os_activate('donna');` Copy the `nonce` from the result. It is shown only to you; a Telegram tap does nothing.
3. `select public.office_os_decide('donna', '<nonce>', true);`
4. `select public.office_os_activate('donna');` The status is now `active`, and `office_blocks` lists `deceptive_communication`.
5. Money only on need: `select public.fz_owner_allocate('donna', <cents>, 'why');` There is no fixed budget.
6. Check with `/office donna` in Telegram: ACTIVE, manager set, no DRIFT line.

Next offices, same steps, only after Donna is running: Wolf Squad, then FF Marketing. Connections: `ops/CONNECT_SESSION_CHECKLIST.md`.
