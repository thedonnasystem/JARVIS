#!/usr/bin/env bash
# Write-path cost of the redaction epoch triggers (round 8, S5). In ONE transaction that is rolled back (the scratch database is left as it was): seeds N leads and N outbox rows, then times a
# 150-row insert of KNOWN values into each (the case that used to scan the whole table once per distinct value), a single-row insert and a 150-row delete. Prints milliseconds; fails when the
# 150-row lead insert exceeds the budget. Measured on the 2-core scratch machine at 100,000 rows: 4403 ms / 1376 ms before the hash indexes, 152 ms / 101 ms after.
#   scripts/perf_epoch_triggers.sh <scratch database url> [rows=100000] [budget_ms=1500]
set -euo pipefail
url="${1:?scratch database url}"; n="${2:-100000}"; budget="${3:-1500}"
echo "$url" | grep -qi supabase && { echo "refusing: not a scratch database"; exit 2; }
out="$(psql "$url" -X -q -At -v ON_ERROR_STOP=1 -v n="$n" 2>&1 <<'SQL'
begin;
select set_config('perf.n', :'n', true);
do $$
declare n int := current_setting('perf.n')::int; v uuid; ag text; t0 timestamptz; a int; b int; c int; d int;
begin
  select id into v from public.ventures order by slug limit 1; select slug into ag from public.agents order by slug limit 1;
  set local session_replication_role = replica;        -- the seed rows skip the triggers; the timed statements below do not
  insert into public.outbox (agent, channel, to_ref, body, venture_id) select ag, 'email', 'perf-' || (g % 20000) || '@example.test', 'b', v from generate_series(1, n) g;
  insert into public.leads (venture_id, name, email, phone, status) select v, 'Perf Name' || g, 'pl' || g || '@example.test', '613-' || (1000000 + g), 'new' from generate_series(1, n) g;
  set local session_replication_role = origin;
  analyze public.outbox; analyze public.leads;
  t0 := clock_timestamp();
  insert into public.leads (venture_id, name, email, phone, status) select v, 'Perf Name' || g, 'pl' || g || '@example.test', '613-' || (1000000 + g), 'new' from generate_series(1, 150) g;
  a := round(extract(epoch from (clock_timestamp() - t0)) * 1000); t0 := clock_timestamp();
  insert into public.outbox (agent, channel, to_ref, body, venture_id) select ag, 'email', 'perf-' || g || '@example.test', 'batch150', v from generate_series(1, 150) g;
  b := round(extract(epoch from (clock_timestamp() - t0)) * 1000); t0 := clock_timestamp();
  insert into public.outbox (agent, channel, to_ref, body, venture_id) values (ag, 'email', 'perf-7@example.test', 'single', v);
  c := round(extract(epoch from (clock_timestamp() - t0)) * 1000); t0 := clock_timestamp();
  delete from public.outbox where body = 'batch150';
  d := round(extract(epoch from (clock_timestamp() - t0)) * 1000);
  raise notice 'PERF % % % %', a, b, c, d;
end $$;
rollback;
SQL
)" || { echo "$out" | tail -5; echo "PERF FAIL: the measurement did not run"; exit 1; }
set -- $(echo "$out" | sed -n 's/.*PERF \([0-9]*\) \([0-9]*\) \([0-9]*\) \([0-9]*\).*/\1 \2 \3 \4/p' | tail -1)
[ $# = 4 ] || { echo "$out" | tail -5; echo "PERF FAIL: no measurement"; exit 1; }
echo "rows per table: $n | 150-row lead insert: $1 ms | 150-row outbox insert: $2 ms | single outbox insert: $3 ms | 150-row outbox delete: $4 ms (budget for the lead insert: ${budget} ms)"
[ "$1" -le "$budget" ] || { echo "PERF FAIL: 150-row lead insert took $1 ms at $n rows"; exit 1; }
