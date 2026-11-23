# Proposal: add M7 (office OS) to the replica harness (owner decision)

Review finding 3 on PR #40 asked for M7 to be wired into `scripts/replica/run.sh`. That file is a protected judge (`ops/PROTECTED_PATHS.json`, category `judges`), and the edit was refused in the build session, so it is proposed here for the owner to apply or approve. The M7 branch does not change it.

The same proof already runs on every gate: run.sh executes every `sqltests/*.sql`, and `sqltests/office_os_check.sql` O1 does the following in one transaction:
- money fingerprint with M7, without it (rollback run twice) and re-applied;
- no M7 function, schema or drift job left;
- profiles, decisions and drift rows archived with no loss;
- M1, M2 and M6 functions unchanged;
- one export record;
- no API role on the archive;
- the manager appointment comes back after re-apply.

What run.sh would add, all additive (no assertion removed):

1. **Fingerprint around the apply.** In both money-fingerprint `if` lines, append `|| [ "$f" = "20261203_office_os_v1.sql" ]`.
2. **Rollback order.** Before every line that runs `ops/rollback_monitoring_brain.sql`, add the same line for `ops/rollback_office_os.sql` (M7 sits on M6), with the echo text `OFFICE OS ROLLBACK (before the monitoring brain rollback) FAILED`.
3. **A drill block**, placed right before `echo "monitoring + brain rollback drill: ..."`:
   1. Setup, in one psql session: a synthetic owner in `auth.users` / `app_owners`, `set_config('app.uid', ...)`, `office_os_set_manager('monopoly', 'drill manager')`, `office_os_drift_check()`.
   2. Record the live counts of profiles, managers set, decisions and drift rows; the `office_os_export` audit count; and the md5 of `authorize_action`, `reserve_spend`, `settle_spend`, `capital_snapshot`, `app_set_kill`, `fz_owner_set_office_status`, `fz_set_office_policy` and `fz_reserve_office_spend` (definition and ACL).
   3. Run `ops/rollback_office_os.sql` twice.
   4. Check that the `fz_archive` counts equal the live ones (8 profiles).
   5. Check that no `office_os_*` function, `fz_office_os` schema or `office-os-drift` cron job is left, that there is exactly one new export record, and that no API role has usage on any `fz_archive*` schema.
   6. Check that the md5 is unchanged.
   7. Re-apply `APPLY_ORDER.txt`.
   8. Check that monopoly comes back with `drill manager` / `dormant`, all 8 profiles exist, and the drift job is scheduled.
   9. Clear the manager (owner session).
   10. Run `sqltests/office_os_check.sql` and `scripts/expected_grants.py --check`.
