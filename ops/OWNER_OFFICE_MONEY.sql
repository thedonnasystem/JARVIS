-- Owner-only office money controls (FENDEZY GROUP Phase 1, M2). Run in the Supabase SQL editor, only after the release of migration 20261128_office_money_v1.
-- Like ops/OWNER_JARVIS_CORE.sql: these functions accept the signed-in APP OWNER only (is_app_owner); a plain SQL session is refused like the bot. So each statement runs
-- together with your app user id (Supabase -> Authentication -> Users -> your user -> UID), in ONE transaction:
--   begin; select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true); select public.fz_owner_allocate('donna', 50000, 'first month'); commit;
-- Amounts are CAD cents (50000 = $500.00). Every change is logged in audit_log. Nothing below is run by any script.
-- Office money is ACCOUNTING: one real bank account (the group's). An allocation earmarks group capital for an office; it never moves money.

-- 0. Look first (anyone with the service key may run these)
-- select public.fz_money_report();
-- select office, status, net_allocation_cents, spent_cents, reserved_cents, revenue_cents, profit_cents, reinvest_pct, available_cents from public.fz_office_money order by kind, office;

-- 1. An office spends only when it is ACTIVE (M1 owner control) and has money available:
-- select public.fz_owner_set_office_status('donna', 'active');

-- 2. Allocate group capital to an office (refused if it is more than the group capital not yet allocated):
-- select public.fz_owner_allocate('donna', 50000, 'why');
-- Claw back (refused above what the office has available; leave the amount null for everything available):
-- select public.fz_owner_clawback('donna', 10000, 'why');
-- select public.fz_owner_clawback('donna', null, 'take all of it back');

-- 3. Reinvestment rule (default 0 %: an office never keeps profit until you set this). 25 = the office keeps 25 % of its profit, the rest is the group's:
-- select public.fz_owner_set_reinvest('donna', 25);

-- 4. Proposals from Jarvis / the bot (the id is in the Telegram message and in /offices). true executes, false rejects:
-- select public.fz_owner_decide_office_proposal('<proposal id>', true);
-- select public.fz_owner_decide_office_proposal('<proposal id>', false, 'not now');

-- 5. Move a ledger row (e.g. revenue the system gave to the group) to an office, or back to 'group':
-- select public.fz_owner_attribute_ledger('<ledger id>', 'donna', 'why');
