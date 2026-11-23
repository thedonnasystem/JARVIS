# Scoped token rotation and revocation (owner runbook)

The scoped tokens (M1) only **name** an identity. The database decides at every request (`fz_identity_now()`), so you can stop any token at once, without rotating the Supabase JWT secret. Run the statements in the Supabase SQL editor in your owner session (with your auth uid, as in `ops/OWNER_JARVIS_CORE.sql`):

```
begin; select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true); <statement>; commit;
```

The replica runs every step below as a drill (`scripts/replica/token_drill.sql`, the "token rotation drill" step of `scripts/replica/run.sh`).

## Look first

- `/security` in Telegram: identities (active / dormant / revoked), tokens near expiry, alerts.
- `select public.fz_security_report();` for the full report.

## Rotate one identity (routine, e.g. every 90 days)

1. Mint a new token in `ops/mint_scoped_tokens.html`. Note its `jti` and expiry.
2. Pin it. **The old token stops at once**: `select public.fz_owner_set_identity('<identity>', 'active', '<new jti>');`
3. Put the new value in Railway (`FZ_SCOPED_TOKENS`) and redeploy.
4. Register its expiry, so `/security` warns 14 days before it lapses: `select public.fz_owner_register_token('<identity>', '<new jti>', '<expires at>');`

## Void everything issued so far (one identity)

`select public.fz_owner_set_identity('<identity>', 'active', null, true);`. Every token issued before now is refused. Mint and install a new one.

## A token leaked

1. **At once** (Jarvis may also do this; it can only make things safer): `select public.fz_revoke_identity('<identity>', 'leaked');`. That identity reads and does nothing from now on.
2. When ready, re-activate with a new token and void the old ones: `select public.fz_owner_set_identity('<identity>', 'active', '<new jti>', true);`
3. Check `select public.fz_audit_verify();` (the audit chain) and `/security` (any new privileged grant).

## The JWT secret itself leaked

That is the rare, heavy case. Rotate the JWT secret in Supabase (Project Settings, JWT Keys). That invalidates **every** token, including the service key, the anon key and the backup reader. Then re-mint all scoped tokens and update every Railway variable that holds a key. Before you do, revoke the scoped identities (step 1 above) so nothing runs in between.

## Rules the database enforces (tested)

- The bot can revoke but never activate (`fz_owner_set_identity` refuses it).
- A token with a `sub` claim, a role that does not match, another office's claim, an unknown or dormant identity, an unpinned jti, or an issue time before the void is refused.
- Every step writes an `audit_log` row, and the audit hash chain (M4) makes a later edit of those rows evident.
