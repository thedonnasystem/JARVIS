-- READ-ONLY. Per-table row count + content hash for every table in schema public. Run the same file on production (read-only SELECT) and on a
-- restored scratch database, then compare the output rows. Tables that change while the company runs (audit_log, llm_calls, heartbeat-style tables)
-- will legitimately differ if production kept running after the backup; compare against a quiet moment or accept expected drift (documented in the report).
select c.relname as table_name,
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', c.relname), false, true, '')))[1]::text::bigint as rows,
       (xpath('/row/h/text()', query_to_xml(format('select md5(coalesce(string_agg(t::text, E''\n'' order by t::text), '''')) as h from public.%I t', c.relname), false, true, '')))[1]::text as content_md5
from pg_class c
where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname not in ('push_config', 'push_subscriptions')
order by 1;
