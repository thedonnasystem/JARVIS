create or replace view public.agent_accuracy as
select agent_slug,
  count(*) as predictions,
  count(*) filter (where correct is true) as right_calls,
  count(*) filter (where correct is false) as wrong_calls,
  count(*) filter (where correct is null) as unresolved,
  round(100.0 * count(*) filter (where correct is true) / nullif(count(*) filter (where correct is not null),0), 1) as accuracy_pct
from public.predictions group by agent_slug;
alter view public.agent_accuracy set (security_invoker = true);