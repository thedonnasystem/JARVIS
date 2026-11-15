-- OWNER ONLY. Run in the Supabase SQL editor, ONE statement block at a time, after migrations 20261121_* are applied under release authorization.
-- Nothing here enables outreach by itself; it only prepares the evidence and suppression controls. Replace every <...>.
-- The owner calls need your auth uid: in the SQL editor set it for this transaction first (your uid from Authentication > Users):
--   select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
-- A key is EXACTLY 64 lowercase hex characters (32 random bytes). Passphrases are refused: the stored fingerprints are HMACs of fixed strings, so a guessable key could be brute-forced offline.
-- Generate keys on YOUR computer (python3 -c "import secrets;print(secrets.token_hex(32))"), keep them in the password manager, never in chat. Delete the editor snippet afterwards.

-- KEY RULES (PR #15 review): the two keys must be UNRELATED random values (64 hex characters each from the command above, generated twice). ffm_set_key refuses a weak key, a repeated
-- pattern, and a key that equals, contains or overlaps the other. Check a candidate locally first so the database call never fails (a failed statement can be written to the error log WITH the key):
--   CONSENT_KEY_CANDIDATE="$(cat /dev/shm/cap.key)" CONSENT_KEY_OTHER="$(cat /dev/shm/sup.key)" python3 hq_consent.py check-key        # prints only "key OK" / "key REFUSED (reason)"
-- The SQL editor sends the key as part of the statement text, which a query log may keep. If you have psql access, prefer the variant below (key read from a file on tmpfs, never typed or in shell history):
--   umask 077; python3 -c "import secrets;print(secrets.token_hex(32))" > /dev/shm/sup.key          # and /dev/shm/cap.key
--   psql "$OWNER_DB_URL" -v ON_ERROR_STOP=1 --no-psqlrc <<'SQL'
--   \set HISTFILE /dev/null
--   select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', false);
--   \set k `cat /dev/shm/sup.key`
--   select public.ffm_set_key('suppression_hmac_key', :'k', 'owner');
--   \unset k
--   SQL
--   shred -u /dev/shm/sup.key after storing it in the password manager. Before either method run:  show log_statement;   (must be none or ddl). Never print or paste a key.

-- 1. Suppression key (kept OFFLINE, separate from BACKUP_KEY). Set once. Returns a fingerprint, not the key.
select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
select public.ffm_set_key('suppression_hmac_key', '<64-hex suppression key>', 'owner');

-- 2. Capture signing key (given ONLY to the consent-form endpoint, never to the bot). Set once.
select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
select public.ffm_set_key('capture_signing_key', '<64-hex capture key>', 'owner');

-- 3. Register each approved consent wording (sha256 of the exact text shown on the form).
select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
select public.ffm_register_wording('<workspace uuid>', '<wording version, e.g. form-v1>', '<sha256 hex of wording>', 'owner');

-- 4. Hand-attested consent (paper/recorded call) - only with a real artifact kept on file; see ffm_register_capture_owner's signature in the migration.

-- 6. AFTER ANY RESTORE (provider PITR, pg_dump, Supabase backup restore, or ops/restore_backup.py). ORDER MATTERS: record the restore -> verify -> /gate anchor (ops/OWNER_RESTORE_RUNBOOK.md).
--    The gate row comes back as it was at the snapshot, possibly 'verified' = OPEN, with later suppressions missing. Since v3 the gate also closes itself (other cluster/timeline, the sender's outside
--    high-water mark, a stale attestation), but do this FIRST. OWNER ONLY (run it here, in the SQL editor; the bot role cannot): it writes an OWNER RESTORE MARKER, closes the gate, and is the only thing
--    that can ever authorise the sender to lower its mark:
select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
select public.ffm_owner_record_restore('<what you restored and to which time>');
--    then re-establish the list, then verify against an INDEPENDENT checkpoint (the file hash YOU recorded outside the database when you made the export: restore_backup.py --expect-sha256. NOT audit_log: service_role can write audit_log, so it proves nothing. A provider restore can also bring back a 'verified' gate with an older list: close the gate first).
--    ffm_import_suppression_hashes() followed by ffm_verify_suppression() is circular (the import IS the checkpoint) and proves nothing by itself.

-- 5. After a restore (see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 8), AFTER re-establishing the list from the provider backup and/or:
--    select public.ffm_import_suppression_hashes();
select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
select public.ffm_verify_suppression('owner');   -- must return verified; anything else = stay closed

-- 5b. AFTER the verification above, in the BOT CHAT (not here): /gate anchor. The sender keeps the highest suppression epoch it has seen OUTSIDE the database and refuses to send when the
--     database is behind it or when it has none. Anchoring is accepted only while the gate is verified AFTER the newest restore marker, and, when the database is behind the sender's mark, only with an owner restore marker (step 6) the mark has not used.
--     Needed once at setup and after every restore. /gate (no argument) prints the next required step.
-- 5c. Optional (owner only): the gate timers. Defaults: sender attestation must be at most 15 minutes old; your verification at most 30 days old. Bounds 6-120 minutes (the engine tick is 300 s), 1-90 days.
--    select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
--    select public.ffm_set_gate_config(15, 30, 'owner');

-- Check state at any time (safe, read-only; /gate in the bot chat shows the same plus the sender's mark):
select public.ffm_outreach_gate_status();

-- 7. app_owners: the bot's service role can no longer write it (migration 20261121_suppression_integrity_v1, section 13). Add or remove an owner HERE, in the SQL editor:
--    insert into public.app_owners (email) values ('<owner email>');
