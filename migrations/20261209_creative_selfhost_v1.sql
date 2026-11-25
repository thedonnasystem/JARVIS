-- FENDEZY AI CREATIVE STUDIO: self-hosted ComfyUI worker provider row (hq_creative_selfhost; docs/architecture/CREATIVE_SELFHOST.md).
-- Additive and idempotent. No functions, no grants. The row starts OFF: the owner enables it with creative_owner_set_provider('comfyui-selfhost', true)
-- after a worker has passed its selftest. 0 CAD cents per call (our own worker): the router never reserves for it, and the existing fal.ai caps are unchanged.
-- A rented pod is paid per hour outside the studio (owner decision; the worker stops itself when idle).
set lock_timeout = '5s';

insert into fz_creative.providers (slug, title, kind, modules, models, env_key, est_cents, unit, note) values
  ('comfyui-selfhost', 'Self-hosted ComfyUI worker (Kaggle free GPU, an owned GPU or an owner-rented pod): 0 per call', 'local', array['video', 'image', 'ugc', 'voice'],
     array['flux.1-schnell', 'flux.1-schnell-lora', 'kokoro-82m', 'wan-2.2-s2v-14b', 'wan-2.2-t2v-a14b', 'wan-2.2-ti2v-5b', 'z-image-turbo', 'z-image-turbo-lora'],
     'COMFYUI_SELFHOST_URL', 0, 'job',
     'free per call; models and licences in creative_studio/selfhost/manifest.json (Apache-2.0 weights only; LTX-Video only behind CREATIVE_LTX_LICENCE_OK)')
on conflict (slug) do update set title = excluded.title, kind = excluded.kind, modules = excluded.modules, models = excluded.models, env_key = excluded.env_key,
  est_cents = excluded.est_cents, unit = excluded.unit, note = excluded.note;   -- 'enabled' stays the owner's
