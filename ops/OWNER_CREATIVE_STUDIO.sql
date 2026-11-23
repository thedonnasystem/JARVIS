-- FENDEZY AI CREATIVE STUDIO: OWNER release steps (Supabase SQL editor, signed in as the owner). Run AFTER migrations/20261205_creative_studio_v1.sql.
-- Nothing here spends money. Every step is audited. Read docs/architecture/PHASE1_M8_CREATIVE_STUDIO.md first.

-- 1. Register the shared service (M5 registry; owner = group). Until this row is active, every studio write refuses.
--    (Not done by the migration: M5's protected sqltest pins exactly six services; see ops/proposals/creative_studio_registry.md.)
insert into public.fz_services (service, title, owner_office, writes, reads, attribution, scoped_identity, modules, note)
select 'creative_studio', 'FENDEZY AI CREATIVE STUDIO (images, video, UGC, voice, music, copy, editing)', id, '{hand_actions}', '{}', 'derived', 'jarvis',
       'hq_creative_studio.py', 'private schema fz_creative; publishing only through the hands pipeline'
  from public.fz_offices where slug = 'group'
on conflict (service) do nothing;

-- 2. Storage: ONE private bucket. No public access, no listing policy (the service key uploads; viewers get signed URLs only).
insert into storage.buckets (id, name, public) values ('creative-studio', 'creative-studio', false) on conflict (id) do nothing;

-- 3. Brand kits: the group, then one per office as each office goes live (keys: tone, colours, fonts, do, dont, disclaimers, logos, voice).
-- select public.creative_owner_set_brand_kit('group', '{"tone": "confident, plain", "dont": ["guaranteed results"], "disclaimers": []}');
-- select public.creative_owner_set_brand_kit('the-trap', '{"tone": "bold streetwear", "colours": ["#111111", "#f4c430"], "dont": [], "disclaimers": []}');

-- 4. Providers: all OFF. Turn on the free ones, then ONE hosted provider for the first real run (its key goes in Railway Variables).
-- select public.creative_owner_set_provider('copy-llm', true);
-- select public.creative_owner_set_provider('fal-hosted', true);            -- or 'replicate-hosted'

-- 5. Optional, per office (default: no creative limit, offices draw on need; premium off; 3 attempts; 20 jobs a day)
-- select public.creative_owner_set_office('ff-marketing', true, null, 3, 20);  -- FF Marketing hero ads may use premium (once a premium adapter exists)
-- select public.creative_owner_set_office('the-trap', false, 2000, 3, 20);     -- an OPTIONAL weekly creative limit of $20

-- 6. Real people: record consent BEFORE any likeness / voice is used; characters for consistent content (fictional unless consent is recorded)
-- select public.creative_owner_record_consent('pimp-ai', 'Model A', 'AI presenter for app ads, 12 months', '<where the signed release is kept>');
-- select public.creative_owner_add_character('pimp-ai', 'nova', 'nova_char', false);

-- 7. Hand-made assets from any outside tool (e.g. Higgsfield), uploaded first to creative-studio/<office>/imports/...
-- select public.creative_owner_import('ff-marketing', 'campaign', 'spring-hero', 'ff-marketing/imports/spring-hero.mp4', 'video/mp4', <bytes>, '<sha256>', 'higgsfield', <cents paid>, true);

-- 8. Decide a finished creative (publishing is then a separate hands approval)
-- select public.creative_owner_decide('<job id>', true, 'ok');

-- 9. M8c (after migrations/20261207_creative_studio_v2.sql). Free local editing (B-roll stitch, beat-synced cuts, visualizers) on the Jarvis host:
-- select public.creative_owner_set_provider('local-edit', true);
--    Templates: the shipped library is seeded; edit or retire one (the seed never overwrites your edit):
-- select public.creative_owner_set_template('trap-flat-lay', 'the-trap', 'image', 'product', 'Flat lay', array['drop-reveal'], '{"prompt": {"base": "{product} flat lay"}}', 'active');
--    Self-hosted ComfyUI (later cost step): ops/proposals/creative_comfyui_selfhost.md, then
-- select public.creative_owner_set_provider('runpod-comfyui', true);   -- also RUNPOD_API_KEY + COMFYUI_RUNPOD_ENDPOINT in Railway Variables

-- Retire (never delete): update public.fz_services set status = 'retired' where service = 'creative_studio';
