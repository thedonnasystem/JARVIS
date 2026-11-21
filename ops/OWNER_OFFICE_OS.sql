-- Owner-only office controls (FENDEZY GROUP Phase 1, M7 office OS). Run in the Supabase SQL editor, only after the release of migration 20261203_office_os_v1.
-- Like ops/OWNER_OFFICE_MONEY.sql: these accept the signed-in APP OWNER only (is_app_owner); the bot and a plain SQL session are refused. Each statement runs with
-- your app user id (Supabase -> Authentication -> Users -> your user -> UID), in ONE transaction:
--   begin; select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true); select public.office_os_set_manager('donna', 'Donna lead'); commit;
-- Nothing below is run by any script. Every change is logged in audit_log.

-- 0. Look first (anyone with the service key; Telegram: /office donna)
-- select public.office_os_status();            -- all 8 offices
-- select public.office_os_status('donna');

-- 1. Appoint (or change) the manager. A label only: a role or a handle, no personal data needed. Clearing (null) works only while the office is dormant.
-- select public.office_os_set_manager('donna', 'Donna lead');

-- 2. Activate, ONE office at a time (approved order: donna, wolf-squad, ff-marketing):
--    a) ask: creates one approval item (Telegram message + /approvals); the office is 'prepared' and still cannot spend
-- select public.office_os_activate('donna');
--    b) tap Approve on the Telegram message
--    c) run the same line again: the office becomes active (M1 status active). If you rejected it or it expired (3 days), it goes back to dormant.
-- select public.office_os_activate('donna');

-- 3. Money only on need (M2; no fixed budgets): select public.fz_owner_allocate('donna', <cents>, 'why');

-- 4. Stop an office (or cancel a pending activation): back to dormant, spending refused again.
-- select public.office_os_deactivate('donna');
