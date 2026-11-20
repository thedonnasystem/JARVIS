-- Money-control fingerprint (office money M2). Defines pg_temp.fz_money_fp() for this session; it changes nothing (every matrix call is undone).
-- Used by sqltests/office_money_check.sql (with M2 / after its rollback / after re-applying it) and by scripts/replica/run.sh (right before vs right after M2 is applied).
-- the money-control fingerprint: protected function texts + ACLs, triggers + ACLs on the money tables, their full contents, capital_snapshot(), and a DECISION MATRIX of
-- authorize_action() and reserve_spend() over modes x kill switch x actions x amounts x (no) approval. Every matrix call runs in a sub-transaction that is undone, so the
-- matrix itself changes nothing.
create function pg_temp.fz_money_fp() returns table (k text, v text) language plpgsql as $$
declare t text; x text; d jsonb; st text; ks boolean; act text; c int; appr boolean;
  money_tables text[] := array['ledger', 'llm_calls', 'spend_reservations', 'capital_policy', 'action_policy', 'system_state', 'approval_requests', 'action_log', 'bank_accounts',
                               'bank_balances', 'bank_transactions', 'payment_instructions', 'waterfall_policy', 'model_prices', 'tool_registry', 'executor_registry', 'executor_runs'];
begin
  k := 'functions';
  select string_agg(p.oid::regprocedure::text || '=' || md5(pg_get_functiondef(p.oid)) || '/' || coalesce(p.proacl::text, ''), ';' order by p.oid::regprocedure::text) into v
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and (p.proname in
      ('authorize_action', 'reserve_spend', 'settle_spend', 'release_spend', 'capital_snapshot', 'capital_mode', 'capital_check', 'capital_brief_text', 'reserve_llm_budget',
       'settle_llm_call', 'estimate_call_cents', 'mission_guard', 'executor_request', 'executor_complete', 'app_set_kill', 'enforce_outbox_rules', 'enforce_build_rules',
       'outbox_send_policy', 'guard_capital_policy', 'audit_policy_change', 'forbid_policy_delete', 'waterfall_policy_guard', 'waterfall', 'is_app_owner', 'record_action_result',
       'set_venture_budget', 'allocation_text', 'holding_pnl', 'fz_authorize_action', 'fz_policy_preview', 'fz_set_office_policy', 'fz_office_policy_guard')
      or p.proname ~ '^(bank_|payment|setter_payout|jarvis_self_fund|jarvis_owner_confirm_revenue)');
  return next;
  k := 'triggers';
  select string_agg(g.tgrelid::regclass::text || '.' || g.tgname || '=' || g.tgfoid::regprocedure::text || '/' || g.tgenabled::text, ';' order by g.tgrelid::regclass::text, g.tgname) into v
    from pg_trigger g where not g.tgisinternal and g.tgrelid::regclass::text in (select 'public.' || m from unnest(money_tables) m union select m from unnest(money_tables) m);
  return next;
  foreach t in array money_tables loop
    continue when to_regclass('public.' || t) is null;
    k := 'table:' || t;
    execute format('select count(*)::text || '':'' || coalesce(md5(string_agg(x::text, '','' order by x::text)), '''') from public.%I x', t) into v;
    v := v || '/' || coalesce((select relacl::text from pg_class where oid = ('public.' || t)::regclass), '') || '/' || (select relrowsecurity::text from pg_class where oid = ('public.' || t)::regclass);
    return next;
  end loop;
  k := 'capital_snapshot'; v := public.capital_snapshot()::text; return next;
  foreach st in array array['dry_run', 'approve_first', 'auto_in_caps'] loop
    foreach ks in array array[false, true] loop
      foreach act in array array['research', 'send_email', 'advertising', 'routine_expense', 'take_loan', 'fabricate', 'no_such_action'] loop
        foreach c in array array[0, 100, 999999] loop
          foreach appr in array array[false, true] loop
            begin
              update public.system_state set mode = st, kill_switch = ks where id = 1;
              if appr then insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('fzm-actor', act, c, 'fzm-ref', 'fingerprint', 'approved', now()); end if;
              d := public.authorize_action('fzm-actor', act, c, 'fzm-ref');
              raise exception using errcode = 'ZFZ01';
            exception when sqlstate 'ZFZ01' then null;
            end;
            k := format('authorize_action:%s:%s:%s:%s:%s', st, ks, act, c, appr); v := (d ->> 'decision') || '|' || coalesce(d ->> 'reason', '') || '|' || coalesce(d ->> 'tier', ''); return next;
          end loop;
        end loop;
      end loop;
      foreach c in array array[0, 100, 2000, 2600, 999999] loop
        foreach appr in array array[false, true] loop
          begin
            update public.system_state set mode = st, kill_switch = ks where id = 1;
            if appr then insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('fzm-actor', 'routine_expense', c, 'fzm-vendor', 'fingerprint', 'approved', now()); end if;
            d := public.reserve_spend('fzm-actor', 'routine_expense', 'fzm-vendor', 'office money check', 'proves the gate', 'none', c);
            raise exception using errcode = 'ZFZ01';
          exception when sqlstate 'ZFZ01' then null;
          end;
          k := format('reserve_spend:%s:%s:%s:%s', st, ks, c, appr); v := (d ->> 'decision') || '|' || coalesce(d ->> 'reason', ''); return next;
        end loop;
      end loop;
    end loop;
  end loop;
end $$;

