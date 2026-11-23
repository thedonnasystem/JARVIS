# Web Studio: websites for every office and for Donna clients

Status: milestone 1, built and tested locally. **Nothing is deployed.** The first site is Donna.AI (`sites/donna/site.json`).

## Why an internal pipeline and not bolt.diy
- **bolt.diy (MIT)** is an interactive, browser-based AI IDE: Remix, WebContainers, and a person driving it. It is not a server-side pipeline the bot can call, it lets the model freehand code, and running it would add a second app to host.
- **What we need** is narrower: the model fills content slots in a vetted template, then build, QA, preview and publish happen with approvals.
- **That fits in one module** (`hq_webstudio.py`, standard library only) plus a template library in `sites/_templates/`.

## Pipeline
1. **Draft or edit.** Run `/site new …` or `/site edit <slug> | <change>`.
   - `hq_llm` (owner-data routing) returns JSON for the content slots only: `meta, hero, demo, services, steps, offer, faq, contact, results`.
   - Brand tokens, prices, legal placeholders, the consent wording and the layout are never the model's. A draft or edit that changes a price is refused.
2. **Validate.** `validate()` applies the content rules below, then the site becomes a **pull request** of `sites/<slug>/site.json` (via `hq_dev`).
   - Every edit bumps `version`, so each change request gives a new version and a new preview.
3. **Build.** `python3 hq_webstudio.py build <slug>`:
   - copies the template;
   - writes `site.json` (plus the fixed consent block) and `config.yaml`;
   - runs `npm ci --ignore-scripts` from the template's lockfile, then `astro build`;
   - runs QA and zips the result.
   - CI runs this for every site (`.github/workflows/sites.yml`, read-only, no secrets, deploys nothing).
4. **Preview.** `/site preview <slug>` queues a hands `deploy` on the site's connected Netlify account as a **draft** deploy (preview URL; the live site is untouched). The owner approves it in Telegram.
5. **Publish.** `/site publish <slug>` queues a production deploy, also approved by the owner in Telegram.
6. **Domain.** Buying the domain and pointing it at Netlify is the owner's step. The sites contain no domain: the address comes from `SITE_URL` or Netlify's `URL` at build time.
7. **Leads.** `/site leads <slug>` reads the site's Netlify form submissions with the connected account's vault token and saves them as `leads`.
   - Saving is idempotent on the submission ID; the suppression and DNC triggers still apply.
   - Consent is recorded as stated: implied consent from the inquiry, express marketing consent only if the optional box was ticked, plus the wording version and its SHA-256.
   - Nothing is sent: follow-up goes through the normal outbox drafts and approvals.

Registered as the shared service `web_studio` in `fz_services` (migration `20261205_web_studio_v1.sql`; rollback `ops/rollback_web_studio.sql` retires the row).

## Template library (curated, commercial-safe licences only)
| Template | Licence | Variants |
|---|---|---|
| `astrowind`: AstroWind (Astro 7 + Tailwind 4), upstream commit `14e1a69` | MIT | `futuristic`, `local` |

**Futuristic variant:**
- dark only, with brand-token glow accents and glass cards;
- a canvas "voice orb" hero, about 2 KB with no library, paused off-screen;
- a call-transcript demo panel labelled as an illustration;
- one-time scroll reveals and bold display type.

All motion is off under `prefers-reduced-motion`, and all content is readable without JavaScript.

**Honest note on sourcing.**
- I looked for a design-led futuristic MIT/Apache template first. The Astro theme catalogue's futuristic SaaS templates are paid, `blackspike-astro-landing-page` is CC-BY-4.0 (not MIT/Apache), and Magic UI's full templates are Pro (paid).
- So the flagship is AstroWind (MIT, maintained) with a purpose-built art-direction layer, scoped under `html.fx`.
- Adding 2 to 4 more flagships (for example shadcn- or Magic UI-component-based ones, whose open-source components are MIT) is milestone 2.

## Content rules (every site, enforced in `validate` and `qa_dist`)
- **Claims:**
  - no testimonials, reviews, client counts, logos or stats sections;
  - case studies are empty slots only;
  - no guarantee, refund, "risk-free", "#1" or "award-winning" wording.
- **Copy:** no AI clichés (unlock, seamless, elevate, revolutionize, empower, leverage, cutting-edge, "in today's fast-paced world", and others), and no HTML in copy.
- **Contact form:**
  - a same-site Netlify form with a honeypot;
  - the CASL inquiry notice and the optional, unticked marketing box, shown verbatim;
  - the wording version is recorded.
- **Legal:** privacy and terms are draft placeholders with an owner-review banner.
- **Build output:** no external scripts, no iframes and no remote assets; mobile viewport; brand name in every title; no template leftovers.
- **Owner-review items** (placeholders, the booking link, `owner_review` notes) are listed on every build. They must be cleared before a publish.

## Not yet (milestone 2)
- **Lighthouse 90+ is not measured** in this sandbox.
  - What I did measure: the home page ships about 300 KB uncompressed (66 KB HTML, 124 KB CSS, 73 KB of one self-hosted font, 16 KB JS), with no third-party requests.
  - A Lighthouse CI step and screenshot-rubric QA (spacing, hierarchy, contrast) belong in the sites workflow.
- Desktop and mobile screenshots were checked by eye in headless Chrome; there is no automated visual rubric yet.
- **Creative Studio does not exist yet.** Hero imagery is the built-in orb scene; custom renders will come from Creative Studio.
- **Build zips are not hosted yet.** Previews need `JARVIS_WEBSTUDIO_ZIP_BASE`: an https location where CI uploads `<slug>-v<version>.zip` (owner decision on where, for example a Supabase Storage bucket). Until then, preview and publish say what is missing and do nothing.
- More flagship templates, and a per-site type pairing choice.

## Owner checklist for Donna.AI
- Choose and buy the domain (donna.ai or a .ca variant).
- Fill in the Cal.com link and the demo line number in `site.json`.
- Have the privacy policy and terms reviewed.
- Confirm the package contents. Only offer what is delivered and tested.
- Create a free Netlify site and connect it: `/connect netlify` with the handle `donna`.
