# Donna.AI growth kit (branch `build/donna-growth`)

Client acquisition and online presence for Donna.AI's launch, except what `build/donna-launch` owns:
- site hosting and contact form;
- the demo line;
- the audit-call, walk-in and closing playbook;
- the offer sheet;
- onboarding.

**Status:**
- Everything here is a **draft**. Nothing has been sent, posted, created or paid for.
- `[OWNER: confirm]` marks your decisions.
- `[DEMO LINE]` is a placeholder for the live demo number. Paste it locally; do not commit phone numbers or business names to this repo.

| File | What it is |
|---|---|
| [CHANNELS.md](CHANNELS.md) | Every channel ranked by speed, cost and likelihood, with first actions, your time, cost and a funnel model. **§2: the 7 verticals ranked by fit, and the effort split.** |
| [LAUNCH_48H.md](LAUNCH_48H.md) | Hour 0 to 48, days 3 to 14, daily targets, pipeline math for 1, 3 and 10 clients, and how to maximise the odds |
| [RISK_REVERSAL.md](RISK_REVERSAL.md) | 3 guarantee, pilot and proof options with terms, legal notes and exposure math. **Owner decisions; none is live.** |
| [REP_PROGRAM.md](REP_PROGRAM.md) | Rep acquisition channel, rep sheet, and the commission proposal at founding prices |
| [PIPELINE_TRACKER.md](PIPELINE_TRACKER.md), [pipeline_tracker.csv](pipeline_tracker.csv), [pipeline_daily.csv](pipeline_daily.csv) | Stages, columns and daily numbers to track from day 1 |
| [SOURCES.md](SOURCES.md) | Every cited benchmark, and the label rules |
| `presence/` | [Google Business Profile](presence/GOOGLE_BUSINESS_PROFILE.md), [LinkedIn](presence/LINKEDIN.md), [social profiles](presence/SOCIAL_PROFILES.md), and the [28-script content calendar](presence/CONTENT_CALENDAR.md) ([csv](presence/content_calendar.csv); regenerate both with `python3 presence/gen_calendar.py presence`) |
| `outreach/` | [Vertical hooks](outreach/VERTICAL_HOOKS.md), [warm network](outreach/WARM_NETWORK.md), [cold email](outreach/COLD_EMAIL.md) (3 variants × 4 emails, CASL), [DMs](outreach/DM_SEQUENCES.md), [FB group posts](outreach/FACEBOOK_GROUP_POSTS.md), [partners and the one-pager](outreach/PARTNERS.md), [objections](outreach/OBJECTIONS.md), [follow-up cadences](outreach/FOLLOW_UP_CADENCES.md), [voicemail](outreach/VOICEMAIL.md), [referral ask](outreach/REFERRAL_ASK.md) |

**Site addition:** the Missed-Call Cost Calculator at `/calculator`, in the nav as "Calculator".
- `sites/_templates/astrowind/src/pages/[calculator].astro`
- `sites/_templates/astrowind/src/components/maison/Calculator.astro`
- the `calculator` block in `sites/donna/site.json`
- a one-line nav hook in `src/navigation.ts`

The page only builds for sites whose `site.json` has a `calculator` block.
