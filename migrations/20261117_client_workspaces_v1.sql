-- Client workspaces v1 (FF Marketing OS data model; OPEN_SOURCE_EVALUATION.md milestone 3).
-- One reusable model, many isolated clients. Additive: four new tables, four new functions. Touches no existing table or function.
--   * isolation is enforced by the database, not by application code: every child row carries workspace_id, and composite foreign keys make
--     it impossible for a lead or spend row to point at another workspace's campaign
--   * SENSITIVE-DATA RULE (mortgage client): the AI must never receive applications, banking, credit, ID or sensitive financial data.
--     ws_guard() runs on every text column of every workspace table and REFUSES the write when ws_sensitive_hits() finds a hit. It is
--     fail-closed on purpose: false positives are cheaper than one leaked SIN. There is no free-form jsonb column to smuggle data through.
--   * default-deny money: monthly_budget_cents is NULL until the owner sets it; ws_record_spend refuses while it is NULL or would be exceeded
--     (nothing here moves money; real spending still goes through the HQ spend gateway and owner approval)
--   * RLS on with no policy; anon/authenticated have nothing; service_role may select only, every write goes through the functions below
create table if not exists public.client_workspaces (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  name text not null check (length(name) between 2 and 120),
  vertical text,
  status text not null default 'draft' check (status in ('draft', 'active', 'paused', 'closed')),
  monthly_budget_cents integer check (monthly_budget_cents is null or monthly_budget_cents >= 0),
  created_at timestamptz not null default now()
);
create table if not exists public.ws_campaigns (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  name text not null check (length(name) between 2 and 160),
  channel text,
  status text not null default 'draft' check (status in ('draft', 'approved', 'running', 'paused', 'done')),
  created_at timestamptz not null default now(),
  unique (workspace_id, id)
);
create table if not exists public.ws_leads (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  campaign_id uuid,
  name text not null check (length(name) between 1 and 160),
  email text,
  phone text,
  source text,
  stage text not null default 'new' check (stage in ('new', 'contacted', 'booked', 'handed_off', 'lost')),
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  foreign key (workspace_id, campaign_id) references public.ws_campaigns (workspace_id, id)
);
create table if not exists public.ws_ledger (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  campaign_id uuid,
  amount_cents integer not null check (amount_cents > 0),
  note text check (note is null or length(note) <= 300),
  created_at timestamptz not null default now(),
  foreign key (workspace_id, campaign_id) references public.ws_campaigns (workspace_id, id)
);
create index if not exists ws_leads_ws_idx on public.ws_leads (workspace_id, stage);
create index if not exists ws_ledger_ws_idx on public.ws_ledger (workspace_id, created_at);
do $$ declare t text; begin
  foreach t in array array['client_workspaces', 'ws_campaigns', 'ws_leads', 'ws_ledger'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to service_role', t);
    execute format('revoke insert, update, delete, truncate, trigger, references on public.%I from service_role', t);
  end loop;
end $$;

create or replace function public.ws_sensitive_hits(p_text text) returns text[]
language plpgsql immutable set search_path to 'public' as $$
declare t text; np text; c text; k text; kc text; hits text[] := '{}';
begin
  -- normalise first: zero-width characters out, NFKC (fullwidth digits etc.), Arabic-Indic / Persian digits to ASCII
  t := translate(normalize(regexp_replace(coalesce(p_text, ''), '[​-‍⁠﻿]', '', 'g'), NFKC),
                 '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
  k := lower(t);
  -- phone-shaped numbers are removed from the text first (NOT used to excuse the rest of it), then digits are compacted
  np := regexp_replace(t, '(\+?1[ .\-]?)?\(?[0-9]{3}\)?[ .\-]?[0-9]{3}[ .\-]?[0-9]{4}', ' ', 'g');
  c := regexp_replace(np, '[^[:alnum:]]', '', 'g');
  if c ~ '(^|[^0-9])[0-9]{9}([^0-9]|$)' then hits := hits || array['sin_like_number']; end if;
  if c ~ '[0-9]{13,19}' then hits := hits || array['card_like_number']; end if;
  if c ~ '(^|[^0-9])[0-9]{7,8}([^0-9]|$)' or c ~ '(^|[^0-9])[0-9]{10,12}([^0-9]|$)' then hits := hits || array['account_like_number']; end if;
  kc := regexp_replace(k, '[^a-z0-9]', '', 'g');
  if k ~ '(^|[^a-z])s[ ._\-]*i[ ._\-]*n([^a-z]|$)' or k ~ '(^|[^a-z])(ssn|nas)([^a-z]|$)'
     or kc ~ '(socialinsurance|passport|driverslicen|driverlicen|governmentid|healthcard|ohip|dateofbirth)' then hits := hits || array['identity_document']; end if;
  if kc ~ '(bankstatement|accountnumber|accountno|bankaccount|chequingaccount|routingnumber|transitnumber|institutionnumber|voidcheque|voidcheck|directdeposit|bankingdetails|iban)' then hits := hits || array['banking']; end if;
  if kc ~ '(creditscore|creditreport|creditcheck|credithistory|creditrating|equifax|transunion|experian|beaconscore)' or k ~ '(^|[^a-z])fico([^a-z]|$)' then hits := hits || array['credit']; end if;
  if kc ~ '(mortgageapplication|loanapplication|preapproval|noticeofassessment|paystub|employmentletter|incomeverification|proofofincome|networth|income|salary|taxreturn)'
     or k ~ '(^|[^a-z0-9])(t4a?|noa)([^a-z0-9]|$)' then hits := hits || array['application_or_income']; end if;
  return hits;
end $$;

create or replace function public.ws_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; hits text[]; allv text := '';
begin
  -- a value split across columns (name / phone / note) is caught by also scanning every scanned column joined together
  for k, v in select key, value from jsonb_each_text(to_jsonb(new) - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    allv := allv || ' ' || coalesce(v, '');
  end loop;
  hits := public.ws_sensitive_hits(allv);
  if array_length(hits, 1) > 0 then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(hits, ', ') using errcode = 'P0001';
  end if;
  for k, v in select key, value from jsonb_each_text(to_jsonb(new) - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    hits := public.ws_sensitive_hits(v);
    if array_length(hits, 1) > 0 then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(hits, ', ')
        using errcode = 'P0001';
    end if;
  end loop;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['client_workspaces', 'ws_campaigns', 'ws_leads', 'ws_ledger'] loop
    execute format('drop trigger if exists ws_guard on public.%I', t);
    execute format('create trigger ws_guard before insert or update on public.%I for each row execute function public.ws_guard()', t);
  end loop;
end $$;

create or replace function public.ws_add_lead(p_ws uuid, p_campaign uuid, p_name text, p_email text, p_phone text, p_source text, p_note text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not exists (select 1 from public.client_workspaces where id = p_ws and status in ('draft', 'active')) then raise exception 'workspace not found or not open'; end if;
  insert into public.ws_leads (workspace_id, campaign_id, name, email, phone, source, note) values (p_ws, p_campaign, p_name, p_email, p_phone, p_source, p_note) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ws', 'ws_lead_added', 'workspace/' || p_ws, jsonb_build_object('lead', v_id));
  return v_id;
end $$;

create or replace function public.ws_record_spend(p_ws uuid, p_campaign uuid, p_cents integer, p_note text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_budget integer; v_used integer; v_id uuid;
begin
  select monthly_budget_cents into v_budget from public.client_workspaces where id = p_ws and status = 'active' for update;
  if not found then raise exception 'workspace not found or not active'; end if;
  if v_budget is null then raise exception 'no monthly budget has been set for this workspace; spending is refused'; end if;
  select coalesce(sum(amount_cents), 0) into v_used from public.ws_ledger
    where workspace_id = p_ws and created_at >= date_trunc('month', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
  if v_used + p_cents > v_budget then raise exception 'workspace monthly budget would be exceeded'; end if;
  insert into public.ws_ledger (workspace_id, campaign_id, amount_cents, note) values (p_ws, p_campaign, p_cents, p_note) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ws', 'ws_spend_recorded', 'workspace/' || p_ws, jsonb_build_object('ledger', v_id, 'cents', p_cents));
  return v_id;
end $$;

create or replace function public.ws_summary(p_ws uuid) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'workspace', (select slug from public.client_workspaces where id = p_ws),
    'leads_by_stage', coalesce((select jsonb_object_agg(stage, n) from (select stage, count(*) n from public.ws_leads where workspace_id = p_ws group by stage) s), '{}'::jsonb),
    'campaigns', (select count(*) from public.ws_campaigns where workspace_id = p_ws),
    'spent_cents', (select coalesce(sum(amount_cents), 0) from public.ws_ledger where workspace_id = p_ws));
$$;

revoke all on function public.ws_sensitive_hits(text) from public, anon, authenticated;
revoke all on function public.ws_guard() from public, anon, authenticated;
revoke all on function public.ws_add_lead(uuid, uuid, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.ws_record_spend(uuid, uuid, integer, text) from public, anon, authenticated;
revoke all on function public.ws_summary(uuid) from public, anon, authenticated;
grant execute on function public.ws_sensitive_hits(text) to service_role;
grant execute on function public.ws_guard() to service_role;
grant execute on function public.ws_add_lead(uuid, uuid, text, text, text, text, text) to service_role;
grant execute on function public.ws_record_spend(uuid, uuid, integer, text) to service_role;
grant execute on function public.ws_summary(uuid) to service_role;
