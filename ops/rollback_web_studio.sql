-- Rollback of migrations/20261205_web_studio_v1.sql: fz_services rows are never deleted, so the Web Studio row is retired.
-- Run before rollback_shared_services.sql. Idempotent.
update public.fz_services set status = 'retired', note = 'retired by ops/rollback_web_studio.sql', updated_by = 'rollback'
 where service = 'web_studio' and status <> 'retired';
