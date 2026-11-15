-- OWNER ONLY. Run in the Supabase SQL editor, ONE statement block at a time, after migrations 20261121_* are applied under release authorization.
-- Nothing here enables outreach by itself; it only prepares the evidence and suppression controls. Replace every <...>.
-- The owner calls need your auth uid: in the SQL editor set it for this transaction first (your uid from Authentication > Users):
--   select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
-- Generate keys on YOUR computer (python3 -c "import secrets;print(secrets.token_hex(32))"), keep them in the password manager, never in chat. Delete the editor snippet afterwards.

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

-- 5. After a restore (see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 8), AFTER re-establishing the list from the provider backup and/or:
--    select public.ffm_import_suppression_hashes();
select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true);
select public.ffm_verify_suppression('owner');   -- must return verified; anything else = stay closed

-- Check state at any time (safe, read-only):
select public.ffm_outreach_gate_status();
