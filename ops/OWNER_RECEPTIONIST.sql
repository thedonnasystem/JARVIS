-- Donna Receptionist v1: OWNER steps (Supabase SQL editor, signed in as the owner). Read docs/architecture/DONNA_RECEPTIONIST_V1.md first.
-- Nothing here calls anyone or sends a text. A client starts in 'demo': only your demo line gets the AI, and its texts are logged as dry_run.

-- 1. The client business is a client workspace (the existing CRM). Callers become its leads.
-- insert into public.client_workspaces (slug, name, vertical, status) values ('<client-slug>', '<Business name>', '<vertical>', 'active');

-- 2. Its receptionist config (shape: receptionist/TEMPLATE.json). Phone numbers in E.164. Keep real configs out of the repo.
-- select public.reception_owner_set_client('<client-slug>', (select id from public.client_workspaces where slug = '<client-slug>'), '<config json>'::jsonb);

-- 3. Going live (needs the Donna office active and the client's own Twilio number):
-- select public.reception_owner_set_client('<client-slug>', (select id from public.client_workspaces where slug = '<client-slug>'), '<config json>'::jsonb, '+1XXXXXXXXXX');
-- select public.reception_owner_set_flags('<client-slug>', 'live', true, false);   -- text-back on, each text waits for you
-- select public.reception_owner_set_flags('<client-slug>', 'live', true, true);    -- text-back on with your standing approval
-- select public.reception_owner_set_flags('<client-slug>', 'paused', false, false); -- stop everything for this client (STOP replies still honoured)

-- 4. Texts waiting for you
-- select id, kind, body, created_at from fz_reception.messages where status = 'pending_approval' order by created_at;
-- select public.reception_owner_decide_sms('<message id>', true);
