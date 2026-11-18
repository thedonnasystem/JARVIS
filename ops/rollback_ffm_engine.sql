-- Rollback of migrations/20261125_ffm_engine_v1.sql (FF Marketing engine v1). Idempotent. Run from the repo root.
-- DESTRUCTIVE for the engine tables only (saved briefs and generated packs): export them first if you want them
-- (e.g. \copy public.ffm_engine_packs to 'ffm_engine_packs.csv' csv header). Workspaces, onboarding items, campaigns, ad sets and creatives the engine drafted
-- are ordinary FF Marketing rows and are KEPT. No other object is changed: the backup policy needs no restore (ffm_* tables are excluded by rule).
begin;
drop function if exists public.ffm_engine_save_pack(uuid, text, jsonb, uuid, integer, text, text), public.ffm_engine_leaves(jsonb, text), public.ffm_engine_save_brief(uuid, jsonb, text),
  public.ffm_engine_create_workspace(text, text, text, text), public.ffm_engine_screen_texts(uuid, text[]), public.ffm_engine_screen(uuid, text, text);
drop table if exists public.ffm_engine_packs, public.ffm_engine_briefs;
commit;
