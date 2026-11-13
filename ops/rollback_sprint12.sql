-- ROLLBACK OF THE SPRINT 1-2 MIGRATIONS ONLY (20261113_backup_schema, 20261114_venture_generic, 20261115_venture_deals_replies,
-- 20261115_inbox_needs_you). Phase 1 (already live) is NOT touched; use ops/rollback_phase1.sql only if you also want Phase 1 removed.
-- Derived from the matching sections of ops/rollback_phase1.sql; scripts/replica/run.sh proves it (Phase 1 functions survive, new ones go,
-- migrations re-apply). Idempotent. Tables created by these migrations (contact_suppressions, lead_replies, venture_config) are LEFT IN
-- PLACE on purpose: the suppression list is a CASL legal record and the others hold owner data. After running it, re-run
-- migrations/20261112_lockdown_v1.sql (idempotent) and ops/verify_live.sql.
begin;
drop function if exists public.backup_snapshot(text[]);
drop function if exists public.backup_schema();
-- Deals / replies / do-not-contact (20261115_venture_deals_replies_v1): triggers first, then functions. venture_kpis goes back to the
-- 20261114 body here (the generic section below then drops it with the rest). Tables are LEFT IN PLACE (they hold the CASL
-- suppression list, replies and config; dropping would delete data): optional drops are commented at the end of this block.
drop trigger if exists outbox_dnc_guard on public.outbox;
drop trigger if exists leads_dnc_cascade on public.leads;
drop trigger if exists leads_suppression_guard on public.leads;
drop function if exists public.outbox_dnc_guard();
drop function if exists public.leads_dnc_cascade();
drop function if exists public.leads_suppression_guard();
create or replace function public.venture_kpis(p_venture text) returns jsonb
language plpgsql stable set search_path to 'public' as $$
declare v public.ventures;
begin
  select * into v from public.ventures where slug = p_venture;
  if not found then return null; end if;
  return jsonb_build_object(
    'venture', v.slug,
    'leads', (select count(*) from public.leads where venture_id = v.id),
    'emailable_leads', (select count(*) from public.leads where venture_id = v.id and email is not null and do_not_contact = false),
    'drafted', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id),
    'approved', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id and o.status in ('approved','sent')),
    'sent', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id and o.status = 'sent'),
    'won_deals', (select count(*) from public.deals where venture_id = v.id and lower(stage) in ('won','closed','closed_won','paid')),
    'deals_by_stage', coalesce((select jsonb_object_agg(stage, n) from (select stage, count(*) n from public.deals where venture_id = v.id group by stage) d), '{}'::jsonb),
    'revenue_cents', coalesce((select sum(amount_cents) from public.ledger where venture_id = v.id and kind = 'revenue' and status = 'received' and intercompany = false), 0));
end $$;
drop function if exists public.lead_funnel(text);
drop function if exists public.set_venture_config(text, text, text, text);
drop function if exists public.venture_config_get(text);
drop function if exists public.confirm_deal_won(uuid, int, text, text, text);
drop function if exists public.set_deal_stage(uuid, text, text, text);
drop function if exists public.create_deal(uuid, int, text, text);
drop function if exists public.record_lead_reply(uuid, text, text, text);
drop function if exists public.mark_do_not_contact(uuid, text, text);
drop function if exists public.is_suppressed(text);
-- normalize_addr is referenced by the suppression table's CHECK: drop that constraint first (the table and its append-only trigger stay: legal record)
do $$ begin
  if to_regclass('public.contact_suppressions') is not null then
    alter table public.contact_suppressions drop constraint if exists contact_suppressions_address_check;
  end if;
end $$;
drop function if exists public.normalize_addr(text);
-- Optional, destructive, NOT part of a normal rollback (the suppression list is a legal record):
-- drop table if exists public.lead_replies, public.venture_config, public.contact_suppressions;

-- Venture generic loop (20261114_venture_generic_v1): new functions only, nothing else changed
drop function if exists public.ensure_venture_agents(text, text);
drop function if exists public.queue_prospect_task(text);
drop function if exists public.queue_all_prospect_tasks();
drop function if exists public.venture_kpis(text);

-- Unified Needs-you inbox (20261115_inbox_needs_you_v1): new functions only, nothing else changed
drop function if exists public.app_needs_you();
drop function if exists public.needs_you(integer);
commit;
