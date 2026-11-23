# Upstream

- **Template:** AstroWind, https://github.com/onwidget/astrowind, at commit `14e1a691f80548dcc36370847b1a02c0d0b12821` (2026-09-12).
- **Licence:** MIT (see `LICENSE.md`, kept unchanged as the licence requires).

## Changes for Web Studio
- **Removed:**
  - the demo pages, the blog posts and the Decap CMS admin;
  - the upstream agent instruction files;
  - the announcement bar;
  - third-party image preconnects.
- **Added:**
  - all copy and brand tokens now come from `src/data/site.json`, which `hq_webstudio.py stage` writes;
  - the futuristic art-direction layer (`src/assets/styles/fx.css`, `src/components/fx/`);
  - the Web Studio contact form (`src/components/widgets/SiteContact.astro`);
  - privacy and terms placeholder pages built from `site.json`.
- **The site address comes from the build environment** (`SITE_URL`, or Netlify's `URL`, in `vendor/integration/index.ts`), so no domain is hard-coded.

Dependencies install from `package-lock.json` with `npm ci --ignore-scripts`; no package install scripts run.

## Maison theme (gold, wine, black) — `"theme": "maison"` in site.json
Select it per site with `"variant": "futuristic", "theme": "maison"`; metal = `brand.accent`, wine = `brand.primary`, so any brand can wear it.
Files: `src/components/maison/*` (home page, header, footer, 3D stage, phone call demo, motion layer), `src/components/maison/scene/donna-scene.ts` (the three.js scene), `src/assets/styles/maison.css`, `public/maison/stage-*.webp` (stills of the scene for no-WebGL visitors).
The contact form markup lives once in `src/components/widgets/ContactForm.astro` (used by every theme; themes restyle it with CSS only).

### Third-party code and fonts in the maison theme (self-hosted; no runtime requests to other sites)
| Dependency | Version | Licence | Where | Why |
|---|---|---|---|---|
| Lenis (darkroom.engineering) | 1.3.27 (npm `lenis`, 2026-10-15) | MIT (`src/vendor/lenis/LICENSE`) | `src/vendor/lenis/lenis.mjs` (vendored unchanged except the source-map comment) | inertial smooth scrolling and anchor scrolling; off under prefers-reduced-motion |
| three.js (three.js authors) | r186.1 (npm `three@0.186.1`, 2026-09-24) | MIT (`src/vendor/three/LICENSE`) | `src/vendor/three/three.module.js` + `three.core.js` (unchanged) | WebGL renderer, PBR materials (metalness/roughness, clearcoat, transmission, dispersion), PMREM environment, instancing, points |
| three.js addons | same release | MIT | `src/vendor/three/addons/` — `postprocessing/{EffectComposer,RenderPass,ShaderPass,UnrealBloomPass,OutputPass,MaskPass,Pass}.js`, `shaders/{CopyShader,LuminosityHighPassShader,OutputShader}.js`, `geometries/RoundedBoxGeometry.js`; the only change is the bare `'three'` import rewritten to `'../../three.module.js'` (no bundler alias needed) | bloom, tone-mapped output pass, rounded calendar tiles |
| webgl-noise, 3D simplex noise (Ian McEwan, Ashima Arts; Stefan Gustavson) | github.com/ashima/webgl-noise | MIT | inlined GLSL in `donna-scene.ts` | the gold heart's living surface |
| Cormorant Garamond (Christian Thalmann) | Fontsource latest at build, weights 300/400, normal + italic, latin | SIL OFL 1.1 | Astro Fonts API (`astro.config.ts`), downloaded at build and served from `/_astro/fonts` | high-contrast display serif |
| Inter (Rasmus Andersson) | Fontsource, variable 100–900 (already used by AstroWind) | SIL OFL 1.1 | Astro Fonts API | text face |
| Tabler icons | `@iconify-json/tabler` (already a dependency) | MIT | inlined SVG at build | service icons |

Written for this template (no third-party code): the 3D scene itself (the gold armillary "instrument", the call particles and their four
layouts, the calendar, the per-section camera choreography, the studio environment, the vignette/grain/aberration pass), the phone call demo
(transcription, typing, live waveform), the bento grid, the scroll choreography (IntersectionObserver + CSS), magnetic buttons, the cursor
light, card tilt, price count-ups and the velocity marquee. The studio environment follows the approach of three.js's `RoomEnvironment`
(MIT; emissive boxes in a dark room, prefiltered with `PMREMGenerator`), so no HDR file is downloaded.
The 3D scene (~150 KB gzipped with three.js) is a separate chunk, imported only after the page has loaded and the browser is idle, and only
when a hardware GPU is present; everyone else sees the pre-rendered stills. Quality steps down on slow GPUs (bloom off, lower resolution,
half the particles, then a still frame), and rendering pauses in background tabs.
Considered and not used: GSAP (its "standard no-charge" licence is not MIT/Apache/BSD/ISC); the `postprocessing` and `maath` packages
(zlib / MIT, fine to use) were not needed because three's own addons cover bloom and the damping helpers are three lines.
three.js is vendored (like Lenis) rather than added to package.json because package manifests and lockfiles are protected paths.
Lenis is vendored rather than added to package.json because package manifests and lockfiles are protected paths (owner approval).
