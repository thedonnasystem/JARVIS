-- PERSISTENT REDACTION DENY-LIST: names, emails and phone numbers of people the system has ever known, kept as KEYED HASHES only, so the off-site export can still redact them after the
-- lead / setter / workspace row has been ERASED or DELETED (ffm_erase_lead overwrites ws_leads.name with '[erased]'; `delete from leads` removes the row; the export used to learn names only from live rows).
-- Design
--   * What is stored: HMAC-SHA256(key, kind ':' normalised value). kind: n = name token (casefolded, accent/look-alike folded, >= 3 letters, not an operating word), f = whole name squashed (letters+digits only,
--     >= 5 chars; also an email's local part), e = normalised email, p10 / p7 = last 10 / last 7 digits of a phone number. No plaintext, no names. The table cannot be read or written by any API role.
--   * The key: ffm_redaction_keys.denylist_hmac, generated INSIDE this migration from the database's strong random source (two gen_random_uuid(), 244 bits) if absent. It is never exported (the table name starts
--     with ffm_, which backup_export_policy() denies by NAME PATTERN whatever any list says), never logged, never returned by a function, and there is no function that reads it for a caller: only SECURITY DEFINER
--     code inside this database uses it. It does not depend on ffm_secrets (another branch). It cannot be rotated: erased names exist only as hashes, so a new key would orphan the whole list.
--   * Populated by triggers on every table that holds a client name / email / phone (leads, ws_leads, setters, client_workspaces, setter_events, contact_suppressions, outbox) on INSERT, UPDATE (old AND new value),
--     DELETE and TRUNCATE, BEFORE the data changes, and back-filled below from the rows that exist today. Hashes are never removed (append-only trigger).
--   * Used by: backup_snapshot() (the candidate tokens that occur in the exported text are hashed and compared; matches are redacted like live names) and by direct backup_redact_text() calls.
-- The list is itself CLIENT-DERIVED data (a keyed hash of a name is still personal data) and is therefore class secret / client_pii: it is NEVER in the off-site file and it grows with the number of people
-- ever stored (about 100 bytes per token; 1 million people is about 400 MB). It is available to backup_snapshot() at export time because the export runs inside the database.
-- LIMITS: a common word that is also somebody's name ('sam', 'pat', 'bob', 'will') is redacted wherever it occurs as a word in exported text, for ever. Operating words (backup_stopwords) and one-word names that are
-- stop words are not stored as tokens (the whole squashed name still is). Without the key nothing can be matched, so after a restore from the off-site file (which has no client data and no key) the list is empty
-- by design; the provider's database backup holds list and key together, like the client tables themselves.

create table if not exists public.ffm_redaction_keys (
  name text primary key check (name = 'denylist_hmac'),
  value text not null check (length(value) >= 32),
  created_at timestamptz not null default now()
);
create table if not exists public.ffm_redaction_denylist (
  h text primary key check (h ~ '^[0-9a-f]{64}$'),
  kind text not null check (kind in ('n', 'f', 'e', 'p7', 'p10')),
  first_seen timestamptz not null default now()
);
alter table public.ffm_redaction_keys enable row level security;
alter table public.ffm_redaction_denylist enable row level security;
revoke all on public.ffm_redaction_keys from public, anon, authenticated, service_role;
revoke all on public.ffm_redaction_denylist from public, anon, authenticated, service_role;
insert into public.ffm_redaction_keys (name, value)
  select 'denylist_hmac', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where not exists (select 1 from public.ffm_redaction_keys where name = 'denylist_hmac');

-- append-only: a hash is never changed or removed (an erased name must stay redacted)
create or replace function public.redaction_denylist_immutable() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
begin
  raise exception 'ffm_redaction_denylist and ffm_redaction_keys are append-only: nothing is updated, deleted or truncated';
end $$;
revoke all on function public.redaction_denylist_immutable() from public, anon, authenticated;
drop trigger if exists denylist_append_only on public.ffm_redaction_denylist;
create trigger denylist_append_only before update or delete on public.ffm_redaction_denylist for each row execute function public.redaction_denylist_immutable();
drop trigger if exists denylist_no_truncate on public.ffm_redaction_denylist;
create trigger denylist_no_truncate before truncate on public.ffm_redaction_denylist for each statement execute function public.redaction_denylist_immutable();
drop trigger if exists keys_append_only on public.ffm_redaction_keys;
create trigger keys_append_only before update or delete on public.ffm_redaction_keys for each row execute function public.redaction_denylist_immutable();
drop trigger if exists keys_no_truncate on public.ffm_redaction_keys;
create trigger keys_no_truncate before truncate on public.ffm_redaction_keys for each statement execute function public.redaction_denylist_immutable();

-- the HMAC pads of the key (ipad/opad XOR, hex 'ipad:opad'): derived once per snapshot, so each hash is two SHA-256 calls. Secret-derived: no API role may call this.
-- SECURITY INVOKER on purpose: the lockdown migration (last) grants execute on EVERY function to service_role, so a definer function here would be callable by it. As invoker it needs the caller to be able to read
-- the key table, which only the owner (and so the definer functions backup_redaction_context / the capture trigger) can: a direct call by service_role fails with 'permission denied'.
create or replace function public.redaction_pads() returns text
language plpgsql stable set search_path to 'pg_catalog' as $$
declare kv text; k bytea; ik bytea := decode(repeat('00', 64), 'hex'); ok bytea := decode(repeat('00', 64), 'hex'); i int;
begin
  select value into kv from public.ffm_redaction_keys where name = 'denylist_hmac';
  if kv is null then return null; end if;
  k := convert_to(kv, 'UTF8');
  if length(k) > 64 then k := sha256(k); end if;
  k := k || decode(repeat('00', 64 - length(k)), 'hex');
  for i in 0..63 loop
    ik := set_byte(ik, i, get_byte(k, i) # 54);      -- 0x36
    ok := set_byte(ok, i, get_byte(k, i) # 92);      -- 0x5c
  end loop;
  return encode(ik, 'hex') || ':' || encode(ok, 'hex');
end $$;
revoke all on function public.redaction_pads() from public, anon, authenticated, service_role;

-- HMAC-SHA256(key, kind ':' value) as hex, from the pads. Pure SQL so the planner inlines it.
create or replace function public.redaction_h(p_pads text, p_kind text, p_val text) returns text
language sql immutable parallel safe set search_path to 'pg_catalog' as $$
  select encode(sha256(decode(split_part(p_pads, ':', 2), 'hex') || sha256(decode(split_part(p_pads, ':', 1), 'hex') || convert_to(p_kind || ':' || p_val, 'UTF8'))), 'hex')
$$;
revoke all on function public.redaction_h(text, text, text) from public, anon, authenticated, service_role;

-- records one value. kind: n name, e email, p phone, c contact (email if it has an @, else phone). Returns the number of new hashes.
create or replace function public.redaction_capture(p_kind text, p_value text) returns integer
language plpgsql volatile set search_path to 'pg_catalog' as $$
declare pads text; f text; tok text[]; w text; sq text; d text; n int := 0; stop text[] := public.backup_stopwords(); kind text := p_kind; a int; b int; c text;
begin
  if p_value is null or btrim(p_value) = '' then return 0; end if;
  pads := public.redaction_pads();
  if pads is null then
    insert into public.ffm_redaction_keys (name, value) select 'denylist_hmac', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where not exists (select 1 from public.ffm_redaction_keys where name = 'denylist_hmac');
    pads := public.redaction_pads();
  end if;
  f := lower(public.backup_fold_text(btrim(p_value)));
  if f in ('[erased]', 'erased') or length(f) < 2 then return 0; end if;
  if kind = 'c' then kind := case when position('@' in f) > 0 then 'e' else 'p' end; end if;
  if kind = 'p' then
    d := regexp_replace(f, '[^0-9]', '', 'g');
    if length(d) >= 7 then
      insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'p7', right(d, 7)), 'p7') on conflict do nothing; get diagnostics n = row_count;
      if length(d) >= 10 then
        insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'p10', right(d, 10)), 'p10') on conflict do nothing;
      end if;
    end if;
    return n;
  end if;
  if kind = 'e' then
    if position('@' in f) = 0 then return 0; end if;
    insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'e', f), 'e') on conflict do nothing;
    f := split_part(f, '@', 1);
    tok := array(select x from unnest(regexp_split_to_array(f, '[^a-z0-9]+')) x where x <> '');
    sq := array_to_string(tok, '');
    if length(sq) >= 5 then insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'f', sq), 'f') on conflict do nothing; end if;
    return 1;
  end if;
  -- name
  tok := array(select x from unnest(regexp_split_to_array(f, '[^a-z0-9\u0080-\uffff]+')) x where x <> '');
  if cardinality(tok) = 0 then return 0; end if;
  sq := array_to_string(tok, '');
  if length(sq) >= 5 then insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'f', sq), 'f') on conflict do nothing; end if;
  -- every contiguous run of adjacent tokens, squashed: a hyphenated or apostrophe surname written WITHOUT its separator ('Ashgrove-Pellew' -> 'ashgrovepellew', "D'Arcy" -> 'darcy'), a first name + surname pair, in any position
  for a in 1..least(cardinality(tok), 8) loop
    for b in a + 1..least(cardinality(tok), 8) loop
      c := array_to_string(tok[a:b], '');
      if length(c) >= 5 and c <> sq then insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'f', c), 'f') on conflict do nothing; end if;
    end loop;
  end loop;
  foreach w in array tok loop
    if length(w) >= (case when w ~ '[^\x01-\x7f]' then 2 else 3 end) and not (w = any (stop)) and w !~ '^[0-9]+$' then
      insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'n', w), 'n') on conflict do nothing;
      if length(w) >= 5 then      -- the squashed token on its own (surname): found letter-spaced, glued, with a 1-2 character prefix or suffix, in a plural or a url, like a live name's squashed forms
        insert into public.ffm_redaction_denylist (h, kind) values (public.redaction_h(pads, 'f', w), 'f') on conflict do nothing;
      end if;
    end if;
  end loop;
  return 1;
end $$;
revoke all on function public.redaction_capture(text, text) from public, anon, authenticated, service_role;

-- trigger: TG_ARGV = 'column:kind' pairs. Captures NEW and OLD values (the old value is what an erasure or an update would otherwise lose).
create or replace function public.redaction_capture_trg() returns trigger
language plpgsql volatile security definer set search_path to 'pg_catalog' as $$
declare a text; col text; kind text; jn jsonb; jo jsonb; r record; nm text;
begin
  if TG_LEVEL = 'STATEMENT' then       -- TRUNCATE: every value, before it goes
    foreach a in array TG_ARGV loop
      col := split_part(a, ':', 1); kind := split_part(a, ':', 2);
      for r in execute format('select distinct %I::text v from %I.%I where %I is not null', col, TG_TABLE_SCHEMA, TG_TABLE_NAME, col) loop
        perform public.redaction_capture(kind, r.v);
      end loop;
    end loop;
    return null;
  end if;
  if TG_OP in ('INSERT', 'UPDATE') then jn := to_jsonb(NEW); end if;
  if TG_OP in ('UPDATE', 'DELETE') then jo := to_jsonb(OLD); end if;
  foreach a in array TG_ARGV loop
    col := split_part(a, ':', 1); kind := split_part(a, ':', 2);
    if jn is not null then perform public.redaction_capture(kind, jn ->> col); end if;
    if jo is not null and (jn is null or (jo ->> col) is distinct from (jn ->> col)) then perform public.redaction_capture(kind, jo ->> col); end if;
  end loop;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;
revoke all on function public.redaction_capture_trg() from public, anon, authenticated, service_role;

-- the tables and columns that hold a person's or company's name / email / phone (the same sources backup_redaction_context() reads). A sqltest fails when a client table gains a name-like column that is not here.
create or replace function public.redaction_sources() returns table (table_name text, column_name text, kind text)
language sql immutable set search_path to 'pg_catalog' as $$
  select * from (values ('leads', 'name', 'n'), ('leads', 'phone', 'c'), ('leads', 'email', 'e'), ('ws_leads', 'name', 'n'), ('ws_leads', 'phone', 'c'), ('ws_leads', 'email', 'e'),
                        ('setters', 'name', 'n'), ('setters', 'contact', 'c'), ('client_workspaces', 'name', 'n'), ('setter_events', 'client', 'n'),
                        ('contact_suppressions', 'address', 'e'), ('outbox', 'to_ref', 'c')) v (table_name, column_name, kind)
$$;
revoke all on function public.redaction_sources() from public, anon, authenticated;
grant execute on function public.redaction_sources() to service_role;

-- attach the triggers and back-fill from today's rows
do $$
declare t record; cols text; r record; tg text;
begin
  for t in select s.table_name, string_agg(s.column_name || ':' || s.kind, ',' order by s.column_name) cols from public.redaction_sources() s
            where to_regclass('public.' || s.table_name) is not null and exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.' || s.table_name) and a.attname = s.column_name and a.attnum > 0 and not a.attisdropped)
            group by s.table_name loop
    execute format('drop trigger if exists redaction_capture on public.%I', t.table_name);
    execute format('create trigger redaction_capture before insert or update or delete on public.%I for each row execute function public.redaction_capture_trg(%s)', t.table_name,
                   (select string_agg(quote_literal(x), ', ') from unnest(string_to_array(t.cols, ',')) x));
    execute format('drop trigger if exists redaction_capture_trunc on public.%I', t.table_name);
    execute format('create trigger redaction_capture_trunc before truncate on public.%I for each statement execute function public.redaction_capture_trg(%s)', t.table_name,
                   (select string_agg(quote_literal(x), ', ') from unnest(string_to_array(t.cols, ',')) x));
    for r in select split_part(x, ':', 1) col, split_part(x, ':', 2) kind from unnest(string_to_array(t.cols, ',')) x loop
      execute format('select public.redaction_capture(%L, %I::text) from (select distinct %I from public.%I where %I is not null) q', r.kind, r.col, r.col, t.table_name, r.col);
    end loop;
  end loop;
end $$;

-- counts only, never a hash
create or replace function public.redaction_denylist_status() returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select jsonb_build_object('key_present', exists (select 1 from public.ffm_redaction_keys where name = 'denylist_hmac'),
    'hashes', (select count(*) from public.ffm_redaction_denylist),
    'by_kind', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from public.ffm_redaction_denylist group by kind) q), '{}'::jsonb),
    'triggers', (select count(*) from pg_trigger t where t.tgname in ('redaction_capture', 'redaction_capture_trunc') and not t.tgisinternal))
$$;
revoke all on function public.redaction_denylist_status() from public, anon, authenticated;
grant execute on function public.redaction_denylist_status() to service_role;
