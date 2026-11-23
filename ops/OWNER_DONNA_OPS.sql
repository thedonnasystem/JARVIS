-- Donna Ops v1: OWNER steps (Supabase SQL editor, signed in as the owner). Read docs/architecture/DONNA_OPS_V1.md first.
-- Nothing here sends, pays, signs or deploys. Donna's agents only research and draft; every external step stays yours.

-- 0. Donna stays DORMANT until you activate her (M7, one office at a time):
-- select public.office_os_set_manager('donna', '<manager name>');
-- select public.office_os_activate('donna');                       -- returns a nonce
-- select public.office_os_decide('donna', '<nonce>', true);
-- select public.office_os_activate('donna');                       -- consumes your decision; the 8 prohibited actions become office blocks
-- Then in Telegram: /donna run market-research, /donna run outreach-prep, /donna report (the weekly report also runs Mondays 09:05 Ottawa via pg_cron).

-- 1. Drafts waiting for you (approval = approved COPY only; nothing is sent from a draft). Replace every [OWNER: ...] placeholder first:
-- select id, kind, channel, subject, left(body, 400) from fz_donna.drafts where status = 'draft' order by created_at;
-- select public.donna_owner_edit_draft('<draft id>', (select subject from fz_donna.drafts where id = '<draft id>'),
--        replace((select body from fz_donna.drafts where id = '<draft id>'), '[OWNER: mailing address]', '<your mailing address>'));   -- CASL re-checked
-- select public.donna_owner_decide_draft('<draft id>', true);       -- or false to reject

-- 2. A client intake (delivery-onboarding) -> its receptionist config, IN DEMO:
-- select id, client_label, open_items from fz_donna.intakes where status = 'draft';
-- select public.donna_owner_decide_intake('<intake id>', true);
-- insert into public.client_workspaces (slug, name, vertical, status) values ('<client-slug>', '<Business name>', '<vertical>', 'active');
-- select public.donna_owner_apply_intake('<intake id>', '<client-slug>', (select id from public.client_workspaces where slug = '<client-slug>'));
-- The intake's site_json stays a draft: hand it to Web Studio, which has its own owner approval before any deploy.

-- 3. Going live (Telegram: /reception golive <client-slug> shows this checklist with ticks):
-- select public.donna_owner_golive_approve('<client-slug>', true, true, true);   -- demo tested, client approved, number webhooks set
-- select public.reception_owner_set_client('<client-slug>', (select workspace_id from fz_reception.clients where slug = '<client-slug>'),
--        (select config from fz_reception.clients where slug = '<client-slug>'), '+1XXXXXXXXXX');
-- select public.reception_owner_set_flags('<client-slug>', 'live', true, false);  -- each text waits for you
-- Undo: select public.reception_owner_set_flags('<client-slug>', 'paused', false, false);
