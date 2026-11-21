# FENDEZY GROUP Phase 1, M4: Audit and security hardening

Branch `build/p1-m4-security`, stacked on `build/p1-m3-approvals`. Migration `migrations/20261130_security_hardening_v1.sql`, rollback `ops/rollback_security_hardening.sql`, proof `sqltests/security_hardening_check.sql`, `scripts/replica/token_drill.sql` and `test_hq_security.py`, runbook `ops/TOKEN_ROTATION_RUNBOOK.md`.

## 1. What was built

| Piece | What it is |
|---|---|
| Audit hash chain | `fz_audit_chain` (new, append-only): one row per `audit_log` row, `row_hash = sha256(id, at, actor, action, target, detail)`, `chain_hash = sha256(previous chain_hash, row_hash)`. Built by `fz_audit_chain_extend()` (cron, every 15 min) in id order, stopping at the first row younger than 5 minutes, so a transaction still committing is not mistaken for an insertion. **`audit_log` and its triggers are not modified.** |
| Verify | `fz_audit_verify()` recomputes everything and names each break: `changed` (an audit row was edited), `deleted` (a chained row is gone), `chain_edited` (the chain table itself was edited), `unchained` (a row below the head that is not in the chain: inserted later with an old id). It returns the head hash. |
| Security report | `fz_security_report()` (read-only; service and owner; scoped roles refused even if granted by mistake). It covers: privileged grants (writes, column writes, anon / authenticated reads, SECURITY DEFINER execution for anon, authenticated, the three scoped roles and backup_reader; superuser / bypassrls / createrole / createdb on API roles; API roles holding service_role / postgres), each marked baseline / alerted / acknowledged / NEW; SECURITY DEFINER functions without a pinned search_path; public tables with RLS off; identities; registered tokens expiring within 14 days (or expired); the chain status; the last alerts. Telegram `/security` (owner chat only, read-only). |
| Token registry | `fz_token_registry`: the owner records each minted token's jti and expiry (`fz_owner_register_token`, owner only). The token itself is never stored. |
| Watch + alerts | `fz_security_watch()` (cron, every 15 min): extends and verifies the chain, compares privileged items with the baseline (taken on its first run), and on a chain break or a **new** privileged item writes **one** alert per finding: `fz_security_alerts` (append-only) plus one Telegram message to the owner (`owner_messages`, kind `health`: never `emergency`, so it can never trigger a call; nothing external). `fz_owner_ack_security(item)` (owner only) marks an expected grant as acknowledged. |
| Runbook + drill | `ops/TOKEN_ROTATION_RUNBOOK.md` (rotate, void, leak, JWT secret leak). `scripts/replica/token_drill.sql` executes each step: rotate (old token refused at once), void, the bot revokes on leak and can never re-activate, the owner re-activates with a new jti, expiry shows in the report, every step is audited. |

## 2. Why this architecture

- **A side chain, not a change to audit_log.** audit_log is protected and many functions write to it; a trigger there would add a write to every audited action. A cron-built chain changes nothing in the write path. It is tamper-**evident** (an edit, deletion or late insertion is detected and alerted), not tamper-proof: a superuser can still rewrite both tables. To make that evident too, the owner can keep the head hash outside the database (it is in every verify and report).
- **Contiguous prefix, 5-minute lag.** Chaining in id order and stopping at the first young row means a long transaction is chained when it commits, instead of later showing as `unchained`.
- **Baseline on first run, not at apply.** In production the post-lockdown grants already exist; on a fresh database they are created after this migration. Taking the baseline on the first watch run avoids alerting on the system's own reviewed grants. The trade-off: a grant made between apply and the first run (at most 15 minutes) is baselined silently. Owner step 2 covers that.
- **Alerts are owner_messages of kind `health`.** That is the owner's own Telegram chat, via the existing delivery. Kind `emergency` is avoided because the emergency-call path keys on it.
- **Everything is owner or service path.** No scoped role executes any M4 function or reads any M4 table (tested for valid, dormant and forged tokens, and with a mistaken grant).

## 3. Classification

Four new group tables, all `confidential`, no scoped access, registered in `fz_table_registry`: `fz_audit_chain`, `fz_security_baseline`, `fz_security_alerts`, `fz_token_registry`. Backup: `secret` (not in the off-site export; after a restore the chain is rebuilt from the restored audit_log and the baseline is re-taken). `backup_classification()` is the M2 text plus these four rows (protected object: owner approval).

## 4. Test evidence

`sqltests/security_hardening_check.sql` (replica step, and again after the rollback drill):
- **S1** money controls unchanged: fingerprint identical with M4, after rolling it back twice, and after re-applying it; `scripts/replica/run.sh` also compares right before vs right after the migration.
- **S2** the chain: aged rows are chained, a fresh row waits, verify is clean, extend is idempotent. Each tamper is detected: a changed row, a deleted row, an edited chain, a late insert below the head. The chain is append-only even for the table owner; the bot cannot write it; no scoped or API role reads it or runs an M4 function.
- **S3** the watch: the first run takes the baseline (no alert); a new table grant and a definer function opened to `authenticated` each alert the owner's Telegram exactly once; a tampered audit row alerts exactly once; no security alert is of kind `emergency`; alerts are append-only; scoped roles cannot run the watch.
- **S4** the report lists a definer function without search_path, an RLS-off table, a token expiring in 3 days (not the one in 90), the active identity, the broken chain and the alerts; the bot cannot register a token; scoped / anon / authenticated are refused, and a scoped role with a mistaken grant is refused by the function itself.
- **S5** acknowledge is owner only; the bot cannot write the baseline.
- **S6** nothing unregistered or unclassified; the money and audit tables keep exactly their triggers; the watch is scheduled.
- **S7** on the final state the rollback changes no money control and archives every chain / alert / baseline / token row.
- The token rotation drill (6 steps, see section 1) passes in the replica.
- Mutation-checked: see the report (16 mutants).
- `test_hq_security.py`: 4 unit tests (formatting, clean chain / not installed, the module never writes or changes a grant, `/security` registered and owner-only).

## 5. Risks

- **Tamper-evident, not tamper-proof** against a database superuser (see 2). Keep the head hash outside the database for the strongest guarantee.
- **The baseline is taken on the first run** (see 2).
- **Token expiry is only known for registered tokens.** The minter does not register them automatically (it never talks to the database).
- **A transaction running longer than 5 minutes** that writes an audit row could show as `unchained` (a false alarm; the alert says what to check).
- Known from M2 / M3 (protected, unchanged): `authorize_action` matches approvals by action, ref and amount, not office; the service key can approve `approval_requests`.

## 6. Rollback

`psql -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql` (one transaction, idempotent, **first** of the Phase 1 rollbacks, before the M3 one). It writes the chain head, the verify result and the counts into one audit_log row, unschedules the watch, **archives** the four tables into schema `fz_archive` (no API privileges; rows intact), drops the M4 functions and restores `backup_classification()` to the exact M2 text. Nothing in audit_log changes. The replica drill runs it twice, checks that no row is lost, M4 is gone and the classification is the M2 text byte for byte, then re-applies everything and re-runs the sqltest.

## 7. Owner actions

1. Approve and apply M1 to M4 in order (release window).
2. After applying, run `select public.fz_security_watch();` once yourself and read `/security`. That run becomes the baseline; acknowledge anything you recognise with `fz_owner_ack_security`.
3. Register each scoped token's expiry when you mint it (runbook).
4. Optional: keep the chain head hash (in `/security`) somewhere outside the database every week or so.

## 8. Next milestone (recommended)

**M5: First live office.** Activate and fund one office, install its token, turn on `FZ_OFFICE_SPEND_GATE`, move Jarvis's reads to its scoped token, and add app buttons for the owner decisions. Also anchor the audit chain head outside the database automatically: a weekly owner message with the head hash.
