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
