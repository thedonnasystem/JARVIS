-- Rollback of migrations/20261204_open_brain_v1.sql. Idempotent. One transaction. Keeps the record: the switch value goes into one audit_log row.
-- (Order: before ops/rollback_monitoring_brain.sql.) The bot keeps working: with open_brain_routing() gone, hq_llm treats the switch as OFF.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'fz_brain_config' and column_name = 'owner_chat_free_providers') then
    insert into public.audit_log (actor, action, target, detail)
      select 'rollback', 'open_brain_export', 'fz_brain_config', jsonb_build_object('owner_chat_free_providers', c.owner_chat_free_providers,
             'allow_training_providers_nonprivate', c.allow_training_providers_nonprivate) from public.fz_brain_config c where c.id = 1;
    alter table public.fz_brain_config drop column owner_chat_free_providers, drop column if exists allow_training_providers_nonprivate;
  end if;
end $$;
drop function if exists public.open_brain_set_training_nonprivate(boolean), public.open_brain_set_owner_chat_free(boolean), public.open_brain_routing();
\if :{?fz_in_txn}
\else
commit;
\endif
