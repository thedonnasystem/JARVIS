-- FF Marketing consent log v1 (owner decisions A and B, Nov 2026). Additive: 2 tables, 1 unique index, 12 functions, 2 replaced functions. No rows are changed.
--   * ffm_consent_log is APPEND-ONLY and immutable (trigger; service_role has no write grants). A withdrawal is a NEW row (basis 'withdrawn'), never an update.
--   * ffm_can_contact(lead, channel) is DEFAULT-DENY: true only with a current express consent, or an implied consent inside an owner-set window.
--     A withdrawal (for that channel or 'all'), a suppression-list hit, a closed workspace, an unknown lead or an unknown channel all give false. Withdrawal always wins and is final in v1.
--   * the implied-consent window is an OWNER-SET number of days per workspace (ffm_set_implied_window, owner-only). NULL / not set = implied consent is not accepted at all.
--     This migration does not choose any number; what counts as implied consent and for how long is for the owner and counsel to decide.
--   * evidence_ref is a short pointer (a form id, a message id), screened by ffm_guard like every other ffm_* text. It is not a place to paste a conversation.
--   * ffm_route_preview (replaced) now REFUSES a lead with no current consent on any channel. Nothing here sends a message, enables a campaign or calls an ad platform:
--     dry_run stays a CHECK-constrained true everywhere, and ffm_can_contact authorizes nothing by itself. A true answer is a necessary condition for outreach, never a sufficient one.
--   * erasure: ffm_erase_lead (owner-only) redacts the lead's contact fields and blanks consent evidence_ref, keeping the metadata rows (basis, channel, times, lead uuid) so that
--     withdrawals and the fact of consent survive without personal data. See DATA_CLASSIFICATION_AND_BACKUP_POLICY.md.
--   * ws_sensitive_hits (replaced, same name and signature) gains a 'health' category (decision B). Fail-closed; regular-expression based, so it has stated limits (see the policy document).

-- 1. detector: existing categories unchanged, plus 'health'
create or replace function public.ws_sensitive_hits(p_text text) returns text[]
language plpgsql immutable set search_path to 'public' as $$
declare t text; np text; c text; k text; kc text; hits text[] := '{}'; w text;
begin
  -- normalise first: zero-width characters out, NFKC (fullwidth digits etc.), Arabic-Indic / Persian digits to ASCII
  t := translate(normalize(regexp_replace(coalesce(p_text, ''), '[\u200b-\u200d\u2060\ufeff]', '', 'g'), NFKC),
                 '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
  k := lower(t);
  -- phone-shaped numbers are removed from the text first (NOT used to excuse the rest of it), then digits are compacted
  np := regexp_replace(t, '(\+?1[ .\-]?)?\(?[0-9]{3}\)?[ .\-]?[0-9]{3}[ .\-]?[0-9]{4}', ' ', 'g');
  c := regexp_replace(np, '[^[:alnum:]]', '', 'g');
  if c ~ '(^|[^0-9])[0-9]{9}([^0-9]|$)' then hits := hits || array['sin_like_number']; end if;
  if c ~ '[0-9]{13,19}' then hits := hits || array['card_like_number']; end if;
  if c ~ '(^|[^0-9])[0-9]{7,8}([^0-9]|$)' or c ~ '(^|[^0-9])[0-9]{10,12}([^0-9]|$)' then hits := hits || array['account_like_number']; end if;
  kc := regexp_replace(k, '[^a-z0-9]', '', 'g');
  if k ~ '(^|[^a-z])s[ ._\-]*i[ ._\-]*n([^a-z]|$)' or k ~ '(^|[^a-z])(ssn|nas)([^a-z]|$)'
     or kc ~ '(socialinsurance|passport|driverslicen|driverlicen|governmentid|healthcard|ohip|dateofbirth)' then hits := hits || array['identity_document']; end if;
  if kc ~ '(bankstatement|accountnumber|accountno|bankaccount|chequingaccount|routingnumber|transitnumber|institutionnumber|voidcheque|voidcheck|directdeposit|bankingdetails|iban)' then hits := hits || array['banking']; end if;
  if kc ~ '(creditscore|creditreport|creditcheck|credithistory|creditrating|equifax|transunion|experian|beaconscore)' or k ~ '(^|[^a-z])fico([^a-z]|$)' then hits := hits || array['credit']; end if;
  if kc ~ '(mortgageapplication|loanapplication|preapproval|noticeofassessment|paystub|employmentletter|incomeverification|proofofincome|networth|income|salary|taxreturn)'
     or k ~ '(^|[^a-z0-9])(t4a?|noa)([^a-z0-9]|$)' then hits := hits || array['application_or_income']; end if;
  -- 'health' (added 20261119): FAIL-CLOSED screen for health information. Two layers, both on the already-normalised text:
  --   (a) compacted (letters+digits only, so "d.i.a.b.e.t.e.s" and "d i a b e t e s" are caught) SUBSTRING match for long, distinctive stems.
  --       Substrings can also match across a word boundary ("scan certificate" contains "cancer"): accepted false positive.
  --   (b) word-boundary match, tolerant of one separator between letters, for short or ambiguous words ("heart", "hiv", "rx", "mental")
  -- It is a regular-expression list, NOT a medical classifier: it misses misspellings, other languages, leetspeak, euphemisms and anything
  -- not on the list, and it refuses innocent text (see sqltests/ffm_consent_check.sql, section H, for the listed false positives).
  -- It reduces accidental capture of health data; it is not a guarantee, and no lawful basis for handling health data follows from it.
  if kc ~ '(diabet|cancer|tumou?r|chemo|radiotherap|oncolog|leuk[a]?emi|lymphoma|melanoma|hypertens|hypotens|cholesterol|asthma|epilep|seizure|dementia|alzheimer|parkinson|arthritis|osteoporo|fibromyalg|multiplesclerosis|cysticfibrosis|crohn|colitis|dialysis|transplant|pacemaker|insulin|inhaler|antibiotic|antidepress|opioid|painkill|steroid|heartattack|heartdisease|heartcondition|heartfailure|heartmurmur|bloodpressure|bloodsugar|bloodtest|bloodwork|bloodthinner|cardiac|cardiolog|cardiovascular|thyroid|kidney|ulcerative|migraine|chronic(?!le)|medical|medication|medicine|medicinal|medicare|medicaid|prescri|pharmac|diagnos|disabilit|pregnan|miscarriage|fertility|abortion|contracepti|maternity|mentalhealth|mentalillness|psychiatr|psychotherap|bipolar|schizophren|depress|anxiety|ptsd|autis|dyslexi|therap|surger|surgical|surgeon|hospital(?!ity)|hospice|palliative|ambulance|clinic|physician|symptom|disease|illness|sickness|syndrome|disorder|infection|infectious|covid|vaccin|allerg|injur|wheelchair|impairment|addict|alcoholi|substanceabuse|overdose|suicid|selfharm|eatingdisorder|anorexi|bulimi|obesity|paralys|hearingloss|hearingaid|apnea|apnoea|biops|mammogra|xray|ctscan|smoker|smoking|tobacco|nicotine|cigarette|cannabis|marijuana|patientrecord|patientfile|patientchart|patienthistory|patientinfo|patientnumber|patientid|patients|health)'
  then hits := hits || array['health']; end if;
  if not ('health' = any(hits)) then
    foreach w in array array['heart', 'hearts', 'hiv', 'aids', 'mental', 'mentally', 'sick', 'doctor', 'doctors', 'nurse', 'nurses', 'rx', 'meds', 'adhd', 'ocd', 'copd',
                             'drug', 'drugs', 'vape', 'vapes', 'vaping', 'stroke', 'strokes', 'lung', 'lungs', 'ulcer', 'ulcers', 'mri', 'ivf', 'stent', 'obese', 'deaf', 'deafness'] loop
      if k ~ ('(^|[^a-z])' || array_to_string(regexp_split_to_array(w, ''), case when length(w) <= 4 then '[._\-]?' else '[ ._\-]?' end) || '([^a-z]|$)') then
        hits := hits || array['health']; exit;
      end if;
    end loop;
  end if;
  return hits;
end $$;
revoke all on function public.ws_sensitive_hits(text) from public, anon, authenticated;
grant execute on function public.ws_sensitive_hits(text) to service_role;

-- 2. consent log (append-only) and the owner-set implied-consent window
create unique index if not exists ws_leads_ws_id_uidx on public.ws_leads (workspace_id, id);   -- lets the consent log carry a composite (workspace, lead) foreign key
create table if not exists public.ffm_consent_settings (
  workspace_id uuid primary key references public.client_workspaces(id) on delete restrict,
  implied_window_days integer check (implied_window_days is null or implied_window_days between 1 and 3650),   -- NULL = implied consent not accepted. The bounds are sanity limits, not legal advice.
  set_by text,
  updated_at timestamptz not null default clock_timestamp()
);
create table if not exists public.ffm_consent_log (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  lead_id uuid not null,
  channel text not null check (channel in ('email', 'sms', 'phone', 'mail', 'all')),
  basis text not null check (basis in ('express', 'implied', 'withdrawn')),
  wording_version text check (wording_version is null or length(wording_version) between 1 and 60),
  source text not null check (length(source) between 2 and 120),
  captured_at timestamptz not null,
  evidence_ref text check (evidence_ref is null or length(evidence_ref) <= 300),
  evidence_erased_at timestamptz,
  recorded_by text not null check (length(recorded_by) between 1 and 80),
  created_at timestamptz not null default clock_timestamp(),
  foreign key (workspace_id, lead_id) references public.ws_leads (workspace_id, id) on delete restrict,
  check (channel <> 'all' or basis = 'withdrawn'),
  check (basis = 'withdrawn' or wording_version is not null)
);
create index if not exists ffm_consent_lead_idx on public.ffm_consent_log (lead_id, channel, created_at);
create index if not exists ffm_consent_ws_idx on public.ffm_consent_log (workspace_id, created_at);
do $$ declare t text; begin
  foreach t in array array['ffm_consent_settings', 'ffm_consent_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to service_role', t);
    execute format('revoke insert, update, delete, truncate, trigger, references on public.%I from service_role', t);
    execute format('drop trigger if exists ffm_guard on public.%I', t);
    execute format('create trigger ffm_guard before insert or update on public.%I for each row execute function public.ffm_guard()', t);
  end loop;
end $$;

-- immutability: no update, delete or truncate, except the owner-only erasure path, which may only blank evidence_ref (and stamp evidence_erased_at)
create or replace function public.ffm_consent_immutable() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if tg_op = 'UPDATE' and current_setting('app.ffm_erasure', true) = 'on' and new.evidence_ref is null and new.source = '[erased]'
     and (to_jsonb(new) - 'evidence_ref' - 'evidence_erased_at' - 'source') = (to_jsonb(old) - 'evidence_ref' - 'evidence_erased_at' - 'source') then
    return new;
  end if;
  raise exception 'The consent log is append-only: rows cannot be changed or removed. Record a withdrawal as a new row.' using errcode = 'P0001';
end $$;
drop trigger if exists ffm_consent_immutable on public.ffm_consent_log;
create trigger ffm_consent_immutable before update or delete on public.ffm_consent_log for each row execute function public.ffm_consent_immutable();
drop trigger if exists ffm_consent_no_truncate on public.ffm_consent_log;
create trigger ffm_consent_no_truncate before truncate on public.ffm_consent_log for each statement execute function public.ffm_consent_immutable();

-- 3. functions
create or replace function public.ffm_set_implied_window(p_ws uuid, p_days integer) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_require_owner();
  perform public.ffm_open_ws(p_ws);
  insert into public.ffm_consent_settings (workspace_id, implied_window_days, set_by, updated_at) values (p_ws, p_days, 'owner', clock_timestamp())
    on conflict (workspace_id) do update set implied_window_days = excluded.implied_window_days, set_by = 'owner', updated_at = clock_timestamp();
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_implied_window_set', 'workspace/' || p_ws, jsonb_build_object('days', p_days));
end $$;

-- express or implied consent only. Withdrawal has its own function. Implied consent is a judgement call, so recording it is owner-only.
create or replace function public.ffm_record_consent(p_ws uuid, p_lead uuid, p_channel text, p_basis text, p_wording_version text, p_source text,
                                                      p_captured_at timestamptz, p_evidence_ref text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  perform public.ffm_open_ws(p_ws);
  if p_basis is null or p_basis not in ('express', 'implied') then raise exception 'consent refused: basis must be express or implied (use ffm_withdraw_consent to withdraw)'; end if;
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail') then raise exception 'consent refused: channel must be one of email, sms, phone, mail'; end if;
  if p_basis = 'implied' then perform public.ffm_require_owner(); end if;
  if coalesce(btrim(p_wording_version), '') = '' then raise exception 'consent refused: the wording version the person saw is required'; end if;
  if coalesce(btrim(p_source), '') = '' then raise exception 'consent refused: a source is required'; end if;
  if coalesce(length(btrim(p_evidence_ref)), 0) < 3 then raise exception 'consent refused: an evidence reference (form or message id) is required'; end if;
  if p_captured_at is null or p_captured_at > clock_timestamp() + interval '5 minutes' then raise exception 'consent refused: captured_at is missing or in the future'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  if not exists (select 1 from public.ws_leads where id = p_lead and workspace_id = p_ws) then raise exception 'lead not found in this workspace'; end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'withdrawn' and channel in (p_channel, 'all')) then
    raise exception 'consent refused: this lead withdrew consent for this channel; a withdrawal is final in v1 (re-opt-in is an owner decision)';
  end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, evidence_ref, recorded_by)
    values (p_ws, p_lead, p_channel, p_basis, p_wording_version, p_source, p_captured_at, p_evidence_ref, coalesce(nullif(btrim(p_by), ''), 'unknown')) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_consent_recorded', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'channel', p_channel, 'basis', p_basis, 'consent', v_id));
  return v_id;
end $$;

-- anyone (bot or owner) may record a withdrawal, at any time, even in a closed workspace: it can only reduce what we may do
create or replace function public.ffm_withdraw_consent(p_ws uuid, p_lead uuid, p_channel text, p_source text, p_evidence_ref text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail', 'all') then raise exception 'withdrawal refused: channel must be one of email, sms, phone, mail, all'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  if not exists (select 1 from public.ws_leads where id = p_lead and workspace_id = p_ws) then raise exception 'lead not found in this workspace'; end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, evidence_ref, recorded_by)
    values (p_ws, p_lead, p_channel, 'withdrawn', null, coalesce(nullif(btrim(p_source), ''), 'unspecified'), clock_timestamp(), nullif(btrim(p_evidence_ref), ''), coalesce(nullif(btrim(p_by), ''), 'unknown')) returning id into v_id;
  if p_channel in ('email', 'all') then
    insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
      select public.normalize_addr(email), 'ffm consent withdrawn', coalesce(nullif(btrim(p_by), ''), 'unknown'), null from public.ws_leads where id = p_lead and public.normalize_addr(email) is not null
      on conflict do nothing;   -- a withdrawal follows the ADDRESS, not only the lead id: a re-added duplicate lead is still refused ('suppressed')
  end if;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_consent_withdrawn', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'channel', p_channel, 'consent', v_id));
  return v_id;
end $$;

-- the decision, with the reason. DEFAULT-DENY: every path that is not an explicit yes is a no.
create or replace function public.ffm_contact_status(p_lead uuid, p_channel text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare l public.ws_leads; wstatus text; e public.ffm_consent_log; i public.ffm_consent_log; win integer;
begin
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail') then return jsonb_build_object('allowed', false, 'reason', 'invalid_channel'); end if;
  select * into l from public.ws_leads where id = p_lead;
  if l.id is null then return jsonb_build_object('allowed', false, 'reason', 'unknown_lead'); end if;
  select status into wstatus from public.client_workspaces where id = l.workspace_id;
  if wstatus is null or wstatus not in ('draft', 'active') then return jsonb_build_object('allowed', false, 'reason', 'workspace_not_open'); end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'withdrawn' and channel in (p_channel, 'all')) then
    return jsonb_build_object('allowed', false, 'reason', 'withdrawn');
  end if;
  if p_channel = 'email' and l.email is not null and public.is_suppressed(l.email) then return jsonb_build_object('allowed', false, 'reason', 'suppressed'); end if;
  select * into e from public.ffm_consent_log where lead_id = p_lead and basis = 'express' and channel = p_channel order by captured_at desc, created_at desc limit 1;
  if e.id is not null then return jsonb_build_object('allowed', true, 'reason', 'express', 'consent', e.id, 'captured_at', e.captured_at, 'wording_version', e.wording_version); end if;
  select * into i from public.ffm_consent_log where lead_id = p_lead and basis = 'implied' and channel = p_channel order by captured_at desc, created_at desc limit 1;
  if i.id is not null then
    select implied_window_days into win from public.ffm_consent_settings where workspace_id = l.workspace_id;
    if win is null then return jsonb_build_object('allowed', false, 'reason', 'implied_not_accepted'); end if;
    if i.captured_at + make_interval(days => win) <= clock_timestamp() then return jsonb_build_object('allowed', false, 'reason', 'implied_expired', 'captured_at', i.captured_at); end if;
    return jsonb_build_object('allowed', true, 'reason', 'implied', 'consent', i.id, 'captured_at', i.captured_at, 'expires_at', i.captured_at + make_interval(days => win));
  end if;
  return jsonb_build_object('allowed', false, 'reason', 'no_consent');
end $$;

create or replace function public.ffm_can_contact(p_lead uuid, p_channel text) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
begin
  return coalesce((public.ffm_contact_status(p_lead, p_channel) ->> 'allowed')::boolean, false);
exception when others then
  return false;   -- fail closed: any error is a no
end $$;

-- owner-only erasure: redact the lead's contact fields, blank consent evidence pointers, and add a final withdrawal for every channel. Metadata rows are kept.
create or replace function public.ffm_erase_lead(p_ws uuid, p_lead uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare n_ev integer;
begin
  perform public.ffm_require_owner();
  if p_reason is null or p_reason not in ('erasure_request', 'withdrawal', 'retention_expired', 'other') then raise exception 'erasure refused: reason must be erasure_request, withdrawal, retention_expired or other'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  if not exists (select 1 from public.ws_leads where id = p_lead and workspace_id = p_ws) then raise exception 'lead not found in this workspace'; end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, source, captured_at, recorded_by)
    values (p_ws, p_lead, 'all', 'withdrawn', 'erasure:' || p_reason, clock_timestamp(), 'owner');
  insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
    select public.normalize_addr(email), 'ffm erasure/withdrawal', 'owner', null from public.ws_leads where id = p_lead and public.normalize_addr(email) is not null
    on conflict do nothing;   -- the address stays blocked after the lead row is redacted, so re-adding the same person cannot restore contact
  perform set_config('app.ffm_erasure', 'on', true);
  update public.ws_leads set name = '[erased]', email = null, phone = null, source = null, note = null where id = p_lead;
  update public.ffm_consent_log set evidence_ref = null, source = '[erased]', evidence_erased_at = clock_timestamp() where lead_id = p_lead and (evidence_ref is not null or source <> '[erased]');
  get diagnostics n_ev = row_count;
  perform set_config('app.ffm_erasure', 'off', true);
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_lead_erased', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'reason', p_reason, 'evidence_refs_blanked', n_ev));
  return jsonb_build_object('lead', p_lead, 'evidence_refs_blanked', n_ev, 'note', 'copies in external backups are handled by key rotation or expiry, see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md');
end $$;

-- 4. routing preview, replaced: refuses leads without current consent. Still a dry run: sends nothing, logs only field names.
create or replace function public.ffm_route_preview(p_ws uuid, p_lead uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ws_leads; r public.ffm_routing_rules; src jsonb; pay jsonb; out_ jsonb := '[]'::jsonb; f text;
begin
  perform public.ffm_open_ws(p_ws);
  select * into l from public.ws_leads where id = p_lead and workspace_id = p_ws;
  if l.id is null then raise exception 'lead not found in this workspace'; end if;
  -- consent gate (20261119): no current consent on any channel = refused. A dry run still touches personal data, so it needs the same permission.
  if not (public.ffm_can_contact(p_lead, 'email') or public.ffm_can_contact(p_lead, 'sms') or public.ffm_can_contact(p_lead, 'phone') or public.ffm_can_contact(p_lead, 'mail')) then
    raise exception 'routing refused: no current consent on record for this lead';
  end if;
  src := jsonb_build_object('name', l.name, 'email', l.email, 'phone', l.phone, 'source', l.source, 'campaign_id', l.campaign_id, 'stage', l.stage, 'created_at', l.created_at);
  for r in select * from public.ffm_routing_rules where workspace_id = p_ws and status = 'approved' and dry_run order by created_at loop
    pay := '{}'::jsonb;
    foreach f in array r.allowed_fields loop pay := pay || jsonb_build_object(f, src -> f); end loop;
    if cardinality(r.allowed_fields) = 0 then continue; end if;
    if array_length(public.ws_sensitive_hits((select string_agg(value #>> '{}', ' ') from jsonb_each(pay) where key not in ('campaign_id', 'created_at'))), 1) > 0 then
      raise exception 'routing refused: payload for rule % looks sensitive', r.name;
    end if;
    insert into public.ffm_route_log (workspace_id, rule_id, lead_id, fields) values (p_ws, r.id, p_lead, r.allowed_fields);
    out_ := out_ || jsonb_build_array(jsonb_build_object('rule', r.name, 'destination_kind', r.destination_kind, 'dry_run', true, 'payload', pay));
  end loop;
  return out_;
end $$;

-- 5. grants: service_role only. Owner-only functions additionally call ffm_require_owner(), which refuses the bot.
revoke all on function public.ffm_consent_immutable() from public, anon, authenticated;
revoke all on function public.ffm_set_implied_window(uuid, integer) from public, anon, authenticated;
revoke all on function public.ffm_record_consent(uuid, uuid, text, text, text, text, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.ffm_withdraw_consent(uuid, uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.ffm_contact_status(uuid, text) from public, anon, authenticated;
revoke all on function public.ffm_can_contact(uuid, text) from public, anon, authenticated;
revoke all on function public.ffm_erase_lead(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.ffm_route_preview(uuid, uuid) from public, anon, authenticated;
grant execute on function public.ffm_consent_immutable() to service_role;
grant execute on function public.ffm_set_implied_window(uuid, integer) to service_role;
grant execute on function public.ffm_record_consent(uuid, uuid, text, text, text, text, timestamptz, text, text) to service_role;
grant execute on function public.ffm_withdraw_consent(uuid, uuid, text, text, text, text) to service_role;
grant execute on function public.ffm_contact_status(uuid, text) to service_role;
grant execute on function public.ffm_can_contact(uuid, text) to service_role;
grant execute on function public.ffm_erase_lead(uuid, uuid, text) to service_role;
grant execute on function public.ffm_route_preview(uuid, uuid) to service_role;
