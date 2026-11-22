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
--    a) ask: creates one approval item (in /approvals) and returns a 64-character nonce only you can see; the office is 'prepared' and still cannot spend
-- select public.office_os_activate('donna');
--    b) decide with that nonce (single use; false refuses). A Telegram tap does NOT activate anything.
-- select public.office_os_decide('donna', '<nonce>', true);
--    c) finish: the office becomes active (M1 status active); its prohibited actions that are policy actions become office blocks. Rejected / expired (3 days): back to dormant.
-- select public.office_os_activate('donna');

-- 3. Money only on need (M2; no fixed budgets): select public.fz_owner_allocate('donna', <cents>, 'why');

-- 4. Stop an office (or cancel a pending activation): back to dormant, spending refused again.
-- select public.office_os_deactivate('donna');

-- 5. Client invoicing (Donna). Drafts are free; nothing reaches a client without one of these:
--    a) one invoice: /invoices shows it after Donna asks (/invoices request <id>); approve it with its exact amount in cents, then /invoices send <id>
-- select public.office_os_invoice_decide('<invoice id>', <cents>, true);
--    b) a recurring billing plan, once: after that, each month / year Donna sends exactly that amount (/invoices bill donna); anything else asks you again
-- select public.office_os_plan_decide('<plan id>', <cents>, 'month', true);
--    c) stop a plan at once (no more automatic invoices):
-- select public.office_os_plan_revoke('<plan id>');

