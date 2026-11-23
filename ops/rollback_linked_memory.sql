-- Rollback of migrations/20261205_linked_memory_v1.sql. Idempotent. One transaction. NON-DESTRUCTIVE: the memories, links and quota counters are KEPT
-- (the schema fz_memory is renamed to fz_memory_archive, which has no privilege for any API role); only the functions go. Re-applying the migration
-- renames it back, so nothing learned is lost. The bot keeps working: with jmem_search / jquota_load gone, hq_memory returns no linked facts and
-- hq_brain_quota keeps the counts in memory only (both fail soft). For the code, unset JARVIS_LINKED_MEMORY in Railway (instant).
\if :{?fz_in_txn}
\else
begin;
\endif
drop function if exists public.jmem_search(text, text, real[], text, integer, text, text), public.jmem_apply(text, jsonb, text, text, text),
  public.jmem_entity_upsert(uuid, text, text), public.jmem_list(text, text, integer), public.jmem_forget(text, text, text, text),
  public.jmem_links(text, text, integer), public.jmem_stats(), public.jquota_record(text, integer, bigint, timestamptz, integer), public.jquota_load(),
  public.jmem_office(text, text), public.jmem_dot(real[], real[]), public.jmem_norm(text), public.jmem_guard();
do $$
begin
  if to_regnamespace('fz_memory') is not null then
    if to_regnamespace('fz_memory_archive') is null then
      alter schema fz_memory rename to fz_memory_archive;
      insert into public.audit_log (actor, action, target, detail) values ('rollback', 'linked_memory_archived', 'fz_memory_archive',
        jsonb_build_object('memories', (select count(*) from fz_memory_archive.memories), 'entities', (select count(*) from fz_memory_archive.entities)));
    else
      raise notice 'fz_memory_archive already exists: fz_memory left in place (nothing is dropped); reconcile by hand';
    end if;
  end if;
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
