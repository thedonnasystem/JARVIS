-- FENDEZY GROUP: "Open brain" (Nov 22 2026). ADDITIVE. Needs 20261202_monitoring_brain_v1 (fz_brain_config).
-- The owner chat and mission tasks now run on free open models (hq_llm rotation, hq_open_brain.py). This file adds ONE owner decision:
--   fz_brain_config.owner_chat_free_providers (default FALSE): when the owner turns it on, owner-chat / owner-mission prompts may go to the free providers
--   that do not train on prompts and keep no prompt data (hq_llm.OWNER_DATA_PROVIDERS: groq, openrouter with data_collection=deny, cerebras).
--   Client personal data is NOT covered by this switch: it still goes only to the self-hosted model (enforced in hq_llm, not here).
-- and a SECOND owner decision (Nov 22 2026, task-aware router):
--   fz_brain_config.allow_training_providers_nonprivate (default FALSE): when on, providers whose free tier may train on prompts (Google Gemini free)
--   may take NON-PRIVATE job prompts only (public sources, nothing detected). Owner chat and client data never go there, whatever this says.
-- open_brain_routing() is what the bot reads (service key; read-only). open_brain_set_owner_chat_free(on) is the owner's switch (owner session only,
-- audited); the existing owner-only config guard on fz_brain_config refuses the service key too.
-- No change to caps, the kill switch, mode, the spend gateway, authorize_action or any money control. Rollback: ops/rollback_open_brain.sql.
-- Ordered BEFORE the lockdown (R3). Safe to re-run.

set lock_timeout = '5s';

alter table public.fz_brain_config add column if not exists owner_chat_free_providers boolean not null default false;
alter table public.fz_brain_config add column if not exists allow_training_providers_nonprivate boolean not null default false;

create or replace function public.open_brain_routing() returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select jsonb_build_object('owner_chat_free_providers', coalesce((select c.owner_chat_free_providers from public.fz_brain_config c where c.id = 1), false),
                            'allow_training_providers_nonprivate', coalesce((select c.allow_training_providers_nonprivate from public.fz_brain_config c where c.id = 1), false))
$$;
revoke all on function public.open_brain_routing() from public, anon, authenticated;

create or replace function public.open_brain_set_owner_chat_free(p_on boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if not (coalesce(public.is_app_owner(), false) or coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres')) then
    raise exception 'owner approval required: only the owner lets free model providers see the owner chat' using errcode = '42501';
  end if;
  update public.fz_brain_config set owner_chat_free_providers = coalesce(p_on, false), updated_by = 'owner' where id = 1;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'open_brain_owner_chat_free_providers', 'fz_brain_config',
    jsonb_build_object('on', coalesce(p_on, false)));
  return public.open_brain_routing();
end $$;
revoke all on function public.open_brain_set_owner_chat_free(boolean) from public, anon, authenticated;

create or replace function public.open_brain_set_training_nonprivate(p_on boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if not (coalesce(public.is_app_owner(), false) or coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres')) then
    raise exception 'owner approval required: only the owner lets training providers see non-private work' using errcode = '42501';
  end if;
  update public.fz_brain_config set allow_training_providers_nonprivate = coalesce(p_on, false), updated_by = 'owner' where id = 1;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'open_brain_training_nonprivate', 'fz_brain_config',
    jsonb_build_object('on', coalesce(p_on, false)));
  return public.open_brain_routing();
end $$;
revoke all on function public.open_brain_set_training_nonprivate(boolean) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then
    revoke all on function public.open_brain_routing() from fz_jarvis, fz_office_agent, fz_auditor;
    revoke all on function public.open_brain_set_owner_chat_free(boolean) from fz_jarvis, fz_office_agent, fz_auditor;
    revoke all on function public.open_brain_set_training_nonprivate(boolean) from fz_jarvis, fz_office_agent, fz_auditor;
  end if;
end $$;

reset lock_timeout;
