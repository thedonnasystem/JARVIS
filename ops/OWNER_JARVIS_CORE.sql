-- Owner-only switches for Jarvis core v2. Run in the Supabase SQL editor, only after the release of migration 20261123_jarvis_core_v1.
-- jarvis_require_owner accepts the signed-in APP OWNER only (as ffm_require_owner): a plain SQL session is refused like the bot. So each statement runs
-- together with your app user id (Supabase -> Authentication -> Users -> your user -> UID), in ONE transaction:
--   begin; select set_config('request.jwt.claim.sub', '<YOUR-AUTH-UID>', true); select public.jarvis_set_config('core_enabled', 'true'); commit;
-- Every change is logged (jarvis_changelog + audit_log). Nothing below is run by any script.

-- 0. Look first
-- select public.jarvis_core_status();

-- 1. Turn the core on (the worker still needs step 2; the kill switch still stops everything)
-- select public.jarvis_set_config('core_enabled', 'true');
-- 2. Let the worker take jobs (the bot also needs JARVIS_CORE=1 in Railway Variables)
-- select public.jarvis_set_config('worker_enabled', 'true');
-- 3. Let the core agent spend through the gateway (free providers settle at 0 cents; the company cap is unchanged)
-- update public.agents set status = 'active' where slug = 'jarvis-core';

-- Optional, each separately:
-- select public.jarvis_set_config('whatsapp_enabled', 'true');          -- plus JARVIS_WHATSAPP=1 and the WhatsApp variables
-- select public.jarvis_set_config('emergency_call_enabled', 'true');    -- plus JARVIS_EMERGENCY_CALL=1 and the telephony variables
-- select public.jarvis_set_config('max_calls_per_day', '2');            -- 0 to 5
-- select public.jarvis_set_config('self_automation_enabled', 'true');   -- drafts automations through the self-edit pipeline
-- select public.jarvis_set_config('self_edit_enabled', 'true');         -- plus JARVIS_SELFEDIT=1 and a machine-account token; read OWNER_GUIDE_JARVIS_V2.md first

-- Self-funding (paid models / GPU only from revenue you confirm):
-- select public.jarvis_set_config('self_fund_pct', '10');               -- 0 to 50 percent of confirmed Jarvis revenue
-- select public.jarvis_owner_confirm_revenue('<ledger id of a received, bank-matched revenue entry>');
-- select public.jarvis_set_config('paid_providers_enabled', 'true');    -- still limited by the self-funded budget and every cap

-- Apply a memory seed the bot staged (/seedmemory tells you the id):
-- select public.jarvis_seed_apply('<stage id>');

-- One use of the large model tier (expires; single use):
-- select public.jarvis_owner_approve_large(null, 24);

-- Turn everything off again: the same calls with 'false'. The kill switch (/kill) stops all of it at once.
