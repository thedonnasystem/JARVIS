# Backup and disaster recovery (Phase 1.5)

Status: **built and drilled locally on synthetic data; NOT yet running against production.** Nothing here is proven for real company data until the "Go-live proof" steps at the bottom pass.

## What is protected
Every table in `public` except `push_config` and `push_subscriptions` (private keys): missions/tasks, leads, outbox drafts, company memory, ledger, `llm_calls` spend records, audit log, agents, ventures, etc. Plus a schema snapshot (`public.backup_schema()`): tables/columns, constraints, indexes, triggers, **function bodies**, views, RLS policies, table grants, function ACLs, sequences, enums, domains, extensions, migration ledger, cron jobs (recorded).

## Final review answers (Nov 12, from read-only queries on production + tests)
**1. Tables not backed up (55 tables, 53 backed up).** `push_config` (1 row: the web-push VAPID public/PRIVATE key and subject) and `push_subscriptions` (0 rows today: endpoints and keys of subscribed devices). They are excluded because they are secrets/credentials, not business data. They hold no business, financial, mission, agent, memory or audit data. Impact on recovery: none on any company record. After a disaster, web push stops until new VAPID keys are generated and the app is re-subscribed (Telegram, the primary channel, is unaffected; the bot already treats push as optional and fails silent). Decision: keep excluded. If you want them included, they would be written into the already-encrypted file; the cost is that one more copy of a private key exists off-site.
**2. Snapshot consistency.** Primary method: `public.backup_snapshot()` returns every table and the schema from ONE SQL statement. PostgreSQL gives a single statement one snapshot, so all tables and the schema are mutually consistent (a transaction that touched several tables appears in all of them or none). Proven in the drill: 25 snapshots taken while 2,419 paired two-table transactions committed, 0 inconsistent. Sequence positions are read at the end of the statement so they are never behind the saved rows. Fallback (if the function is missing, errors or times out): the two-read method, which only proves nothing changed while reading and says so in the manifest (`snapshot_unavailable` shows why). Remaining risks: (a) the snapshot is consistent as of one instant, not "business-complete" (a half-finished multi-step workflow in the application layer is captured mid-flight, same as any crash); (b) the function builds one JSON document in database memory (about 1 MB today; at roughly 100-200 MB switch to per-table streaming); (c) the fallback path has the earlier limitations.
**3. Restore security.** Nothing secret is ever sent to chat or Telegram. Procedure: `ops/restore_local.sh` (Docker required). It starts a throwaway PostgreSQL 17.11 bound to 127.0.0.1, asks for `BACKUP_KEY` (and the read-only B2 key) at HIDDEN prompts, restores, verifies, writes `restore_report_*.json` and `restore_fingerprint_*.txt` (neither contains a secret; checked), then destroys the container. Independent verification: run `ops/table_fingerprint.sql` on production (read-only SELECT in the Supabase SQL editor) and diff against the fingerprint file; only tables that change constantly (audit_log, llm_calls, owner_messages, system_state) may differ.
**4. Database metadata.** Production check: all objects owned by `postgres`; no column-level ACLs; no comments; schema ACL is the standard Supabase one. Effect on recovery of the omissions: owners and column ACLs: none today (every object is owned by `postgres`, which is who the restore runs as). The snapshot now also records the schema ACL and all comments and replays them (verified in the drill), and counts column ACLs and non-default owners; if either becomes non-zero the restore report lists it under `not_restored` so it cannot be silently lost.

## Design
- Runs inside the Railway bot (`hq_backup.run()` from the engine tick), because only Railway holds the Supabase service key.
- Output: `hq-<timestamp>.tar.gz.enc` (Fernet-encrypted gzip tar: `manifest.json` with per-table sha256 and row counts, `schema.json`, `data/<table>.jsonl`) and a plain `.sha256` sidecar.
- Before upload the bot decrypts its own file and recounts/rehashes every table. Upload goes to Backblaze B2 with a SHA-1 header that B2 verifies; the bot also checks B2's acknowledgement.
- Secrets: `BACKUP_KEY`, `BACKUP_PUT_URL`, `BACKUP_AUTH` live only in Railway env vars. Never in GitHub, logs, Telegram or audit rows (tests assert this).
- Bot key is **write+list only** (cannot read or delete). Restore uses a separate read key.

## Schedule and retention
- Daily, window 02:00-05:00 America/Toronto, at most once per 20 h. A failure messages the owner once. `/backup now` forces a run.
- Retention: B2 bucket lifecycle rule, proposed 90 days ("days from uploading to hiding" = 90, "hiding to deleting" = 1). Moe sets it in the B2 console (bucket-scoped keys cannot change it). Until set, files are kept forever (free tier 10 GB; current data is far smaller).

## One-time setup (Moe)
Exact click-by-click steps: **BACKUP_SETUP_OWNER.md**. Summary:
1. Create a free Backblaze B2 account (email only; stop if a card is demanded). Create a **private** bucket.
2. Add the lifecycle rule above.
3. Create two application keys scoped to that bucket: **A** listFiles+writeFiles (bot), **B** listFiles+readFiles (restore).
4. Generate the encryption key yourself and store it offline in a password manager: `python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"`. Losing it makes every backup unreadable.
5. In Railway set `BACKUP_KEY`, `BACKUP_PUT_URL=b2://<bucketId>/hq`, `BACKUP_AUTH=<keyIdA>:<appKeyA>`.
6. Approve: merge/deploy of this branch and the read-only migration `20261113_backup_schema_v1.sql`.

## Recovery procedure
Restore only into a **new** Postgres (never over production without a deliberate decision).
1. Set `BACKUP_KEY` and (for B2) `RESTORE_B2_AUTH=<keyIdB>:<appKeyB>`, `RESTORE_B2_BUCKET_ID`, `RESTORE_B2_PREFIX=hq`.
2. `python ops/restore_backup.py --target postgresql://postgres:...@localhost:5432/restore_x --b2-latest [--wipe] [--expect-sha256 <hash from /backup>]` (or set `RESTORE_DB_URL`; `--file` for a local copy, `--list` to list, `--b2-name <file>` for an older backup). Exit codes: 0 clean pass, 1 verification failed, 2 refused/bad input, 3 unexpected error, 4 restored but foreign-key violations exist.
3. The tool checks sidecar/expected checksum, decrypts, verifies the manifest, rebuilds roles/extensions/types/functions/tables, loads rows, restores constraints, indexes, triggers, views, RLS, policies, grants, then compares every row and the full schema snapshot, and runs smoke tests (capital_mode(); spend gateway refuses with kill switch). Exit 0 only if everything matches.
4. The tool refuses any target that is not an explicitly local scratch DB: host must be written out (localhost/127.0.0.1/::1/socket dir), name must start `restore_`, `drill_`, `scratch_` or `tmp`, `hostaddr`/`service`/`options` are rejected, `PGHOST`-style environment redirects are cleared, and after connecting it refuses a server that looks like Supabase (auth/storage/realtime schemas or Supabase roles) before dropping anything. **Run it inside a throwaway container or VM**: a backup file is executable SQL (function bodies, defaults), so a backup produced by a compromised bot could run arbitrary SQL as the restoring user. Take `--expect-sha256` from the `/backup` audit entry, not from the bucket. To restore to a new hosted project, run it against a local scratch DB first, then `pg_dump` that into the new project by hand.
5. After a real recovery: re-apply `push_config`, re-set Supabase service keys, re-create cron jobs and default privileges (recorded in the snapshot, not replayed), and keep the kill switch ON until verified.

## Evidence so far (synthetic data, local; NOT production proof)
`bash scripts/backup_drill.sh` (43 checks, run on PostgreSQL 17.11 and on 16): real `hq_backup.run()` -> fake B2 -> `restore_backup.py` (read-only key) -> scratch Postgres. 53 tables / 614 rows identical by independent per-table hash; functions (100), triggers, indexes, constraints, grants, views identical; smoke tests pass. Negative controls: corrupted object, wrong key, production-looking host, real-looking DB name, non-empty target, wrong expected checksum, damaged rows, damaged schema. Retention/recovery selection: newest chosen; falls back to the next surviving backup when the newest is gone; older backup restorable by name; empty bucket fails loudly. Review-driven checks: restore guard bypass attempts (hostaddr, empty host + PGHOST, service=, a scratch-named database that looks like Supabase is refused and left untouched), sequences continue after the data, a view keeps `security_invoker`, a foreign key that depends on a plain unique index restores. Unit tests: `test_hq_backup.py` (51, all mutation-checked), `/backup` command tests; consistency, preflight, retry/backoff and no-secret-leak tests included. CI runs the drill.
Read-only live checks done (no writes): live DB is PostgreSQL 17.11, 16 MB, 53 backed-up tables, about 1,138 rows (so each backup is well under 1 MB). `ops/table_fingerprint.sql` runs unchanged on live and on a restored copy for the final production comparison.

## Independent review (fresh agent, read-only) and what changed
Found 10 defects; all fixed and regression-tested: real Backblaze upload hosts (`*.backblaze.com` pods) were rejected by the host allowlist; restore guard could be bypassed with `hostaddr`/empty host/`service`; sequences could be older than the data; a transient schema error silently downgraded the backup to a stale table list; failure caused a retry every 5 minutes plus repeated messages (now 90-minute gap, 3 tries per night, one message per day, single-run lock); a generic URL without `{name}` would overwrite the backup with its checksum file; no retry on network errors / expired tokens; paging stopped at the first short page (now until an empty page); a failed notification could turn a good backup into a reported failure; plus a plain unique index used by a foreign key was missing from the snapshot, and view options (`security_invoker`) were not captured.

## Limitations (be honest)
- Not yet proven against real Backblaze or real PostgREST output, nor on production data. The drill source is the replica with synthetic data.
- The REST API cannot give one database transaction. Safeguard: every table is read twice and the backup is accepted only if both full reads are byte-identical (retried up to 3 times); otherwise it is saved but flagged `consistent: false` and you are told. It cannot detect a change that happens and reverts between reads. Restore also validates foreign keys and warns.
- Backup/restore drill passes on PostgreSQL 17.11 (x86_64, same version as production; production runs aarch64) and on 16.
- Cron jobs and default privileges for future objects are recorded, not replayed. Unavailable extensions are skipped with a note.
- Not replayed by the restore: object owners other than `postgres`, column-level ACLs (both counted in the snapshot and flagged in the report if present; zero in production today), window functions, reloptions on tables. Captured and replayed: schema ACL, comments, table/function/sequence grants, view options. The claim is "identical for what is captured", not "everything".
- Row verification compares numbers by value (30.00 equals 30); exact scale is protected by the backup writing decimals exactly, and by the independent per-table text hash in the drill and `ops/table_fingerprint.sql` on production.
- Foreign-key violations in the backed-up data do not block the restore but give exit code 4 (PASS_WITH_WARNINGS).
- Memory: with the snapshot method the database is built as one JSON document inside Postgres, then held in the bot's RAM about 3 times (fine at 16 MB; revisit past roughly 100-200 MB). The fallback two-read method cannot detect an update that changes and reverts between its two reads.
- Retention depends on the B2 lifecycle rule you set. Supabase free plan has no PITR or downloadable backups, so this is the only recovery path.
- If the bot or Railway is down, no backup runs; `/backup` shows the age of the last good one and the heartbeat alert covers the bot.

## Go-live proof (required before claiming production recovery works)
1. After setup and approvals, `/backup now`.
2. Claude lists the object with key B, checks its size and sha256 against the sidecar and `/backup`.
3. Restore into a throwaway local database with `ops/restore_local.sh` (you run it; the key never goes to chat), then compare the report and fingerprint with production. Claude never needs your keys.
4. Compare restored row counts and content hashes with live read-only fingerprints. Only if all pass is production recovery proven.
