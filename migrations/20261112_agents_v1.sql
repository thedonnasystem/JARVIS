-- Jarvis can grow the company's structure (Section 12) without a human typing SQL, inside hard limits:
--   * departments and agents are created through these functions only
--   * a new agent is cheap or standard tier, cap <= 50 cents/day, cannot contact the owner, and starts ACTIVE only while the total of all
--     active agent daily caps stays within 3x the company daily cap (so a swarm cannot be created past the budget)
--   * at most 3 agents may be created per 7 days; more need the owner (raise nothing silently)
--   * every creation is logged in org_changes (status 'built') and audit_log, and the owner is told in the next brief
-- Depends on org_v1 (org_changes).

create or replace function public.create_department(p_slug text, p_name text, p_venture_slug text default null, p_by text default 'jarvis')
returns text language plpgsql set search_path to 'public' as $$
declare v_vid uuid;
begin
  if p_slug !~ '^[a-z][a-z0-9-]{2,40}$' then raise exception 'Department slug must be 3-41 chars: lowercase letters, digits, dashes.'; end if;
  if length(coalesce(p_name, '')) < 3 then raise exception 'Department needs a name.'; end if;
  if exists (select 1 from public.departments where slug = p_slug) then raise exception 'Department % already exists.', p_slug; end if;
  if p_venture_slug is not null then
    select id into v_vid from public.ventures where slug = p_venture_slug;
    if v_vid is null then raise exception 'No venture %', p_venture_slug; end if;
  end if;
  insert into public.departments (slug, name, venture_id, kind, status) values (p_slug, p_name, v_vid, case when v_vid is null then 'shared' else 'venture' end, 'active');
  insert into public.org_changes (kind, proposed_by, change, status, decided_at) values ('department', p_by, 'Created department ' || p_slug || ' (' || p_name || ')', 'built', now());
  insert into public.audit_log (actor, action, target, detail) values (p_by, 'department_created', 'departments/' || p_slug, jsonb_build_object('venture', p_venture_slug));
  return p_slug;
end $$;

create or replace function public.create_agent(p_slug text, p_title text, p_department text, p_role text, p_tier text, p_cap_cents int,
                                               p_charter text, p_metric text, p_by text default 'jarvis')
returns text language plpgsql set search_path to 'public' as $$
declare v_vid uuid; v_cap int := least(greatest(coalesce(p_cap_cents, 15), 1), 50); v_total int; v_company int; v_recent int; v_status text := 'active';
begin
  if p_slug !~ '^[a-z][a-z0-9-]{2,50}$' then raise exception 'Agent slug must be 3-51 chars: lowercase letters, digits, dashes.'; end if;
  if exists (select 1 from public.agents where slug = p_slug) then raise exception 'Agent % already exists.', p_slug; end if;
  if p_tier not in ('cheap','standard') then raise exception 'New agents are cheap or standard tier; a strong tier agent needs the owner.'; end if;
  if p_role not in ('researcher','specialist','ops','finance','auditor','builder','compliance','gm') then raise exception 'Role % is not allowed for a new agent.', p_role; end if;
  if length(coalesce(p_charter, '')) < 30 or length(coalesce(p_metric, '')) < 3 then raise exception 'An agent needs a charter (what it does, 30+ chars) and a metric.'; end if;
  select venture_id into v_vid from public.departments where slug = p_department;
  if not found then raise exception 'No department %', p_department; end if;
  select count(*) into v_recent from public.org_changes where kind = 'agent' and status = 'built' and created_at > now() - interval '7 days';
  if v_recent >= 3 then raise exception 'Already created % agents this week (max 3). Ask the owner to approve more.', v_recent; end if;
  select coalesce(sum(daily_spend_cap_cents), 0) into v_total from public.agents where status = 'active';
  select daily_spend_cap_cents into v_company from public.system_state where id = 1;
  if v_total + v_cap > 3 * coalesce(v_company, 300) then v_status := 'paused'; end if;   -- over the cap budget: created but asleep
  insert into public.agents (slug, title, venture_id, charter, metric, daily_spend_cap_cents, status, department_slug, role, model_tier, can_contact_owner)
  values (p_slug, p_title, v_vid, p_charter, p_metric, v_cap, v_status, p_department, p_role, p_tier, false);
  insert into public.org_changes (kind, proposed_by, change, cost, status, decided_at, target)
  values ('agent', p_by, 'Created agent ' || p_slug || ' (' || p_role || ', ' || p_tier || ') in ' || p_department || case when v_status = 'paused' then ' [created asleep: caps budget full]' else '' end,
          v_cap || ' cents/day cap', 'built', now(), p_slug);
  insert into public.audit_log (actor, action, target, detail) values (p_by, 'agent_created', 'agents/' || p_slug, jsonb_build_object('cap', v_cap, 'tier', p_tier, 'status', v_status));
  return v_status;
end $$;
