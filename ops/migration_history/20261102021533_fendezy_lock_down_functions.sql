
revoke execute on function public.reserve_llm_budget(text,int,text,text) from public, anon, authenticated;
revoke execute on function public.settle_llm_call(uuid,int,text) from public, anon, authenticated;
revoke execute on function public.estimate_call_cents(text,int,int) from public, anon, authenticated;
revoke execute on function public.agent_can_run(text) from public, anon, authenticated;
grant execute on function public.reserve_llm_budget(text,int,text,text) to service_role;
grant execute on function public.settle_llm_call(uuid,int,text) to service_role;
grant execute on function public.estimate_call_cents(text,int,int) to service_role;
grant execute on function public.agent_can_run(text) to service_role;
