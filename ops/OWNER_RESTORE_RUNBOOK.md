# Owner runbook: after ANY database restore (ordered)

Applies to: a provider point-in-time recovery, a Supabase backup restore, a `pg_dump`/`pg_restore` reload, or `ops/restore_backup.py`. Outreach stays closed throughout. Nothing here sends anything.

**The order is enforced by the database and the sender. Doing a step out of order does not break anything; it is refused.**

## Before a `pg_restore` / `psql` reload into a NEW server or project (prerequisite)
Roles belong to the server, not to the database, so a dump does not create them; it only carries GRANTs to them. Create every role the dump grants to BEFORE restoring, or the restore stops with `role "..." does not exist`:
```
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;            -- Supabase projects already have these three
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin; exception when duplicate_object then null; end $$;
do $$ begin create role backup_reader nologin noinherit nobypassrls nocreatedb nocreaterole noreplication; exception when duplicate_object then null; end $$;   -- the backup identity (PR #16)
grant backup_reader to authenticator;   -- only on Supabase/PostgREST (as in migration 20261121_postlock_backup_identity_v1), so BACKUP_READER_JWT can switch to it
```
`backup_reader` is the backup identity added by the leak-redaction change; creating it on a database that does not have that change yet is harmless (it holds nothing). The restore drill does the same (`scripts/backup_drill.py`, check V9, restore into another cluster). A restore into the SAME project keeps the roles and needs none of this.

| # | Who / where | Action | Why it is first |
|---|---|---|---|
| 0 | you | Do nothing else. Do not re-enable anything. | The gate closes itself (stale attestation within 15 minutes, other cluster or timeline at once, the sender's mark if it sees it). |
| 1 | you, Supabase SQL editor (as the database owner) | `select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true); select public.ffm_owner_record_restore('<what was restored, to which time>');` | Writes an OWNER restore marker and closes the gate. Only this marker can allow the sender's mark to be lowered. The bot role cannot call it. `restore_backup.py` writes the same kind of marker itself. |
| 2 | you | Re-establish the suppression list (provider copy, or `ops/restore_backup.py --expect-sha256 <hash you recorded when you exported>`). | A verification against the wrong list proves nothing. |
| 3 | you, SQL editor | `select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true); select public.ffm_verify_suppression('owner');` It must return `verified: true`. | Opens the gate. A verification made BEFORE step 1 is void: the database records the newest marker id at verification and opens only while that is still the newest. |
| 4 | you, bot chat | `/gate anchor` | Starts a new generation of the sender's outside mark at the database's current epoch. Refused unless step 3 came after step 1. Needed once at first setup too (no marker is needed then). |
| 5 | you | `/gate` | Prints the state and `NEXT STEP:`. When it says `none` you are done. |

## If `/gate anchor` says no

| Message | Meaning | Do |
|---|---|---|
| `gate_not_verified` | the gate is not freshly verified after the newest marker | steps 1-3 in order |
| `restore_not_recorded` | the database epoch is BELOW the sender's mark and no unused owner restore marker exists: the restore was not recorded (or not seen) | step 1, then 3, then 4 |
| `anchor_refused` ... `owner-recorded restore ... not yet used` | the database already used your last marker for an anchor | step 1 again |
| `hwm_unavailable` | no mark store is readable or writable (`GATE_HWM_FILE` or `BACKUP_PUT_URL`/`BACKUP_AUTH`) | fix the store first; the database may already hold the new generation: record another restore (step 1), verify, anchor |

## What this does not cover
A restore that also resets every store the sender uses (the B2 `gate/` objects and `GATE_HWM_FILE`), followed by your own anchor, is invisible to the system. The step-1 marker and step-3 checkpoint check are then the only barriers. See `DATA_CLASSIFICATION_AND_BACKUP_POLICY.md` sections 9-10.
