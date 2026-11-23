-- Web Studio v1 (Nov 22 2026): registers the shared Web Studio service (hq_webstudio.py) in the shared-service registry.
-- Web Studio drafts and edits sites as pull requests (sites/<slug>/site.json), queues Netlify previews / publishes as hands 'deploy' actions the
-- owner approves, and imports website form leads into leads. No new table, no new function, no grant: one registry row.
-- Rollback: ops/rollback_web_studio.sql (fz_services rows are never deleted: the row is retired).
insert into public.fz_services (service, title, owner_office, writes, reads, attribution, scoped_identity, modules, note)
values ('web_studio', 'Web Studio: websites for every office and for Donna clients (drafts as PRs, Netlify previews / publishes as approved hands deploys)',
        (select id from public.fz_offices where slug = 'group'), '{leads,hand_actions}', '{hand_accounts,ventures}', 'column', 'jarvis',
        'hq_webstudio.py, hq_hands_adapters.py', 'site content in sites/<slug>/site.json; templates in sites/_templates/; form leads into leads with the consent wording version')
on conflict (service) do update set status = 'active', note = excluded.note, updated_by = 'migration';
