alter table public.ideas
  add column if not exists demand_source text,
  add column if not exists kill_metric text,
  add column if not exists test_started_on date,
  add column if not exists test_ends_on date,
  add column if not exists score numeric generated always as (
    coalesce(speed_to_cash,0) * 2 + (6 - coalesce(effort,5)) - least(coalesce(startup_cost_cents,0) / 10000.0, 5)
  ) stored;
create unique index if not exists ideas_name_lower_uq on public.ideas (lower(name));
-- Max 3 revenue ventures at once: active ventures (minus the idea lab) plus ideas in test or scaled.
create or replace function public.enforce_max_active_ventures() returns trigger
language plpgsql set search_path = public as $$
declare v_active int;
begin
  if new.status in ('testing','scaled') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    select (select count(*) from ventures where status = 'active' and slug not in ('idea-lab','day-job-sales'))
         + (select count(*) from ideas where status in ('testing','scaled') and id <> new.id) into v_active;
    if v_active >= 3 then
      raise exception 'Max 3 revenue ventures at once (owner rule). Park or kill one first.';
    end if;
    if new.status = 'testing' then
      new.test_started_on := coalesce(new.test_started_on, current_date);
      new.test_ends_on := coalesce(new.test_ends_on, current_date + 7);
    end if;
  end if;
  return new;
end $$;
create trigger trg_max_active_ventures before insert or update of status on public.ideas
  for each row execute function public.enforce_max_active_ventures();