-- FENDEZY GROUP: "Donna Nudges v1": the deals that are stuck on the OWNER's next step, so none of them goes cold. READ-ONLY.
-- ADDITIVE, after Donna Replies v1 (20261212). Design: docs/architecture/DONNA_NUDGES_V1.md.
--   * donna_stuck_deals (service path; works while Donna is dormant, because it only reads): one row per lead waiting on the owner, oldest first:
--       audit_no_proposal  booked more than a day ago, no proposal drafted yet           -> /donna proposal
--       won_no_intake      won, no onboarding intake saved yet                            -> /donna intake (after the welcome email's answers)
--       intake_no_agent    an intake is saved, the client's phone agent is not created     -> /donna agent
--     Each row: kind, lead short id, business name, since (when it got stuck), client label (intake only). No contact data.
-- Nothing here writes, sends, pays or deploys. Ordered BEFORE the lockdown. Safe to re-run.

set lock_timeout = '5s';

create or replace function public.donna_stuck_deals(p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_v uuid := fz_donna.donna_venture(); n integer := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
  perform fz_donna.guard();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.since) from (
    select * from (
      select 'audit_no_proposal'::text kind, l.short_id, l.name, coalesce((select min(i.received_at) from fz_donna_rl.inbound i where i.lead_id = l.id and i.booked), l.created_at) since,
             null::text client_label
        from public.leads l
       where l.venture_id = v_v and l.status = 'booked' and not l.do_not_contact
         and not exists (select 1 from fz_donna_rl.staged s where s.lead_id = l.id and s.purpose = 'proposal')
         and not exists (select 1 from fz_donna.drafts d where d.lead_id = l.id and d.status = 'draft')      -- a draft already queued for this lead (it stages on retry)
      union all
      select 'won_no_intake', l.short_id, l.name, coalesce((select max(d.updated_at) from public.deals d where d.lead_id = l.id and d.stage = 'won'), l.created_at), null
        from public.leads l
       where l.venture_id = v_v and l.status = 'won'
         and not exists (select 1 from fz_donna.intakes t where t.lead_id = l.id)
      union all
      select 'intake_no_agent', l.short_id, coalesce(l.name, t.client_label), t.created_at, t.client_label
        from (select distinct on (coalesce(t.lead_id::text, t.client_label)) t.* from fz_donna.intakes t
               where t.status in ('draft', 'owner_approved') order by coalesce(t.lead_id::text, t.client_label), t.created_at desc) t
        left join public.leads l on l.id = t.lead_id
       where not exists (select 1 from fz_donna_ca.agents a where a.intake_id = t.id)
         and (l.id is null or l.status = 'won')
    ) s
    where s.kind <> 'audit_no_proposal' or s.since < now() - interval '1 day'
    order by s.since limit n) x), '[]'::jsonb);
end $$;
revoke all on function public.donna_stuck_deals(integer) from public, anon, authenticated;
