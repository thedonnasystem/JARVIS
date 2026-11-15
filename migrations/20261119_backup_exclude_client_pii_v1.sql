-- Off-site backup: client personal data is EXCLUDED by default (owner decision C, Nov 2026). Read-only functions; writes nothing; service role only.
--   * backup_classification()   the explicit, reviewed list: every table that exists today has a data class. exported = class public or internal.
--                               Anything not on the list is 'unclassified' and is NOT exported (fail closed) until someone classifies it in a migration.
--   * deny always wins          ws_* , ffm_* and client_workspaces are never exported, whatever any list says; and any table with a foreign key to a non-exported table
--                               is not exported either (otherwise a restore would load rows that point at data that is not in the file)
--   * column drift              a table on the allow side that gains a column that looks like personal contact data (email, phone, address, ...) and is not on the reviewed
--                               exception list is excluded until reviewed
--   * backup_export_policy()    the decision, as jsonb: exported / excluded (with class and reason) / unclassified. Table NAMES only, never data.
--   * backup_snapshot(skip)     replaced (same name and signature): dumps only the exported tables and returns the policy beside the data. The schema (structure, no rows)
--                               of every table, including excluded ones, is still in schema.json so a restore rebuilds the empty tables.
--   * hq_backup.py refuses to run an off-site export without this function (it cannot fall back to "export everything").
-- WHAT THIS DOES NOT DO: it does not protect the live database, does not control Supabase's own backups, and cannot see personal data that a person typed into a
-- free-text column of an exported table (memory, tasks, notes). See DATA_CLASSIFICATION_AND_BACKUP_POLICY.md.
create or replace function public.backup_classification() returns table (table_name text, data_class text, note text)
language sql immutable set search_path to 'pg_catalog', 'public' as $$
  select * from (values
    -- public: non-personal reference data
    ('model_prices', 'public', 'published model prices'),
    -- secret: never exported, never in any backup
    ('push_config', 'secret', 'private push keys'),
    ('push_subscriptions', 'secret', 'push endpoints and keys'),
    -- client_pii: third-party personal data (leads, prospects, replies, setters, suppression list). EXCLUDED until retention, access, deletion and key policy are set.
    ('leads', 'client_pii', 'prospect name, phone, email, notes'),
    ('outbox', 'client_pii', 'drafts and recipients (to_ref) for leads'),
    ('lead_replies', 'client_pii', 'free-text notes about replies from leads'),
    ('deals', 'client_pii', 'notes about leads; references leads'),
    ('contact_suppressions', 'client_pii', 'opted-out email addresses. After a restore from an off-site backup this list is EMPTY: restore it from the database provider backup before any outreach is ever enabled'),
    ('setters', 'client_pii', 'sales partner name and contact'),
    ('setter_events', 'client_pii', 'client names per setter event'),
    ('setter_payouts', 'client_pii', 'references setters'),
    ('client_workspaces', 'client_pii', 'client company names'),
    -- internal: operating data of the owner and the ventures
    ('account_requests', 'internal', 'vendor sign-up requests; login name only, never a password'),
    ('accounts_registry', 'internal', 'which service accounts exist; vault reference only'),
    ('action_log', 'internal', 'action audit'), ('action_policy', 'internal', 'autonomy tiers'), ('agent_runs', 'internal', 'run summaries (free text)'),
    ('agents', 'internal', 'agent definitions'), ('alert_state', 'internal', 'alert throttling'), ('app_owners', 'internal', 'owner login emails'),
    ('approval_requests', 'internal', 'approvals'), ('audit_log', 'internal', 'audit trail (free text in detail)'), ('bank_accounts', 'internal', 'owner own bank labels and last4'),
    ('bank_balances', 'internal', 'owner own balances'), ('bank_transactions', 'internal', 'owner own transactions'), ('build_requests', 'internal', 'build queue'),
    ('capital_policy', 'internal', 'spend limits'), ('company_profile', 'internal', 'sender identity of the owner ventures'), ('dayjob_days', 'internal', 'day job counters'),
    ('dayjob_targets', 'internal', 'day job targets'), ('departments', 'internal', 'org'), ('escalations', 'internal', 'escalations (free text)'),
    ('evidence_sources', 'internal', 'fetched public web pages'), ('executor_registry', 'internal', 'executor limits'), ('executor_runs', 'internal', 'executor audit'),
    ('handbook', 'internal', 'handbook'), ('human_handoffs', 'internal', 'tasks for the owner (free text)'), ('ideas', 'internal', 'ideas'),
    ('integration_status', 'internal', 'integration health'), ('ledger', 'internal', 'books'), ('llm_calls', 'internal', 'model call meter'),
    ('memory', 'internal', 'agent memory (free text)'), ('mission_outcomes', 'internal', 'outcomes'), ('missions', 'internal', 'missions (free text)'),
    ('org_changes', 'internal', 'org proposals'), ('owner_messages', 'internal', 'messages to the owner (free text)'), ('payment_instructions', 'internal', 'payment requests; payee may be a person'),
    ('predictions', 'internal', 'predictions'), ('reconciliation_flags', 'internal', 'reconciliation'), ('setter_terms', 'internal', 'setter commission terms'),
    ('spend_reservations', 'internal', 'spend gateway'), ('system_state', 'internal', 'kill switch and modes'), ('systems', 'internal', 'registered systems'),
    ('tasks', 'internal', 'tasks (free text)'), ('tool_registry', 'internal', 'tools'), ('venture_assets', 'internal', 'assets'), ('venture_config', 'internal', 'venture offer config'),
    ('venture_goals', 'internal', 'goals'), ('venture_procedures', 'internal', 'procedures'), ('ventures', 'internal', 'ventures'), ('waterfall_policy', 'internal', 'money waterfall'),
    ('web_messages', 'internal', 'owner chat (free text)')
  ) v (table_name, data_class, note)
$$;

-- reviewed exceptions to the column-drift rule: columns that look like contact data but hold the OWNER's own or a business's data
create or replace function public.backup_pii_column_exceptions() returns table (table_name text, column_name text)
language sql immutable set search_path to 'pg_catalog', 'public' as $$
  select * from (values ('app_owners', 'email'), ('company_profile', 'reply_email'), ('company_profile', 'mailing_address'), ('company_profile', 'sender_name'),
                        ('accounts_registry', 'login_email'), ('account_requests', 'account_login'), ('payment_instructions', 'payee')) v (table_name, column_name)
$$;

create or replace function public.backup_export_policy() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public' as $$
declare res jsonb;
begin
  with recursive tabs as (
    select c.relname::text n from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
  ), base as (
    select t.n,
           case when t.n ~ '^(ws_|ffm_)' or t.n = 'client_workspaces' then 'client_pii' else coalesce(k.data_class, 'unclassified') end as cls,
           case
             when t.n ~ '^(ws_|ffm_)' or t.n = 'client_workspaces' then 'denied by rule: client workspace tables are never exported'
             when k.data_class is null then 'unclassified: add it to backup_classification() in a migration'
             when k.data_class not in ('public', 'internal') then 'class ' || k.data_class
             when exists (select 1 from pg_attribute a join pg_class c on c.oid = a.attrelid
                          where c.relnamespace = 'public'::regnamespace and c.relname = t.n and a.attnum > 0 and not a.attisdropped
                            and a.attname ~* '(^|_)(email|e_mail|phone|mobile|first_?name|last_?name|full_?name|to_ref|address|payee|dob|birth[a-z]*)($|_)'
                            and not exists (select 1 from public.backup_pii_column_exceptions() x where x.table_name = t.n and x.column_name = a.attname))
               then 'column that looks like personal contact data is not on the reviewed exception list'
           end as why
      from tabs t left join public.backup_classification() k on k.table_name = t.n
  ), ex as (
    select n from base where why is not null
    union
    select c.relname::text
      from pg_constraint f join pg_class c on c.oid = f.conrelid join pg_class r on r.oid = f.confrelid join ex on ex.n = r.relname::text
     where f.contype = 'f' and c.relnamespace = 'public'::regnamespace and r.relnamespace = 'public'::regnamespace
  ), ex1 as (
    select b.n, b.cls, coalesce(b.why, 'references a table that is not exported (foreign key); a restore would load rows that point at missing data') as why
      from base b where b.n in (select n from ex)
  )
  select jsonb_build_object(
    'exported', coalesce((select jsonb_agg(n order by n) from tabs where n not in (select n from ex1)), '[]'::jsonb),
    'excluded', coalesce((select jsonb_agg(jsonb_build_object('table', n, 'class', cls, 'reason', why) order by n) from ex1), '[]'::jsonb),
    'unclassified', coalesce((select jsonb_agg(n order by n) from base where cls = 'unclassified'), '[]'::jsonb))
  into res;
  return res;
end $$;

-- same name and signature as 20261113_backup_schema_v1: one-statement consistent snapshot of the EXPORTED tables only, plus the schema description (structure only)
create or replace function public.backup_snapshot(skip text[] default array['push_config', 'push_subscriptions']) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public' as $$
declare q text; res jsonb; pol jsonb := public.backup_export_policy();
begin
  select 'select jsonb_build_object(''data'', (select coalesce(jsonb_object_agg(k, v), ''{}''::jsonb) from (' ||
         string_agg(format('select %L::text as k, (select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t) as v', c.relname, c.relname), ' union all ' order by c.relname) ||
         ') s), ''schema'', public.backup_schema(), ''policy'', ' || quote_literal(pol::text) || '::jsonb, ''method'', ''single statement snapshot'')'
    into q
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname <> all (skip)
     and c.relname in (select jsonb_array_elements_text(pol -> 'exported'));
  if q is null then raise exception 'backup refused: the export policy lists no exportable table'; end if;
  execute q into res;
  return res;
end $$;

revoke all on function public.backup_classification() from public, anon, authenticated;
revoke all on function public.backup_pii_column_exceptions() from public, anon, authenticated;
revoke all on function public.backup_export_policy() from public, anon, authenticated;
revoke all on function public.backup_snapshot(text[]) from public, anon, authenticated;
grant execute on function public.backup_classification() to service_role;
grant execute on function public.backup_pii_column_exceptions() to service_role;
grant execute on function public.backup_export_policy() to service_role;
grant execute on function public.backup_snapshot(text[]) to service_role;
