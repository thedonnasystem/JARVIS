-- Phase 1: Jarvis's own chat / research / content model calls go through the spend gateway as this agent.
-- 150 CAD cents a day (~20-40 chat turns on the strong model); it also counts toward the company cap.
-- It never receives HQ tasks (the engine, planner and missions exclude it).
insert into public.agents (slug, title, role, model_tier, daily_spend_cap_cents, status, can_contact_owner, charter, metric)
values ('jarvis-chat', 'Jarvis (owner chat)', 'specialist', 'strong', 150, 'active', false,
        'Meters the owner''s direct conversation with Jarvis. Not a task agent.', 'owner questions answered')
on conflict (slug) do nothing;
