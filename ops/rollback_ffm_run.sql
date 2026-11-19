-- Rollback of migrations/20261126_ffm_run_v1.sql (FF Marketing execution v1). Idempotent. Run from the repo root.
-- DESTRUCTIVE for the ffm_run_* tables only (launches, approved budgets, platform object ids, metrics, receipts, lead sequences): export them first if you want them
-- (e.g. \copy public.ffm_run_receipts to 'ffm_run_receipts.csv' csv header). BEFORE running it on a live system: /ffm stop every launch (pauses the ads on Meta);
-- this file cannot reach Meta. Leads (ws_leads), consent records, suppressions, hand_actions and outbox rows are ordinary rows and are KEPT.
-- The meta-ads connector row is removed only when no account was ever connected through it. No other object is changed.
begin;
drop function if exists public.ffm_run_report(uuid, date, date), public.ffm_run_stop(uuid, text), public.ffm_run_lead_event(uuid, text, text),
  public.ffm_run_touch(uuid, integer, text, text, boolean), public.ffm_run_intake_lead(uuid, text, text, text, text, text, jsonb, text), public.ffm_run_set_landing(uuid, text),
  public.ffm_run_submit_hand(uuid, text, text, text, jsonb), public.ffm_run_put_metrics(uuid, date, integer, integer, integer, integer, boolean),
  public.ffm_run_set_object(uuid, text, integer), public.ffm_run_put_object(uuid, text, text, uuid, text, text, integer, boolean), public.ffm_run_receipt(uuid, text, text, boolean, boolean, text, text, uuid),
  public.ffm_run_gate(uuid, text, text), public.ffm_run_sync_decisions(), public.ffm_run_request_budget(uuid, integer, integer, text),
  public.ffm_run_propose(uuid, uuid, integer, integer, date, date, text[], text[], jsonb, text), public.ffm_run_check_budget(uuid), public.ffm_run_ask_owner(uuid, text),
  public.ffm_run_money(integer), public.ffm_run_budget(uuid), public.ffm_run_live_mode();
drop table if exists public.ffm_run_touches, public.ffm_run_leads, public.ffm_run_metrics, public.ffm_run_receipts, public.ffm_run_objects, public.ffm_run_budgets, public.ffm_run_launches;
drop function if exists public.ffm_run_budget_fixed(), public.ffm_run_append_only();
do $$ begin
  if to_regclass('public.hand_connectors') is not null then
    delete from public.hand_connectors c where c.slug = 'meta-ads' and not exists (select 1 from public.hand_accounts a where a.connector = c.slug);
  end if;
end $$;
commit;
