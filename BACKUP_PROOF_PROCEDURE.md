# Backup proof procedure: prove a REAL production backup can be downloaded, decrypted and restored

Purpose: turn "built and drilled on synthetic data" into "proven once on real production data". Until every step below passes, do not claim production recovery works.

**Hard rule: Claude, Jarvis, ChatGPT or any other AI must never be given BACKUP_KEY or any Backblaze credential, and none of them runs this procedure.** You run it on your own machine. Secrets are typed only into the local hidden prompts of `ops/restore_local.sh`. What you may show an AI afterwards: the two output files (`restore_report_*.json`, `restore_fingerprint_*.txt`) and the output of `ops/table_fingerprint.sql`. None of those contain secrets (check in step G).

Prerequisites: setup finished (`BACKUP_SETUP_OWNER.md`, `ops/backup_config_checklist.md` all ticked); Docker installed and running; Python 3 with `pip install cryptography psycopg2-binary`; a bash shell (Mac/Linux, or WSL on Windows); internet (Docker pulls `postgres:17.11`); the repo on that machine; BACKUP_KEY and the READ-ONLY key B from your password manager.

Record for each step: expected, actual, PASS/FAIL. Any FAIL: stop, use the triage table (F), fix, and restart from the failed step. A step is not "PASS" because it did not error: it needs the stated evidence.

## A. Trigger the backup (needs your explicit authorization of backup activation)
Only after you have approved the deploy and the migration `20261113_backup_schema_v1.sql`, and `/backup check` shows no FAIL and no WARN.
| | |
|---|---|
| Do | In the Jarvis Telegram chat send `/backup now` (replies "Running backup now. This can take a minute."), then `/backup`. |
| Expected | Final reply "Backup finished. Check /backup for details." `/backup` shows: Last good (UTC, within a minute or two), File `hq-<UTC timestamp>.tar.gz.enc`, Size (a few hundred KB; under 1 MB today), rows about 1,100 or more, tables 53, `complete: True`, and a 64-hex-character sha256. |
| Write down | file name, size, rows, sha256 (the hash is not a secret). Take the hash from the `/backup` reply, never from the bucket. |
| PASS if | `complete: True` and a sha256 is shown. FAIL if "Backup did not complete: ..." (reason is safe to read; see F) or `complete: False` (migration missing: data-only, unrestorable). You will also be messaged if the data was changing while it was read ("consistent: false"); then the file is saved but run `/backup now` again before proving. |
Note the time you ran it (step D needs it).

## B. Confirm the objects exist in Backblaze (web console, no secrets)
| | |
|---|---|
| Do | Log in to backblaze.com, Buckets, your backup bucket, Browse Files, open the `hq` folder. |
| Expected | Two files: `hq-<same timestamp>.tar.gz.enc` (size equals the Size from `/backup`, exactly) and `hq-<same timestamp>.tar.gz.enc.sha256` (about 100 bytes). Bucket page says Private. |
| PASS if | Both exist, sizes match, bucket is Private. FAIL if the sidecar is missing or sizes differ. (Earlier days' files may also be listed; that is normal.) |
Do not download or share anything in this step. The names and sizes are all you need.

## C. Local restore with hidden prompts
Run from the repo folder on your own machine:
`ops/restore_local.sh --b2-latest --expect-sha256 <sha256 from step A>`
(Run `chmod +x ops/restore_local.sh` first if needed. If you want an older backup, use `--b2-name <file name>` instead of `--b2-latest`.)
What it asks, in this order:
| Prompt | What you type | Echoed? |
|---|---|---|
| `BACKUP_KEY (hidden):` | the 44-character BACKUP_KEY (paste from the password manager) | No (hidden) |
| `Read-only B2 key as keyId:applicationKey (hidden):` | the READ-ONLY key B as `keyID:applicationKey`, one colon | No (hidden) |
| `B2 bucket ID (not secret):` | the Bucket ID | Yes (not a secret) |
Nothing else is typed. If you had `BACKUP_KEY` or `RESTORE_B2_AUTH` already exported in your shell it skips that prompt; do not export secrets for this, type them at the prompts. The `--expect-sha256` value is a command-line argument on purpose (not a secret).
| | |
|---|---|
| Expected | `restore exit code: 0` (or 4, see below). Then `RESULT: PASS` (or `PASS_WITH_WARNINGS`), the same file name and sha256 as step A, `consistency of the backup:` containing `single SQL statement snapshot (all tables + schema)` with `consistent: True`, and these steps all PASS: `file_checksum_decrypt_manifest`, `schema_rebuilt`, `data_loaded`, `constraints_indexes_triggers_views_policies_grants`, `every_row_identical`, `schema_identical`, `smoke_tests`. Business-data lines all say `identical`. Then "wrote restore_report_<stamp>.json and restore_fingerprint_<stamp>.txt" and "Destroying the throwaway database container...". |
| PASS if | exit code 0, or 4 with the foreign-key warnings understood (E). FAIL on any other exit code or any step FAIL. |

## D. Independent verification against production
The restore tool compares the restored data with the backup file. This step compares the restored copy with the LIVE production database using a separate method (a per-table row count and md5 over every row), so a bug in the backup writer cannot hide itself.
1. Immediately after step A (the smaller the gap the better), open the Supabase SQL editor for the production project and run the contents of `ops/table_fingerprint.sql` (a read-only SELECT). Save the output (table_name, rows, content_md5), noting the time. (If you ran it later than a few hours after the backup, expect more drift; run a fresh `/backup now` and repeat A to D for a cleaner comparison.)
2. Compare with `restore_fingerprint_<stamp>.txt` (format `table|rows|md5`, one line per table; push_config and push_subscriptions are excluded by design). Export the SQL result as CSV or copy rows, then diff, for example `diff <(sort restore_fingerprint_*.txt) <(sort production_fingerprint.txt)` after saving production as the same `table|rows|md5` shape.
| | |
|---|---|
| Expected | Same 53 tables on both sides. Every table has identical rows and md5, EXCEPT the allowed-to-differ list below. |
| PASS if | Every table outside the list is identical, and for each listed table production has equal or MORE rows than the restored copy (data only appends/changes after the snapshot). FAIL if any non-listed table differs, a table is missing on either side, or a listed table has FEWER rows in production than the restore (that means rows were deleted or the backup is wrong: investigate). |

Rule for rows that legitimately differ. These tables change while the company runs, after the backup's snapshot moment: `audit_log` (the backup itself writes a `backup_ok` row after the snapshot, so at least this table differs by one), `llm_calls` (spend records), `owner_messages` (Telegram messages and notices), `system_state` (heartbeats), and, because the engine ticks every few minutes, possibly `integration_status` (checked_at each tick), `alert_state`, `agent_runs`, `action_log`, `tasks`, `missions`, `web_messages`, `spend_reservations`. For a non-listed-by-name table that differs, the rule is: you must be able to point to a legitimate cause (activity between backup and fingerprint, visible as newer timestamps in production). If you cannot, it is a FAIL. To remove the doubt, repeat A to D during a quiet moment (night, no missions running) so almost nothing differs. A difference in the content_md5 of an unchanged-row-count table is not "just drift" until you have seen the changed rows.

## E. What the restore report must show
Open `restore_report_<stamp>.json`. All of these, no exceptions:
| Field | Required value |
|---|---|
| exit code printed by the script | 0, or 4 |
| `result` | `PASS` (or `PASS_WITH_WARNINGS` for exit 4) |
| `file.sidecar_sha256_ok` | `true` |
| `file.expected_sha256_ok` | `true` (it is there because you passed `--expect-sha256`) |
| `file.decrypts` | `true` |
| `archive.complete` | `true` |
| `archive.consistency` | consistent `true`, method `single SQL statement snapshot (all tables + schema)`. If it says `two identical full reads` or has `snapshot_unavailable`, the snapshot function was not used: the backup is weaker; find out why before accepting. |
| `steps.every_row_identical` | `PASS` |
| `steps.schema_identical` | `PASS` |
| `steps.smoke_tests` | `PASS` |
| `steps.schema_rebuilt`, `data_loaded`, `constraints_indexes_triggers_views_policies_grants` | `PASS` |
| `views_failed` | empty |
| `not_restored` | read it: expected only cron jobs, future default privileges, push tables note. Anything new is a finding. |
| `constraint_warnings` | empty for exit 0. Exit 4 means rows in the backed-up data violate foreign keys: the restore is faithful (the violation is in production too), but record the listed tables and decide whether to clean them. Not a failure of the backup, not a clean pass either. |
`business_data` lines (missions/tasks, leads, ledger, memory, etc.) must all be `all_identical: true`.

## F. Failure triage
| Symptom (exit code) | Meaning | Fix |
|---|---|---|
| `checksum mismatch: file X vs sidecar Y` (2) | File changed or truncated after upload, or sidecar belongs to another file | Do not trust that file. Download again; if it repeats, run `/backup now` again and prove the new file. Investigate the bucket (who has write access). |
| `checksum mismatch: file X vs --expect-sha256 Z` (2) | The hash you typed is not the one `/backup` recorded, or the object in the bucket is not the one the bot recorded | Re-copy the hash from `/backup` (watch for the wrong day). If it is right, treat the object as tampered/corrupt: serious, escalate. |
| `cannot decrypt: wrong BACKUP_KEY or the file is damaged` (2) | The key typed differs from the key in Railway when the backup was made | Compare your two stored copies (do not compare by pasting anywhere). If Railway's key was changed later, you need the key that was active at that time. This is the failure that matters most: it means the backup is useless. |
| `B2 authorize failed (HTTP 401)` (2) | Wrong keyID:applicationKey, typo, key deleted/expired | Re-copy key B from the password manager. If lost, create a new Read Only key (the backups are unaffected). |
| `B2 list failed (HTTP 401/403)` / `B2 download failed (HTTP 403)` (2) | Key lacks listFiles/readFiles (for example the write-only bot key was typed), or is limited to another bucket, or wrong bucket ID | Use key B (Read Only, this bucket), check the bucket ID. |
| `no backups found in that bucket/prefix` (2) | Wrong bucket ID, or prefix differs (`RESTORE_B2_PREFIX` default is `hq/`; BACKUP_PUT_URL must end `/hq`), or nothing uploaded yet | Check step B shows files under `hq/`. |
| `Docker is required` / `Could not start the throwaway PostgreSQL 17.11 container` / `did not become ready in 60 seconds` (2) | Docker not installed, not running, or cannot pull the image | Start Docker, check internet, retry. Nothing was restored. |
| `Run: pip install cryptography psycopg2-binary` (2) | Missing Python libraries | Install, retry. |
| Exit 4, `constraint_warnings` | Foreign-key violations exist in the backed-up data | See E. Record, do not ignore silently. |
| Exit 1, `schema_identical` FAIL | Restored schema differs from the backup's own description. Possible cause: the throwaway server is PostgreSQL 17.11 while production's catalogs may differ in a point version, or a captured object type is not replayed | Read `schema` section of the report for the differing items. Differences limited to server-version strings or items listed in `not_restored` are explainable; anything else is a FAIL. The drill passed on PG 16 and 17, so a PG16 vs PG17 difference is expected to be cosmetic only: prove that from the report, do not assume. |
| Exit 1, `every_row_identical` FAIL | A table restored differently from the backup | Real FAIL: the report names the table. Do not proceed. |
| Exit 3 | Unexpected error (message has no secrets) | Keep the report; give it to Claude; do not retry blindly. |
| Exit 2 `no schema.json (data-only)` | `complete: False` backup: migration not applied | Apply the approved migration, run `/backup now`, restart at A. |

## G. Cleanup and no-secrets check
1. Container: the script removes it on exit. Check: `docker ps -a --filter name=fendezy-restore` must list nothing. If one is left: `docker rm -f <name>`.
2. Shell: close the terminal window (secrets were only in that process's memory, never on a command line).
3. The only files left are `restore_report_*.json` and `restore_fingerprint_*.txt`. Check they hold no secrets before showing anyone: `grep -c -E 'gAAAA|:[A-Za-z0-9+/_-]{25,}|eyJ' restore_report_*.json restore_fingerprint_*.txt` should print 0 for each file (Fernet tokens start `gAAAA`, JWTs start `eyJ`, key pairs contain `keyID:longKey`). Also confirm by eye that your BACKUP_KEY (search for the first 8 characters, typed locally) does not appear. The report contains only: file name, size, sha256, counts, PASS/FAIL, table names and a host/db label.
4. Do not copy the downloaded data anywhere: the script never writes the backup file to disk (it is held in memory); the restored data lives only inside the destroyed container.
5. Delete the two output files when no longer needed (keep the PASS report as your record if you like; it has no secrets).

## H. What a PASS proves and does not prove (honest)
Proves:
- The real file the production bot produced can be downloaded with a Read Only key, passed its checksum, decrypted with your stored BACKUP_KEY, and rebuilt into a working PostgreSQL 17.11 database; every captured row equals the backup; the captured schema (functions, triggers, indexes, constraints, views, policies, grants) is identical; smoke tests pass; and the restored copy matches production's independent fingerprint apart from explained drift.
- Your stored copy of BACKUP_KEY is the right one, and the Read Only key works.
Does NOT prove:
- Anything about backups other than this one: it is ONE restore of ONE backup on ONE day. Tomorrow's backup, a bigger database, or a changed schema needs its own proof (hence the drill schedule below).
- That a disaster recovery on a new hosted Supabase project works: this restores into a local scratch Postgres; moving it into a new project is a separate manual step (`pg_dump` from the scratch DB), not exercised here.
- Architecture parity: production runs aarch64; your restore container is usually x86_64 (or arm on Apple silicon). Same PostgreSQL major version (17.11), but not byte-identical platforms.
- Web push keys: `push_config` and `push_subscriptions` are deliberately excluded; after a disaster push needs new keys and re-subscribing (Telegram is unaffected).
- Cron jobs, future default privileges, non-`postgres` object owners, column-level ACLs and anything outside schema `public` are recorded, not replayed. Supabase platform state (auth users, storage, project secrets, service keys) is not in the backup at all.
- Bot-side behavior (Railway down means no backup), bucket lifecycle behavior at 90 days, or protection if both your BACKUP_KEY copies are lost.
- That the fingerprint comparison is perfect: production may legitimately have changed after the snapshot (D); and md5 over `row::text` can differ from the backup's own comparison only through real differences, but it cannot see rows that changed and changed back.

## I. Recurring restore-drill schedule (recommendation)
- Weekly (2 minutes, no secrets needed): `/backup` in Telegram: Last good under 2 days old, complete True. Also glance at the Backblaze bucket: the newest `.enc` and its `.sha256`.
- Monthly: repeat C, E and G with `--b2-latest` (D optional). Calendar reminder on the first Sunday.
- Quarterly, and after any of these: full A to H, including D. Triggers: a schema migration, a rotation of BACKUP_KEY or B2 keys, a Supabase plan or region change, the database growing past about 100 MB (the snapshot function builds one JSON document in memory; revisit then), a Railway or Backblaze account change.
- Yearly: confirm both copies of BACKUP_KEY still exist and are readable, and that key B is still valid.
- If a monthly drill FAILS: treat as an incident the same day: backups are not protecting you until it passes again.
