-- Round-3 regression tests for the leak redaction (SCRATCH replica only; one transaction, rolled back; every check raises with its id).
--   M  B1  service_role (after the lockdown migration re-granted execute on everything) can neither read the key / deny-list nor write to the deny-list through ANY function the leak migrations created
--   N  S1  erased and deleted names in 25 spaced / glued / dotted / digit / plural / url forms, 8 strict columns (JSON values, keys, arrays), single statement AND paged
--   O  S3  2-character CJK / Korean / Arabic names, a two-part name in either order, small-caps and Latin-alpha look-alikes
--   P      a JSON number that is a known phone under an allow-listed key
begin;
do $$
declare
  v uuid; ag text; ctx jsonb; pads text; f record; a text; i int; r text; res text; n0 int; k0 text; txt text; snap jsonb; rec record; nm text; fn text; sn text; tpl text[]; s text;
  cands text[]; sig text; pg jsonb; pc int; j int;
begin
  select id into v from public.ventures where slug = 'donna' limit 1;
  if v is null then select id into v from public.ventures limit 1; end if;
  select slug into ag from public.agents order by slug limit 1;

  -- ============================================================ M. B1: service_role vs EVERY function the leak migrations created (enumerated from the catalog)
  pads := public.redaction_pads();
  if pads is null then raise exception 'M0 the key is not installed'; end if;
  n0 := (select count(*) from public.ffm_redaction_denylist);
  k0 := (select md5(string_agg(x::text, '|' order by x::text)) from public.ffm_redaction_keys x);
  ctx := public.backup_redaction_context();
  if ctx ? 'pads' or position(pads in ctx::text) > 0 then raise exception 'M1 the redaction context carries the key pads'; end if;
  -- every function of the leak migrations (and anything new named like them) must be in this list: a new function has to be added here on purpose
  cands := array(select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
                 and p.proname ~ '^(backup_|redaction_)' and p.proname not in ('backup_schema', 'backup_put', 'backup_status') order by 1);
  if cardinality(cands) < 40 then raise exception 'M2 expected 40+ backup_/redaction_ functions, found %', cardinality(cands); end if;
  grant usage on schema public to service_role;
  for pc in 1..2 loop                                                   -- two argument sets: harmless probes, then probes that try to read the key / write the deny-list through SQL text
    foreach sig in array cands loop
      declare args text := ''; t record; oidv oid := sig::regprocedure::oid; argtypes oidvector; nm2 text := (select proname from pg_proc where oid = oidv); lit text; out text := null; err text := null;
      begin
        select proargtypes into argtypes from pg_proc where oid = oidv;
        for t in select ord, typ from unnest(argtypes::oid[]) with ordinality u (typ, ord) order by ord loop
          lit := case t.typ::regtype::text
            when 'text' then case when pc = 1 then quote_literal('zz probe text 613-555-0100') else quote_literal('select (select string_agg(x::text, '','') from public.ffm_redaction_keys x) as s, redaction_capture(''n'', ''Poison Pill'')') end
            when 'jsonb' then quote_literal(case when pc = 1 then '{}' else '{"deny":"true","pads":"x"}' end) || '::jsonb'
            when 'integer' then '0' when 'oid' then '0' when 'text[]' then 'null::text[]' else 'null' end;
          if lit = 'null' then lit := 'null::' || t.typ::regtype::text; end if;
          args := args || case when t.ord > 1 then ', ' else '' end || lit;
        end loop;
        set local role service_role;
        begin
          execute format('select public.%I(%s)::text', nm2, args) into out;
        exception when others then err := sqlerrm; end;
        reset role;
        if pads is not null and (position(pads in coalesce(out, '') || coalesce(err, '')) > 0 or position(left(pads, 24) in coalesce(out, '') || coalesce(err, '')) > 0) then raise exception 'M3 % leaks the key pads to service_role (pass %): %', sig, pc, left(coalesce(out, err), 200); end if;
        if coalesce(out, '') || coalesce(err, '') ~ '[0-9a-f]{64}' then raise exception 'M4 % returns a 64-hex value (a hash or key) to service_role (pass %)', sig, pc; end if;
      end;
    end loop;
  end loop;
  if (select count(*) from public.ffm_redaction_denylist) <> n0 then raise exception 'M5 the deny-list changed while service_role called the leak functions (poison pill written)'; end if;
  if exists (select 1 from public.ffm_redaction_denylist where h = public.redaction_h(pads, 'n', 'poison pill')) then raise exception 'M5b the poison pill is in the deny-list'; end if;
  if (select md5(string_agg(x::text, '|' order by x::text)) from public.ffm_redaction_keys x) is distinct from k0 then raise exception 'M6 the key table changed'; end if;
  -- the two reported repros, spelled out
  set local role service_role;
  begin perform (public.backup_redaction_context() ->> 'pads'); res := (select (public.backup_redaction_context() ->> 'pads')); exception when others then res := 'err'; end;
  reset role;
  if res is not null and res <> 'err' then raise exception 'M7 backup_redaction_context()->>pads returned a value to service_role'; end if;
  set local role service_role;
  begin res := public.backup_deny_run('select (select string_agg(x::text, '','') from public.ffm_redaction_keys x) as s', 'zz')::text; exception when others then res := 'err:' || sqlerrm; end;
  reset role;
  if res !~ '^err:' or res ~ '[0-9a-f]{64}' then raise exception 'M8 backup_deny_run read the key table as service_role: %', left(res, 200); end if;
  set local role service_role;
  begin res := public.backup_deny_run('select redaction_capture(''n'', ''Poison Pill'')::text as s', 'zz')::text; exception when others then res := 'err:' || sqlerrm; end;
  reset role;
  if res !~ '^err:' then raise exception 'M9 backup_deny_run wrote the deny-list as service_role'; end if;
  if (select count(*) from public.ffm_redaction_denylist) <> n0 then raise exception 'M10 poison pill count changed'; end if;
  -- the redactor entry points service_role is meant to use still work
  set local role service_role;
  begin
    perform public.backup_redact_text('call Zed Quillon', public.backup_redaction_context(), 500, 'strict'); perform public.backup_snapshot_cost(); perform public.backup_redaction_status();
    reset role;
  exception when others then reset role; raise exception 'M11 service_role lost an intended entry point: %', sqlerrm; end;

  -- ============================================================ N. S1: erased and deleted names, 25 forms x 8 strict columns, single statement and paged
  insert into public.leads (venture_id, name, email, phone, status) values (v, 'Ottoline Brackenridge', 'ottoline@brackenridge-fixture.example', '613-555-0301', 'new'), (v, 'Wilhelmina Strathaven', 'w@strathaven-fixture.example', '613-555-0302', 'new');
  update public.leads set name = '[erased]', email = null, phone = null where name = 'Ottoline Brackenridge';
  delete from public.leads where name = 'Wilhelmina Strathaven';
  ctx := public.backup_redaction_context();
  create temp table nv (id serial, nm text, sn text, s text) on commit drop;
  foreach nm in array array['Ottoline Brackenridge', 'Wilhelmina Strathaven'] loop
    fn := split_part(nm, ' ', 1); sn := split_part(nm, ' ', 2);
    tpl := array[sn, regexp_replace(sn, '(.)', '\1 ', 'g'), regexp_replace(sn, '(.)', '\1.', 'g'), sn || '1', sn || 's', 'the ' || sn || 's', lower(left(fn, 1)) || sn, 'www.' || sn || '.ca',
      'https://x.example/' || sn, fn || sn, sn || ', ' || fn, fn || '.' || sn, upper(sn), replace(sn, 'e', 'é'), sn || '2024', '2' || sn, left(sn, 5) || '-' || substr(sn, 6),
      sn || '@mail.example', fn || ' ' || sn, 'mr' || sn, 'x' || sn || 'xy', left(sn, 4) || chr(8203) || substr(sn, 5), replace(sn, 'a', chr(1072)), fn || '_' || sn, regexp_replace(fn || sn, '(.)', '\1 ', 'g')];
    for i in 1..array_length(tpl, 1) loop insert into nv (nm, sn, s) values (nm, sn, 'ref ' || tpl[i] || ' ok'); end loop;
  end loop;
  -- the eight strict columns: direct redactor first (text, json value, json key, json array element)
  for rec in select * from nv order by id loop
    r := public.backup_redact_text(rec.s, ctx, 2000, 'strict');
    if lower(regexp_replace(public.backup_fold_text(r), '[^a-zA-Z0-9]', '', 'g')) ~ lower(rec.sn) then raise exception 'N1 text "%" survives as "%"', rec.s, r; end if;
    r := public.backup_redact_json(jsonb_build_object('v', rec.s), ctx, 500, 'strict')::text;
    if lower(regexp_replace(public.backup_fold_text(r), '[^a-zA-Z0-9]', '', 'g')) ~ lower(rec.sn) then raise exception 'N2 json value "%" survives as %', rec.s, r; end if;
    r := public.backup_redact_json(jsonb_build_object(rec.s, 1), ctx, 500, 'strict')::text;
    if lower(regexp_replace(public.backup_fold_text(r), '[^a-zA-Z0-9]', '', 'g')) ~ lower(rec.sn) then raise exception 'N3 json key "%" survives as %', rec.s, r; end if;
    r := public.backup_redact_json(jsonb_build_array(rec.s, jsonb_build_array(rec.s)), ctx, 500, 'strict')::text;
    if lower(regexp_replace(public.backup_fold_text(r), '[^a-zA-Z0-9]', '', 'g')) ~ lower(rec.sn) then raise exception 'N4 json array "%" survives as %', rec.s, r; end if;
  end loop;
  -- then through the real export (source triggers bypassed on purpose: this tests the export layer): tasks.result, ledger.note, audit_log.detail (value / key / array), agent_runs.summary, escalations.summary, ideas.result
  set local session_replication_role = replica;
  for rec in select * from nv order by id loop
    insert into public.tasks (assigned_agent, title, detail, status, result, created_by) values (ag, 'zzn ' || rec.id, 'x', 'done', rec.s, 'owner');
    insert into public.ledger (kind, amount_cents, currency, note, status) values ('expense', 100 + rec.id, 'CAD', rec.s, 'received');
    insert into public.audit_log (actor, action, target, detail) values ('zzn', 'note', 'zzn/v/' || rec.id, jsonb_build_object('v', rec.s));
    insert into public.audit_log (actor, action, target, detail) values ('zzn', 'note', 'zzn/k/' || rec.id, jsonb_build_object(rec.s, 1));
    insert into public.audit_log (actor, action, target, detail) values ('zzn', 'note', 'zzn/a/' || rec.id, jsonb_build_object('l', jsonb_build_array(rec.s)));
    insert into public.agent_runs (agent_id, status, summary) select id, 'ok', rec.s || ' #zzn' || rec.id from public.agents order by slug limit 1;
    insert into public.escalations (from_agent, kind, summary) values (ag, 'failure', rec.s);
    insert into public.ideas (name, result) values ('zzn ' || rec.id, rec.s);
  end loop;
  set local session_replication_role = origin;
  snap := public.backup_snapshot();
  for rec in select e.key tname, x from jsonb_each(snap -> 'data') e, jsonb_array_elements(e.value) x
             where lower(regexp_replace(public.backup_fold_text(x::text), '[^a-zA-Z0-9]', '', 'g')) ~ '(brackenridge|strathaven)' loop
    raise exception 'N5 an erased/deleted surname survives in the single-statement snapshot, table %: %', rec.tname, left(rec.x::text, 300);
  end loop;
  for rec in select t from (values ('tasks'), ('ledger'), ('audit_log'), ('agent_runs'), ('escalations'), ('ideas')) vv (t) loop
    for i in 0..((public.backup_table_digest(rec.t) ->> 'rows')::int / 40) loop
      pg := public.backup_snapshot_page(rec.t, i * 40, 40);
      if lower(regexp_replace(public.backup_fold_text((pg -> 'rows')::text), '[^a-zA-Z0-9]', '', 'g')) ~ '(brackenridge|strathaven)' then raise exception 'N6 an erased/deleted surname survives in the PAGED export of % (page %)', rec.t, i; end if;
    end loop;
  end loop;
  -- must-survive: an unrelated sentence is not damaged by the extra checks
  r := public.backup_redact_text('invoice sent to the brackish water authority about the ridge road', ctx, 2000, 'strict');
  if r not like '%ridge road%' then raise exception 'N7 over-redaction of unrelated words: %', r; end if;

  -- ============================================================ O. S3: short non-ASCII names, either order, look-alikes
  insert into public.leads (venture_id, name, phone, status) values (v, '李伟', '613-555-0311', 'new'), (v, '김민', '613-555-0312', 'new'), (v, 'محمد', '613-555-0313', 'new'), (v, 'Wu Li', '613-555-0314', 'new'), (v, 'Jo Xu', '613-555-0315', 'new'), (v, 'Zofia Wrzesniewska', '613-555-0316', 'new');
  ctx := public.backup_redaction_context();
  foreach a in array array['李伟', '김민', 'محمد'] loop
    r := public.backup_redact_text('please call ' || a || ' tomorrow', ctx, 500, 'strict');
    if position(a in r) > 0 then raise exception 'O1 the short non-ASCII name % is not redacted: %', a, r; end if;
    r := public.backup_redact_json(jsonb_build_object('k', 'x ' || a), ctx, 500, 'strict')::text;
    if position(a in r) > 0 then raise exception 'O2 the short non-ASCII name % survives in json: %', a, r; end if;
  end loop;
  foreach a in array array['Li, Wu', 'Li Wu', 'wu li', 'Xu Jo', 'Xu, Jo', 'Jo Xu', 'LiWu', 'W.U. L.I.'] loop
    r := public.backup_redact_text('meeting with ' || a || ' on friday', ctx, 500, 'strict');
    if r ~* '(li[ ,.]*wu|wu[ ,.]*li|xu[ ,.]*jo|jo[ ,.]*xu)' then raise exception 'O3 the two-part name % (either order) is not redacted: %', a, r; end if;
  end loop;
  foreach a in array array['ᴢᴏꜰɪᴀ ᴡʀᴢᴇꜱɴɪᴇᴡꜱᴋᴀ', 'Wrzesnɪewska', 'wrzesniewskɑ', 'Zofɑ Wrzesniewskɑ'] loop
    r := public.backup_redact_text('ask ' || a || ' now', ctx, 500, 'strict');
    if lower(regexp_replace(public.backup_fold_text(r), '[^a-zA-Z0-9]', '', 'g')) ~ 'wrzesniewsk' then raise exception 'O4 look-alike spelling % survives: %', a, r; end if;
  end loop;
  -- ASCII 2-character tokens stay unredacted by design (a 2-letter rule would erase "Li" from every sentence); a lone 2-character ASCII name is skipped, a pair is matched as a pair
  r := public.backup_redact_text('go to Li street', ctx, 500, 'strict');
  if r not like '%street%' then raise exception 'O5 a lone short ASCII token destroyed the sentence: %', r; end if;

  -- ============================================================ P. a number that is a known phone under an allow-listed key
  insert into public.leads (venture_id, name, phone, status) values (v, 'Zed Quillon', '613-555-0188', 'new');
  ctx := public.backup_redaction_context();
  j := 0;
  r := public.backup_redact_json('{"amount":6135550188,"total":6135550188,"ph":6135550188,"cents":125000,"count":3,"ms":12345678}'::jsonb, ctx, 500, 'strict')::text;
  if r like '%6135550188%' then raise exception 'P1 a known phone survives as a JSON number: %', r; end if;
  if r not like '%125000%' or r not like '%12345678%' then raise exception 'P2 ordinary amounts were damaged: %', r; end if;

  raise notice 'ROUND-3 LEAK CHECKS PASSED';
end $$;
rollback;
select 'leak_redaction_round3_ok';
