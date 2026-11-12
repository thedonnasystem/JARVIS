-- Public setter application (the ONE anon-callable function besides nothing else). Safeguards: honeypot, field limits,
-- global rate limit (15 per hour), one application per contact, no overwrite of existing setters, generic replies (no data leaks).
-- Applicants land as status 'applied' for the owner to review. Needs setters_v1. Apply BEFORE lockdown_v1 re-runs (lockdown exempts it).
create or replace function public.setter_apply(p_name text, p_contact text, p_niche text default null, p_note text default null, p_hp text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_name text := regexp_replace(trim(coalesce(p_name,'')), '[[:cntrl:]]', '', 'g');
        v_contact text := regexp_replace(trim(coalesce(p_contact,'')), '[[:cntrl:]]', '', 'g');
begin
  if coalesce(p_hp, '') <> '' then return jsonb_build_object('ok', true); end if;                      -- bot trap: pretend success, store nothing
  if length(v_name) < 2 or length(v_name) > 80 or length(v_contact) < 5 or length(v_contact) > 120 then
    return jsonb_build_object('ok', false, 'error', 'Please enter your name and a phone number or email.');
  end if;
  if v_contact !~ '@' and v_contact !~ '[0-9]{7,}' then
    return jsonb_build_object('ok', false, 'error', 'Please enter a valid phone number or email.');
  end if;
  if (select count(*) from public.setters where notes like 'self-signup%' and created_at > now() - interval '1 hour') >= 15 then
    return jsonb_build_object('ok', false, 'error', 'Too many applications right now. Please try again later.');
  end if;
  if exists (select 1 from public.setters where lower(contact) = lower(v_contact)) or exists (select 1 from public.setters where lower(trim(name)) = lower(v_name)) then
    return jsonb_build_object('ok', true);                                                              -- already known: same reply, no change
  end if;
  insert into public.setters (name, contact, niche, status, notes)
    values (v_name, v_contact, nullif(left(regexp_replace(trim(coalesce(p_niche,'')), '[[:cntrl:]]', '', 'g'), 120), ''), 'applied',
            'self-signup: ' || left(regexp_replace(coalesce(p_note,''), '[[:cntrl:]]', ' ', 'g'), 500));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.setter_apply(text, text, text, text, text) from public;
grant execute on function public.setter_apply(text, text, text, text, text) to anon, authenticated, service_role;
