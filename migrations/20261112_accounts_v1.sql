-- Account requests (spec 11 + your Nov 12 note). Agents cannot browse or sign up on their own here, and captchas, ID checks and
-- payment steps always belong to you, so the workflow is: Jarvis requests -> you approve -> you (or a browser session you start)
-- sign up with the business email/number you chose -> `/account done` records it as a venture asset. No passwords are stored.
insert into public.action_policy (action, tier, description, max_cents_per_action, max_count_per_day, max_cents_per_week, live_only) values
 ('account_request','yellow','Ask the owner to create a business account (he signs up himself)', null, 3, null, false)
on conflict (action) do nothing;

create table if not exists public.account_requests (
  id uuid primary key default gen_random_uuid(),
  vendor text not null check (length(vendor) >= 2),
  purpose text not null check (length(purpose) >= 5),
  venture_id uuid references public.ventures(id),
  signup_url text,
  est_monthly_cents int not null default 0 check (est_monthly_cents >= 0),
  needs text[] not null default '{}',            -- steps only the owner can do: captcha, email_code, sms_code, id, payment
  status text not null default 'awaiting_owner' check (status in ('awaiting_owner','approved','created','rejected')),
  requested_by text not null,
  account_login text,                            -- username or email only, never a password
  asset_id uuid references public.venture_assets(id),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  created_on timestamptz
);
alter table public.account_requests enable row level security;

create or replace function public.request_account(p_actor text, p_vendor text, p_purpose text, p_venture_slug text, p_url text,
                                                  p_monthly_cents int, p_needs text[])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_v uuid; v_id uuid; r jsonb;
begin
  if exists (select 1 from account_requests where lower(vendor) = lower(p_vendor) and status in ('awaiting_owner','approved')
             and coalesce(venture_id::text,'') = coalesce((select id::text from ventures where slug = p_venture_slug),'')) then
    return jsonb_build_object('decision','deny','reason','An open request for that vendor already exists.');
  end if;
  r := public.authorize_action(p_actor, 'account_request', coalesce(p_monthly_cents, 0), p_vendor, null, null, jsonb_build_object('purpose', p_purpose));
  if r->>'decision' = 'deny' then return r; end if;       -- ask_owner is expected: the owner approves below
  select id into v_v from ventures where slug = p_venture_slug;
  insert into account_requests (vendor, purpose, venture_id, signup_url, est_monthly_cents, needs, requested_by)
    values (p_vendor, p_purpose, v_v, p_url, greatest(coalesce(p_monthly_cents, 0), 0), coalesce(p_needs, '{}'), p_actor) returning id into v_id;
  insert into owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
    values ('jarvis', 'proposal', 'telegram',
            format(E'Account to create: %s\nFor: %s%s%s\nSteps only you can do: %s\nIf you approve, sign up with your business email/number, then send /account done %s <login email or username>. Never send me the password.',
                   p_vendor, p_purpose, case when p_url is null then '' else E'\nSign-up: ' || p_url end,
                   case when coalesce(p_monthly_cents,0) > 0 then E'\nCost: about $' || to_char(p_monthly_cents / 100.0, 'FM999,990.00') || '/month (needs a payment instruction if it costs money)' else E'\nCost: free tier' end,
                   case when coalesce(array_length(p_needs, 1), 0) = 0 then 'captcha or verification codes if asked' else array_to_string(p_needs, ', ') end,
                   left(v_id::text, 8)),
            true, 'account_requests', v_id);
  return jsonb_build_object('decision','ask_owner','request_id', v_id, 'reason','Waiting for the owner.');
end $$;

create or replace function public.decide_account(p_id uuid, p_approved boolean, p_by text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare a public.account_requests;
begin
  if p_by is null or p_by not like 'owner%' then raise exception 'Only the owner decides accounts.'; end if;
  select * into a from account_requests where id = p_id and status = 'awaiting_owner' for update;
  if a.id is null then return 'Not waiting for a decision.'; end if;
  update account_requests set status = case when p_approved then 'approved' else 'rejected' end, decided_at = now() where id = p_id;
  return case when p_approved then format('Approved: %s. Sign up%s, then /account done %s <login email or username>.', a.vendor,
                                          case when a.signup_url is null then '' else ' at ' || a.signup_url end, left(p_id::text, 8))
              else 'Rejected.' end;
end $$;

create or replace function public.complete_account(p_id uuid, p_login text, p_by text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare a public.account_requests; v_asset uuid;
begin
  if p_by is null or p_by not like 'owner%' then raise exception 'Only the owner confirms an account.'; end if;
  if p_login is null or length(trim(p_login)) < 3 then return 'Send the login email or username (never the password).'; end if;
  if p_login ~* '(password|passwd|pwd)\s*[:=]' then return 'Refused: do not send passwords. Send only the login email or username.'; end if;
  select * into a from account_requests where id = p_id and status = 'approved' for update;
  if a.id is null then return 'No approved account request with that id.'; end if;
  insert into venture_assets (venture_id, kind, name, url, status, notes, created_by)
    values (a.venture_id, 'account', a.vendor, a.signup_url, 'live', 'Login: ' || left(trim(p_login), 120) || '. ' || a.purpose, p_by) returning id into v_asset;
  update account_requests set status = 'created', account_login = left(trim(p_login), 120), asset_id = v_asset, created_on = now() where id = p_id;
  return format('Recorded: %s account (%s). Saved as a venture asset; no password stored.', a.vendor, left(trim(p_login), 120));
end $$;

create or replace function public.accounts_text() returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(string_agg(format('%s  %s  (%s)  id %s', status, vendor, purpose, left(id::text, 8)), E'\n' order by created_at), 'No open account requests.')
  from account_requests where status in ('awaiting_owner','approved')
$$;
revoke all on function public.request_account(text, text, text, text, text, int, text[]), public.decide_account(uuid, boolean, text),
  public.complete_account(uuid, text, text), public.accounts_text() from public, anon, authenticated;
