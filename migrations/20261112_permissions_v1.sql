-- Phase 4: permissions engine (Green / Yellow / Red / Prohibited), enforced in the database.
-- Modes (system_state.mode): dry_run = no external actions; approve_first = Yellow needs the owner too;
-- auto_in_caps / exceptions_only = Yellow runs inside its limits.
-- Additive. Default-deny: an action that is not in action_policy is refused.
-- Agents never get SQL; the only write path to action_policy is the owner's /policy command.

create table if not exists public.action_policy (
  action text primary key check (action ~ '^[a-z][a-z0-9_]{2,60}$'),
  tier text not null check (tier in ('green','yellow','red','prohibited')),
  description text not null,
  max_cents_per_action int check (max_cents_per_action is null or max_cents_per_action >= 0),  -- CAD cents
  max_count_per_day int check (max_count_per_day is null or max_count_per_day >= 0),
  max_cents_per_week int check (max_cents_per_week is null or max_cents_per_week >= 0),         -- CAD cents
  live_only boolean not null default false,  -- refused while system_state.mode = 'dry_run'
  updated_by text not null default 'seed',
  updated_at timestamptz not null default now()
);
alter table public.action_policy enable row level security;

create table if not exists public.action_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor text not null,
  action text not null,
  tier text,
  decision text not null check (decision in ('allow','deny','ask_owner')),
  reason text,
  cents int not null default 0,
  venture_id uuid,
  mission_id uuid,
  ref text,                       -- what it's about (task/outbox/account id, URL...)
  detail jsonb not null default '{}'::jsonb,
  approval_id uuid,
  result text,                    -- filled by the caller after it acts (ok / failed: ...)
  evidence text,                  -- proof the action happened (provider id, URL, receipt)
  verified boolean
);
alter table public.action_log enable row level security;
create index if not exists action_log_action_at on public.action_log(action, at desc);

create table if not exists public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  actor text not null,
  action text not null,
  cents int not null default 0,
  ref text,
  recommendation text not null,   -- the agent's case: recommendation, numbers, risks, alternatives, cost of doing nothing
  status text not null default 'pending' check (status in ('pending','approved','rejected','used','expired')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  expires_at timestamptz not null default now() + interval '7 days'
);
alter table public.approval_requests enable row level security;

-- Seed policy from the master spec. Money limits are conservative placeholders until the owner sets them.
insert into public.action_policy (action, tier, description, max_cents_per_action, max_count_per_day, max_cents_per_week, live_only) values
 ('research','green','Web research and analysis',null,null,null,false),
 ('internal_document','green','Create internal docs, plans, financial models',null,null,null,false),
 ('write_code','green','Write code in an HQ workspace',null,null,null,false),
 ('build_internal_tool','green','Build/test internal tools and workflows',null,null,null,false),
 ('build_website_preview','green','Build and test a website on a preview URL',null,null,null,false),
 ('manage_tasks','green','Create, assign and update HQ tasks and missions',null,null,null,false),
 ('create_temp_agent','green','Create a temporary specialist agent (within existing caps)',null,null,null,false),
 ('update_internal_records','green','Update internal records',null,null,null,false),
 ('fix_routine_issue','green','Fix routine technical problems',null,null,null,false),
 ('llm_call','green','Model call through the spend gateway (its own caps apply)',null,null,null,false),
 ('send_email','yellow','Send an approved outbox email to a prospect or customer',null,20,null,true),
 ('customer_message','yellow','Reply to an existing customer',null,30,null,true),
 ('prospect_outreach','yellow','First contact with a prospect (CASL rules apply)',null,20,null,true),
 ('publish_content','yellow','Publish approved business content',null,5,null,true),
 ('deploy_website','yellow','Deploy a website to a public URL',null,3,null,true),
 ('create_account','yellow','Create a business software account (no ID/KYC/payment steps; those go to the owner)',null,2,null,true),
 ('subscription_purchase','yellow','Start a paid subscription',2500,1,5000,true),
 ('software_purchase','yellow','One-off software purchase',2500,1,5000,true),
 ('routine_expense','yellow','Routine business expense',2000,3,5000,true),
 ('advertising','yellow','Paid advertising spend',2000,1,5000,true),
 ('hire_contractor','yellow','Hire a contractor for a pre-approved scope',5000,1,5000,true),
 ('vendor_negotiation','yellow','Routine vendor negotiation (no commitment)',null,5,null,true),
 ('take_loan','red','Take on debt',null,null,null,true),
 ('acquire_business','red','Acquire a business',null,null,null,true),
 ('sell_business','red','Sell a business',null,null,null,true),
 ('sign_contract','red','Sign a major contract',null,null,null,true),
 ('legal_obligation','red','Create a major legal obligation',null,null,null,true),
 ('financial_transfer','red','Significant transfer of money',null,null,null,true),
 ('change_banking_permissions','red','Change banking permissions',null,null,null,true),
 ('irreversible_decision','red','Irreversible material decision',null,null,null,true),
 ('close_venture','red','Close or materially restructure an established venture',null,null,null,true),
 ('restructure_holding','red','Major change to the holding company',null,null,null,true),
 ('access_personal_bank','prohibited','Access the owner''s personal bank accounts',null,null,null,false),
 ('access_personal_finance','prohibited','Access unrelated personal financial accounts',null,null,null,false),
 ('bypass_verification','prohibited','Bypass CAPTCHA, KYC, identity verification or security',null,null,null,false),
 ('fabricate','prohibited','Fabricate results or information',null,null,null,false),
 ('spend_outside_budget','prohibited','Spend outside authorized budgets',null,null,null,false),
 ('modify_own_permissions','prohibited','Change its own permissions, policy or spending limits',null,null,null,false),
 ('evade_platform_restrictions','prohibited','Evade platform restrictions or create accounts to dodge limits',null,null,null,false),
 ('deceptive_communication','prohibited','Send unlawful or deceptive communications',null,null,null,false)
on conflict (action) do nothing;

-- The one gate every external action asks. Writes an action_log row for every decision.
create or replace function public.authorize_action(
  p_actor text, p_action text, p_cents int default 0, p_ref text default null,
  p_venture uuid default null, p_mission uuid default null, p_detail jsonb default '{}'::jsonb)
returns jsonb language plpgsql set search_path to 'public' as $$
declare
  pol public.action_policy%rowtype; st record; v_decision text; v_reason text;
  v_today int; v_week int; v_approval uuid; v_start timestamptz;
begin
  perform pg_advisory_xact_lock(7332);
  select kill_switch, mode into st from public.system_state where id = 1;
  select * into pol from public.action_policy where action = p_action;
  p_cents := greatest(coalesce(p_cents, 0), 0);

  if st.kill_switch then
    v_decision := 'deny'; v_reason := 'Kill switch is on.';
  elsif not found then
    v_decision := 'deny'; v_reason := 'Unknown action: everything not in the policy is refused.';
  elsif pol.tier = 'prohibited' then
    v_decision := 'deny'; v_reason := 'Prohibited by policy: ' || pol.description;
  elsif pol.live_only and st.mode = 'dry_run' then
    v_decision := 'deny'; v_reason := 'Dry-run mode: external actions are switched off.';
  elsif pol.tier = 'red' or (pol.tier = 'yellow' and st.mode = 'approve_first') then
    -- Red always needs the owner; in approve_first mode Yellow does too. One approval = one use.
    select id into v_approval from public.approval_requests
      where action = p_action and status = 'approved' and coalesce(ref,'') = coalesce(p_ref,'')
        and cents >= p_cents and expires_at > now()
      order by decided_at limit 1 for update;
    if v_approval is not null then
      update public.approval_requests set status = 'used' where id = v_approval;
      v_decision := 'allow'; v_reason := 'Owner approved this specific action.';
    else
      v_decision := 'ask_owner';
      v_reason := case when pol.tier = 'red' then 'Red action: needs the owner''s decision first.'
                       else 'Approve-first mode: the owner OKs each external action.' end;
    end if;
  else
    v_start := date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
    select count(*) into v_today from public.action_log where action = p_action and decision = 'allow' and at >= v_start;
    select coalesce(sum(cents), 0) into v_week from public.action_log
      where action = p_action and decision = 'allow' and at >= now() - interval '7 days';
    if pol.max_cents_per_action is not null and p_cents > pol.max_cents_per_action then
      v_decision := 'ask_owner'; v_reason := format('Over the per-action limit ($%s > $%s).', p_cents/100.0, pol.max_cents_per_action/100.0);
    elsif pol.max_count_per_day is not null and v_today >= pol.max_count_per_day then
      v_decision := 'deny'; v_reason := format('Daily limit reached (%s per day).', pol.max_count_per_day);
    elsif pol.max_cents_per_week is not null and v_week + p_cents > pol.max_cents_per_week then
      v_decision := 'ask_owner'; v_reason := format('Weekly limit would be passed ($%s of $%s used).', v_week/100.0, pol.max_cents_per_week/100.0);
    else
      v_decision := 'allow'; v_reason := initcap(pol.tier) || ' action within policy.';
    end if;
  end if;

  insert into public.action_log (actor, action, tier, decision, reason, cents, venture_id, mission_id, ref, detail, approval_id)
    values (p_actor, p_action, pol.tier, v_decision, v_reason, p_cents, p_venture, p_mission, p_ref, coalesce(p_detail,'{}'::jsonb), v_approval);
  if v_decision = 'deny' and pol.tier = 'prohibited' then
    insert into public.escalations (from_agent, kind, summary)  -- from_agent must be a known agent
      values (coalesce((select slug from public.agents where slug = p_actor), 'jarvis'), 'failure',
              format('Policy: %s tried a prohibited action (%s). Refused.', p_actor, p_action));
  end if;
  return jsonb_build_object('decision', v_decision, 'reason', v_reason, 'tier', pol.tier);
end $$;

-- The caller reports what actually happened (verification engine: evidence, not claims).
create or replace function public.record_action_result(p_log_id bigint, p_result text, p_evidence text, p_verified boolean)
returns void language sql set search_path to 'public' as $$
  update public.action_log set result = left(p_result, 500), evidence = left(p_evidence, 1000), verified = p_verified
  where id = p_log_id and result is null;
$$;

-- Policy changes only via the owner path; every change is audited.
create or replace function public.audit_policy_change()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.updated_by is null or new.updated_by not like 'owner%' then
    if tg_op = 'UPDATE' then raise exception 'Only the owner can change the action policy.'; end if;
  end if;
  new.updated_at := now();
  insert into public.audit_log (actor, action, target, detail)
    values (coalesce(new.updated_by,'unknown'), 'policy_' || lower(tg_op), new.action,
            jsonb_build_object('tier', new.tier, 'per_action', new.max_cents_per_action, 'per_day', new.max_count_per_day,
                               'per_week', new.max_cents_per_week, 'live_only', new.live_only));
  return new;
end $$;
drop trigger if exists action_policy_audit on public.action_policy;
create trigger action_policy_audit before insert or update on public.action_policy
  for each row execute function public.audit_policy_change();
create or replace function public.forbid_policy_delete() returns trigger language plpgsql as $$
begin raise exception 'Policy rows cannot be deleted; set the tier instead.'; end $$;
drop trigger if exists action_policy_no_delete on public.action_policy;
create trigger action_policy_no_delete before delete on public.action_policy
  for each row execute function public.forbid_policy_delete();

-- Outbox fix: the owner sending an approved email himself (/sent) is a record, not an agent send.
-- Before this, dry-run mode refused the owner's own /sent. Agents' sends stay fully gated.
alter table public.outbox add column if not exists sent_by text;

CREATE OR REPLACE FUNCTION public.enforce_outbox_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_mode text; v_ks boolean; v_owner boolean;
begin
  select mode, kill_switch into v_mode, v_ks from public.system_state where id = 1;
  v_owner := coalesce(new.sent_by, '') = 'owner';

  if tg_op = 'INSERT' and new.status <> 'draft' then
    raise exception 'New outbox rows must start as draft.';
  end if;

  if exists (select 1 from public.leads l
             where l.do_not_contact
               and (l.id = new.lead_id or (new.to_ref is not null and (l.phone = new.to_ref or l.email = new.to_ref)))) then
    raise exception 'Recipient is on the do-not-contact list.';
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'qa_passed' then
      if old.status <> 'draft' then raise exception 'Only a draft can pass QA.'; end if;
      if new.qa_agent is null or new.qa_agent = new.agent then
        raise exception 'QA must be done by a different agent than the one who wrote the message.';
      end if;
    elsif new.status = 'approved' then
      if old.status <> 'qa_passed' then raise exception 'A message must pass QA before approval.'; end if;
    elsif new.status = 'sent' then
      if old.status <> 'approved' then raise exception 'A message must be approved before sending.'; end if;
      if v_ks and not v_owner then raise exception 'Kill switch is on: nothing may be sent.'; end if;
      if v_mode = 'dry_run' and not v_owner then raise exception 'Dry run mode: nothing may be sent.'; end if;
      if new.lead_id is not null and exists (
           select 1 from public.outbox o
           where o.lead_id = new.lead_id and o.status = 'sent' and o.id <> new.id
             and o.sent_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')) then
        raise exception 'Daily contact limit reached for this lead.';
      end if;
      new.sent_at := now();
    end if;
  end if;
  return new;
end $function$;

-- Outbox: sending is a Yellow action, so the send itself must pass the gate (on top of the existing outbox rules).
create or replace function public.outbox_send_policy()
returns trigger language plpgsql set search_path to 'public' as $$
declare r jsonb;
begin
  if tg_op = 'UPDATE' and new.status = 'sent' and old.status is distinct from 'sent'
     and coalesce(new.sent_by, '') <> 'owner' then  -- the owner's own sends are records, not agent actions
    r := public.authorize_action(coalesce(new.agent, 'unknown'), 'send_email', 0, new.id::text, null, null,
                                 jsonb_build_object('to', new.to_ref));
    if r->>'decision' <> 'allow' then
      raise exception 'Send refused by policy: %', r->>'reason';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists outbox_send_policy on public.outbox;
create trigger outbox_send_policy before update on public.outbox
  for each row execute function public.outbox_send_policy();
