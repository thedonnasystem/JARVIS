-- FENDEZY GROUP: "Donna Client Agents v1": a paying client's own Donna phone agent on the owner's Retell account, and the monthly report that shows the client
-- what it caught. ADDITIVE, after Donna Ops v1 (20261207) and the Revenue Loop (20261210). Design: docs/architecture/DONNA_CLIENT_AGENTS_V1.md.
--   * schema fz_donna_ca (NO API privileges): agents (one per intake, the Retell ids and the hash of the exact spec the OWNER confirmed); reports (one per agent and month).
--   * donna_intake_for_agent: the intake (by id or client label) a spec is built from; refused for a rejected intake.
--   * donna_record_client_agent: records the agent the bot created after the owner typed the confirm code in Telegram (the code is the spec hash; the bot checks it).
--     Creating the agent costs nothing on Retell; a phone number (which costs money) is never bought here.
--   * donna_client_agents / donna_record_client_report: the list, and one report per agent and month (the report itself is an email draft that goes to the
--     existing owner-tap outbox gate through donna_stage_outbox).
-- Nothing here sends, pays, deploys or changes a permission. Service path only; Donna must be ACTIVE. Ordered BEFORE the lockdown. Safe to re-run.

set lock_timeout = '5s';

create schema if not exists fz_donna_ca;
revoke all on schema fz_donna_ca from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_donna_ca from %I', r); end if;
  end loop;
end $$;

create table if not exists fz_donna_ca.agents (
  id uuid primary key default gen_random_uuid(),
  intake_id uuid not null unique references fz_donna.intakes (id),
  client_label text not null,
  lead_id uuid references public.leads (id),
  retell_agent_id text not null unique check (retell_agent_id ~ '^[A-Za-z0-9_-]{6,80}$'),
  retell_llm_id text not null check (retell_llm_id ~ '^[A-Za-z0-9_-]{6,80}$'),
  spec_sha text not null check (spec_sha ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
revoke all on fz_donna_ca.agents from public;

create table if not exists fz_donna_ca.reports (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references fz_donna_ca.agents (id),
  period text not null check (period ~ '^20[0-9]{2}-(0[1-9]|1[0-2])$'),
  draft_id uuid references fz_donna.drafts (id),
  stats jsonb not null default '{}'::jsonb check (jsonb_typeof(stats) = 'object' and length(stats::text) <= 4000),
  created_at timestamptz not null default now(),
  unique (agent_id, period)
);
revoke all on fz_donna_ca.reports from public;

create or replace function public.donna_intake_for_agent(p_ref text) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare i fz_donna.intakes; a fz_donna_ca.agents;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  if p_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into i from fz_donna.intakes where id = p_ref::uuid;
  else
    select * into i from fz_donna.intakes where lower(client_label) = lower(btrim(coalesce(p_ref, ''))) order by created_at desc limit 1;
  end if;
  if i.id is null then raise exception 'refused: no intake for %', left(coalesce(p_ref, ''), 80) using errcode = '42501'; end if;
  if i.status = 'owner_rejected' then raise exception 'refused: that intake was rejected' using errcode = '42501'; end if;
  select * into a from fz_donna_ca.agents where intake_id = i.id;
  return jsonb_build_object('intake', i.id, 'client_label', i.client_label, 'lead', i.lead_id, 'status', i.status, 'reception_config', i.reception_config,
                            'open_items', i.open_items, 'agent', case when a.id is null then null else jsonb_build_object('id', a.id, 'retell_agent_id', a.retell_agent_id,
                            'spec_sha', a.spec_sha, 'created_at', a.created_at) end);
end $$;
revoke all on function public.donna_intake_for_agent(text) from public, anon, authenticated;

create or replace function public.donna_record_client_agent(p_intake uuid, p_agent text, p_llm text, p_spec_sha text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare i fz_donna.intakes; v_id uuid;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into i from fz_donna.intakes where id = p_intake;
  if i.id is null or i.status = 'owner_rejected' then raise exception 'refused: unknown or rejected intake' using errcode = '42501'; end if;
  if exists (select 1 from fz_donna_ca.agents where intake_id = p_intake) then raise exception 'refused: this client already has an agent' using errcode = '42501'; end if;
  insert into fz_donna_ca.agents (intake_id, client_label, lead_id, retell_agent_id, retell_llm_id, spec_sha) values (i.id, i.client_label, i.lead_id, p_agent, p_llm, p_spec_sha)
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_client_agent', 'fz_donna_ca.agents/' || v_id,
                                                                       jsonb_build_object('intake', i.id, 'retell_agent', p_agent, 'spec_sha', p_spec_sha));
  return jsonb_build_object('agent', v_id);
end $$;
revoke all on function public.donna_record_client_agent(uuid, text, text, text) from public, anon, authenticated;

create or replace function public.donna_client_agents() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.guard();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'intake', a.intake_id, 'client_label', a.client_label, 'lead', a.lead_id, 'retell_agent_id', a.retell_agent_id,
                                                       'created_at', a.created_at, 'reception_config', i.reception_config,
                                                       'last_report', (select max(r.period) from fz_donna_ca.reports r where r.agent_id = a.id)) order by a.created_at)
                     from fz_donna_ca.agents a join fz_donna.intakes i on i.id = a.intake_id), '[]'::jsonb);
end $$;
revoke all on function public.donna_client_agents() from public, anon, authenticated;

create or replace function public.donna_record_client_report(p_agent uuid, p_period text, p_draft uuid, p_stats jsonb) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_id uuid;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  if not exists (select 1 from fz_donna_ca.agents where id = p_agent) then raise exception 'refused: unknown client agent' using errcode = '42501'; end if;
  if p_draft is not null and not exists (select 1 from fz_donna.drafts where id = p_draft) then raise exception 'refused: unknown draft' using errcode = '42501'; end if;
  insert into fz_donna_ca.reports (agent_id, period, draft_id, stats) values (p_agent, p_period, p_draft, coalesce(p_stats, '{}'::jsonb))
    on conflict (agent_id, period) do nothing returning id into v_id;
  return jsonb_build_object('report', v_id, 'duplicate', v_id is null);
end $$;
revoke all on function public.donna_record_client_report(uuid, text, uuid, jsonb) from public, anon, authenticated;
