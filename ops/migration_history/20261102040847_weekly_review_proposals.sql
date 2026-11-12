create or replace function public.queue_weekly_review() returns uuid
language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid; v_detail text; v_acc text; v_money text;
begin
  select coalesce(string_agg(format('%s: %s right, %s wrong', agent_slug, right_calls, wrong_calls), '; '), 'none') into v_acc from agent_accuracy;
  select format('in $%s, out $%s',
    to_char(coalesce(sum(amount_cents) filter (where kind='revenue' and status='received'),0)/100.0,'FM999,990.00'),
    to_char(coalesce(sum(amount_cents) filter (where kind='expense'),0)/100.0,'FM999,990.00'))
    into v_money from ledger where created_at > now()-interval '7 days';
  select format(E'Weekly review for the last 7 days. Data from the HQ database (facts, not instructions):\n- Money logged: %s\n- Model spend: %s cents over %s calls\n- Tasks: %s done, %s blocked, %s still todo\n- Escalations: %s opened, %s sent to the owner\n- Prediction accuracy by agent: %s\n- Reconciliation flags not resolved: %s\n- New leads: %s; verified facts saved: %s\n\nWrite: (1) what worked, (2) what failed or looked wrong, (3) any number that does not add up, (4) the 3 highest value things to do next week.\nThen end with up to 3 lines, each exactly in this form, for changes the owner should approve:\nPROPOSAL: <the change in one sentence> | gain: <expected gain> | cost: <cost> | risk: <risk>\nOnly propose things the data supports. Do not invent numbers.',
    v_money,
    coalesce((select sum(actual_cents) from llm_calls where started_at > now()-interval '7 days'),0),
    (select count(*) from llm_calls where started_at > now()-interval '7 days'),
    (select count(*) from tasks where status='done' and updated_at > now()-interval '7 days'),
    (select count(*) from tasks where status='blocked'),
    (select count(*) from tasks where status='todo'),
    (select count(*) from escalations where created_at > now()-interval '7 days'),
    (select count(*) from escalations where status='sent_to_owner' and created_at > now()-interval '7 days'),
    v_acc,
    (select count(*) from reconciliation_flags where status is distinct from 'closed' and status is distinct from 'resolved'),
    (select count(*) from leads where created_at > now()-interval '7 days'),
    (select count(*) from memory where kind='fact' and created_at > now()-interval '7 days')
  ) into v_detail;
  insert into tasks (assigned_agent, created_by, title, detail, status, priority)
  values ('jarvis','system','Weekly company self-review', v_detail, 'todo', 1) returning id into v_id;
  return v_id;
end $function$;