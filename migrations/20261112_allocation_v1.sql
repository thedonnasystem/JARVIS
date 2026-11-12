-- Capital allocation across ventures (spec 10.5). Each venture's monthly ceiling is a slice of money that really exists:
-- the total of all ceilings can never exceed what the capital controller says is available. Owner-only; needs ventures_v1, capital_v1.
create or replace function public.set_venture_budget(p_slug text, p_cents int, p_by text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare v public.ventures; v_other int; v_avail int;
begin
  if p_by is null or p_by not like 'owner%' then raise exception 'Only the owner allocates capital.'; end if;
  if p_cents is null or p_cents < 0 then return 'Budget must be zero or more.'; end if;
  select * into v from ventures where slug = p_slug;
  if v.id is null then return 'No venture ' || coalesce(p_slug, '?') || '.'; end if;
  select coalesce(sum(monthly_budget_cents), 0) into v_other from ventures where id <> v.id and status in ('active','proposed');
  v_avail := coalesce((public.capital_snapshot()->>'available_cents')::int, 0);
  if v_other + p_cents > v_avail then
    return format('Refused: ceilings would total $%s but only $%s is available. Allocations never exceed real money.',
                  to_char((v_other + p_cents) / 100.0, 'FM999,990.00'), to_char(v_avail / 100.0, 'FM999,990.00'));
  end if;
  update ventures set monthly_budget_cents = p_cents where id = v.id;
  insert into audit_log (actor, action, target, detail) values (p_by, 'venture_budget_set', 'ventures/' || p_slug, jsonb_build_object('cents', p_cents, 'was', v.monthly_budget_cents));
  return format('%s monthly ceiling is now $%s. Total allocated $%s of $%s available.', v.name, to_char(p_cents / 100.0, 'FM999,990.00'),
                to_char((v_other + p_cents) / 100.0, 'FM999,990.00'), to_char(v_avail / 100.0, 'FM999,990.00'));
end $$;

create or replace function public.allocation_text() returns text language plpgsql stable security definer set search_path to 'public' as $$
declare r record; out text := ''; tot int := 0; v_avail int := coalesce((public.capital_snapshot()->>'available_cents')::int, 0); used int;
begin
  for r in select slug, name, status, monthly_budget_cents from ventures where status in ('active','proposed') order by slug loop
    used := coalesce((public.venture_workspace(r.slug)->>'ai_spend_30d_cents')::int, 0);
    out := out || format(E'%s [%s]: ceiling $%s, AI used (30d) $%s%s\n', r.slug, r.status, to_char(r.monthly_budget_cents / 100.0, 'FM999,990.00'),
                         to_char(used / 100.0, 'FM999,990.00'), case when r.monthly_budget_cents > 0 and used > r.monthly_budget_cents then ' OVER' else '' end);
    tot := tot + r.monthly_budget_cents;
  end loop;
  return out || format('Allocated $%s of $%s available.', to_char(tot / 100.0, 'FM999,990.00'), to_char(v_avail / 100.0, 'FM999,990.00'));
end $$;
revoke all on function public.set_venture_budget(text, int, text), public.allocation_text() from public, anon, authenticated;
