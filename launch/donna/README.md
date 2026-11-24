# Donna.AI first-client launch kit

Goal: **client #1**. Everything here runs on free tiers and accounts you already have (Retell, Twilio, Cal.com, Make, Tally, Helcim, DocuSign).
It does not depend on merging any Jarvis PR: Netlify builds this branch (`build/donna-launch`) directly.

| File | What it's for |
|---|---|
| `SITE_GO_LIVE.md` | Put the site live on Netlify Free, with the working contact form; domain later |
| `netlify.toml`, `build_site.sh` | Netlify build config (base directory `launch/donna`) |
| `voice/VOICE_SETUP.md` | Demo line on Retell: why Retell, costs, dashboard steps, test-call checklist |
| `voice/prompts/` | Sales demo prompt, Northbeam (fictional HVAC) demo prompt, client prompt template |
| `voice/agents.json`, `voice/retell/`, `voice/retell_push.py` | Import-ready Retell config, validated against Retell's schema; optional API push |
| `voice/MAKE_SCENARIOS.md` | The Make.com scenario: call summary to you, missed-call text-back, confirmations |
| `PLAYBOOK_FIRST_CLIENT.md` | Niche, list building, the after-hours audit, the sequence, the demo moment, closing, CASL |
| `audit_log.csv`, `scoreboard.csv` | The audit log sheet and the daily scoreboard (open in Google Sheets or Excel) |
| `offer_sheet.html` | One-page founding offer (print to PDF, Letter) |
| `ONBOARDING.md` | Client #1 in 48 h: Tally intake, cloning the agent, Cal.com, call forwarding codes, go-live test, weekly text |

## Your launch hour (in this order)

**1. Send Claude three things (5 min).** Claude updates the files and pushes.
- Legal business name, mailing address and email for the site footer and sender ID (CASL needs it).
- Your Cal.com demo link: in Cal.com create a 20-minute "Donna.AI demo" event with Zoom, then copy its link.
- Name, phone and email for the offer sheet footer.

**2. Site live (10 min): `SITE_GO_LIVE.md`, Option A.**
1. Netlify > Sign up with GitHub > Import `thedonnasystem/JARVIS` > branch `build/donna-launch` > base directory `launch/donna` > Deploy.
2. Forms > Enable form detection > Trigger deploy.
3. Add an email notification.
4. Send a test form.

**3. Demo line (15 min): `voice/VOICE_SETUP.md`, steps A and B.**
1. Copy the old prompt somewhere safe.
2. Create the Northbeam agent and paste its prompt.
3. Paste the sales prompt into the agent on 825-462-1250.
4. Add the agent swap.
5. Publish both.

**4. Texts and summaries (15 min): `voice/MAKE_SCENARIOS.md`.**
1. Make > new scenario > webhook > router with routes A, B and C, using your Twilio Canadian number.
2. Paste the webhook URL into both agents and Publish.

**5. Test (10 min).** Run the 15-call checklist in `VOICE_SETUP.md`, and fix anything that fails before the number goes out.

**Tonight:** start `PLAYBOOK_FIRST_CLIENT.md` section 8: 20 after-hours audit calls, 6 to 7 p.m.

**This week (not needed to start):**
- Register as a telemarketer with the National DNCL (lnnte-dncl.gc.ca). Calls to businesses are exempt from the list itself, but registration is still required.
- Add the Cal.com booking tools to both agents.
- Build the Tally intake form (`ONBOARDING.md` §1).
- Print 20 offer sheets.

## Ground rules this kit follows
- Donna always says she is an AI and that the call is recorded.
- The demo company is made up and Donna says so.
- No statistics, testimonials, client counts or guarantees anywhere: there are none yet. The free audit is the proof.
- Standard prices are never shown as "regular" or "was" prices (Competition Act s.74.01).
- No keys, agent IDs or webhook URLs are kept in the repo. `retell_push.py` reads them from your shell.
- Claude creates no accounts, buys nothing, deploys nothing and contacts no business: those are your clicks.
