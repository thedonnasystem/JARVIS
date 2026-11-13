# Backup and disaster recovery (Phase 1.5)

Status: **built and drilled locally on synthetic data; NOT yet running against production.** Nothing here is proven for real company data until the "Go-live proof" steps at the bottom pass.

## What is protected
Every table in `public` except `push_config` and `push_subscriptions` (private keys): missions/tasks, leads, outbox drafts, company memory, ledger, `llm_calls` spend records, audit log, agents, ventures, etc. Plus a schema snapshot (`public.backup_schema()`): tables/columns, constraints, indexes, triggers, **function bodies**, views, RLS policies, table grants, function ACLs, sequences, enums, domains, extensions, migration ledger, cron jobs (recorded).

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
1. Create a free Backblaze B2 account (email only; stop if a card is demanded). Create a **private** bucket.
2. Add the lifecycle rule above.
3. Create two application keys scoped to that bucket: **A** listFiles+writeFiles (bot), **B** listFiles+readFiles (restore).
4. Generate the encryption key yourself and store it offline in a password manager: `python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"`. Losing it makes every backup unreadable.
5. In Railway set `BACKUP_KEY`, `BACKUP_PUT_URL=b2://<bucketId>/hq`, `BACKUP_AUTH=<keyIdA>:<appKeyA>`.
6. Approve: merge/deploy of this branch and the read-only migration `20261113_backup_schema_v1.sql`.

## Recovery procedure
Restore only into a **new** Postgres (never over production without a deliberate decision).
1. Set `BACKUP_KEY` and (for B2) `RESTORE_B2_AUTH=<keyIdB>:<appKeyB>`, `RESTORE_B2_BUCKET_ID`, `RESTORE_B2_PREFIX=hq`.
2. `python ops/restore_backup.py --dsn postgresql://...@localhost/restore_x --b2-latest [--expect-sha256 <hash from /backup>]` (`--file` for a local copy, `--list` to list).
3. The tool checks sidecar/expected checksum, decrypts, verifies the manifest, rebuilds roles/extensions/types/functions/tables, loads rows, restores constraints, indexes, triggers, views, RLS, policies, grants, then compares every row and the full schema snapshot, and runs smoke tests (capital_mode(); spend gateway refuses with kill switch). Exit 0 only if everything matches.
4. The tool refuses any target that is not a local scratch DB (name must start `restore_`, `drill_`, `scratch_` or `tmp`). To restore to a new hosted project, run it against a local scratch DB first, then `pg_dump` that into the new project by hand.
5. After a real recovery: re-apply `push_config`, re-set Supabase service keys, re-create cron jobs and default privileges (recorded in the snapshot, not replayed), and keep the kill switch ON until verified.

## Evidence so far (synthetic, local)
`bash scripts/backup_drill.sh`: 31/31 checks. Real `hq_backup.run()` -> fake B2 -> `restore_backup.py` (read-only key) into a scratch Postgres 16: 53 tables / 614 rows identical by independent per-table hash; functions 100->100, triggers, indexes, constraints, grants, views identical; smoke tests pass. Negative controls pass: corrupted object, wrong key, production-looking host, real-looking DB name, non-empty target, wrong expected checksum, damaged rows, damaged schema. 30 unit tests in `test_hq_backup.py`, plus `/backup` command tests. Also runs in CI.

## Limitations (be honest)
- Not yet proven against real Backblaze or real PostgREST output, nor on production data. The drill source is the replica with synthetic data.
- Dump is table-by-table, not one transaction; cross-table skew is possible but unlikely at 02:00 (restore validates FKs and warns).
- Restore tested on Postgres 16; production is 17.11.
- Cron jobs and default privileges for future objects are recorded, not replayed. Unavailable extensions are skipped with a note.
- Retention depends on the B2 lifecycle rule you set. Supabase free plan has no PITR or downloadable backups, so this is the only recovery path.
- If the bot or Railway is down, no backup runs; `/backup` shows the age of the last good one and the heartbeat alert covers the bot.

## Go-live proof (required before claiming production recovery works)
1. After setup and approvals, `/backup now`.
2. Claude lists the object with key B, checks its size and sha256 against the sidecar and `/backup`.
3. Decrypt + restore into a local scratch DB with the real key (share it temporarily, then rotate; or run the restore yourself with the command above).
4. Compare restored row counts and content hashes with live read-only fingerprints. Only if all pass is production recovery proven.
