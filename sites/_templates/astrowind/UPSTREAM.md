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
Files: `src/components/maison/*` (home page, header, footer, WebGL orb, phone call demo, motion layer), `src/assets/styles/maison.css`.
The contact form markup lives once in `src/components/widgets/ContactForm.astro` (used by every theme; themes restyle it with CSS only).

### Third-party code and fonts in the maison theme (self-hosted; no runtime requests to other sites)
| Dependency | Version | Licence | Where | Why |
|---|---|---|---|---|
| Lenis (darkroom.engineering) | 1.3.27 (npm `lenis`, 2026-10-15) | MIT (`src/vendor/lenis/LICENSE`) | `src/vendor/lenis/lenis.mjs` (vendored unchanged except the source-map comment) | inertial smooth scrolling and anchor scrolling; off under prefers-reduced-motion |
| Cormorant Garamond (Christian Thalmann) | Fontsource latest at build, weights 300/400, normal + italic, latin | SIL OFL 1.1 | Astro Fonts API (`astro.config.ts`), downloaded at build and served from `/_astro/fonts` | high-contrast display serif |
| Inter (Rasmus Andersson) | Fontsource, variable 100–900 (already used by AstroWind) | SIL OFL 1.1 | Astro Fonts API | text face |
| Tabler icons | `@iconify-json/tabler` (already a dependency) | MIT | inlined SVG at build | service icons |

Written for this template (no third-party code): the liquid-metal orb (raw WebGL, one fragment shader, value noise),
the phone call demo, the bento grid, the scroll choreography (IntersectionObserver + CSS) and magnetic buttons.
Considered and not used: GSAP (its "standard no-charge" licence is not MIT/Apache/BSD/ISC), three.js/OGL (MIT, but a single
full-screen shader needs no engine; raw WebGL keeps the page about 6 KB of orb JS instead of 150+ KB).
Lenis is vendored rather than added to package.json because package manifests and lockfiles are protected paths (owner approval).
