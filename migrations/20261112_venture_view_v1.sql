-- Owner-only venture drill-down for the app (needs ventures_v1 and webapp_v1).
create or replace function public.app_venture(p_slug text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v record;
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  select * into v from ventures where slug = p_slug;
  if not found then return null; end if;
  return jsonb_build_object(
    'slug', v.slug, 'name', v.name, 'status', v.status, 'stage', v.stage, 'metric', v.primary_metric,
    'budget_cents', v.monthly_budget_cents, 'description', left(v.description, 600),
    'goals', (select coalesce(jsonb_agg(jsonb_build_object('metric', metric, 'target', target_value, 'now', current_value, 'status', status, 'due', due_on) order by created_at desc), '[]'::jsonb)
              from (select * from venture_goals where venture_id = v.id order by created_at desc limit 8) g),
    'memory', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'content', left(content, 240), 'at', created_at) order by created_at desc), '[]'::jsonb)
               from (select * from memory where venture_id = v.id order by created_at desc limit 8) m),
    'tasks', (select coalesce(jsonb_agg(jsonb_build_object('title', left(title, 120), 'agent', assigned_agent, 'status', status) order by updated_at desc), '[]'::jsonb)
              from (select * from tasks where venture_id = v.id order by updated_at desc limit 8) t),
    'cash_in_cents', (select coalesce(sum(amount_cents), 0) from ledger where venture_id = v.id and kind = 'revenue' and status = 'received'),
    'cash_out_cents', (select coalesce(sum(amount_cents), 0) from ledger where venture_id = v.id and kind = 'expense'),
    'leads', (select count(*) from leads where venture_id = v.id));
end $$;
revoke all on function public.app_venture(text) from public, anon;
grant execute on function public.app_venture(text) to authenticated;
