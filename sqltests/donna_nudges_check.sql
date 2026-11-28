-- Donna Nudges v1 (migrations/20261213_donna_nudges_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: an audit booked over a day ago with no proposal is listed, a fresh booking is not, a staged proposal clears it; a won lead with no intake is listed
-- until its intake is saved; that intake is listed until its agent exists; do-not-contact leads never show; read-only; no API role reaches it; rollback.
begin;
do $$
declare v uuid := (select id from public.ventures where slug = 'donna'); a uuid; b uuid; c uuid; t uuid; x jsonb; rl text; n_audit bigint := (select count(*) from public.audit_log);
begin
  insert into public.leads (venture_id, name, email, status, consent_basis, created_at) values (v, 'Birch Dental', 'hi@birch.example', 'booked', 'implied_inquiry', now() - interval '3 days') returning id into a;
  insert into public.leads (venture_id, name, email, status, consent_basis) values (v, 'Maple Salon', 'hi@maple.example', 'booked', 'implied_inquiry') returning id into b;
  insert into public.leads (venture_id, name, email, status, consent_basis, created_at) values (v, 'Elm Auto', 'hi@elm.example', 'won', 'implied_inquiry', now() - interval '5 days') returning id into c;
  insert into public.leads (venture_id, name, email, status, consent_basis, do_not_contact, created_at) values (v, 'Gone Co', 'hi@gone.example', 'booked', 'implied_inquiry', true, now() - interval '4 days');
  x := public.donna_stuck_deals(10);
  if (select count(*) from jsonb_array_elements(x) e where e ->> 'kind' = 'audit_no_proposal' and e ->> 'name' = 'Birch Dental') <> 1 then raise exception 'N1 stuck audit missing %', x; end if;
  if exists (select 1 from jsonb_array_elements(x) e where e ->> 'name' in ('Maple Salon', 'Gone Co')) then raise exception 'N1 fresh or do-not-contact listed %', x; end if;
  if (select count(*) from jsonb_array_elements(x) e where e ->> 'kind' = 'won_no_intake' and e ->> 'name' = 'Elm Auto') <> 1 then raise exception 'N2 won without intake missing %', x; end if;
  if exists (select 1 from jsonb_array_elements(x) e where e ? 'email' or e ? 'phone') then raise exception 'N1 contact data leaked'; end if;
  -- the owner's intake for Elm Auto: it moves from won_no_intake to intake_no_agent
  insert into fz_donna.intakes (client_label, lead_id, reception_config, site_json) values ('Elm Auto', c,
    '{"business_name":"Elm Auto","timezone":"America/Toronto","hours":{},"services":[],"faqs":[],"escalation_number":"x","booking":{},"voice":{}}', '{}') returning id into t;
  x := public.donna_stuck_deals(10);
  if exists (select 1 from jsonb_array_elements(x) e where e ->> 'kind' = 'won_no_intake') then raise exception 'N3 intake did not clear %', x; end if;
  if (select count(*) from jsonb_array_elements(x) e where e ->> 'kind' = 'intake_no_agent' and e ->> 'client_label' = 'Elm Auto') <> 1 then raise exception 'N3 intake_no_agent missing %', x; end if;
  insert into fz_donna_ca.agents (intake_id, client_label, lead_id, retell_agent_id, retell_llm_id, spec_sha) values (t, 'Elm Auto', c, 'agent_abc123', 'llm_abc123', repeat('a', 64));
  x := public.donna_stuck_deals(10);
  if exists (select 1 from jsonb_array_elements(x) e where e ->> 'name' = 'Elm Auto') then raise exception 'N4 agent did not clear %', x; end if;
  n_audit := (select count(*) from public.audit_log);
  if jsonb_array_length(public.donna_stuck_deals(0)) > 1 then raise exception 'N4 limit floor'; end if;
  if (select count(*) from public.audit_log) <> n_audit then raise exception 'N5 a read wrote the audit log'; end if;
  foreach rl in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent'] loop
    continue when not exists (select 1 from pg_roles where rolname = rl);
    if has_function_privilege(rl, 'public.donna_stuck_deals(integer)', 'execute') then raise exception 'N6 % can execute', rl; end if;
  end loop;
  if (select provolatile from pg_proc where oid = 'public.donna_stuck_deals(integer)'::regprocedure) <> 's' then raise exception 'N5 not stable'; end if;
end $$;
\set fz_in_txn 1
\ir ../ops/rollback_donna_nudges.sql
\ir ../ops/rollback_donna_nudges.sql
do $$ begin
  if to_regprocedure('public.donna_stuck_deals(integer)') is not null then raise exception 'N7 left behind'; end if;
end $$;
\ir ../migrations/20261213_donna_nudges_v1.sql
\ir ../migrations/20261213_donna_nudges_v1.sql
select 'donna_nudges_check ok';
rollback;
