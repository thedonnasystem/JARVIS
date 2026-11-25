# Donna.AI live demo line: Retell setup

The closer: a prospect calls **+1 (825) 462-1250** and talks to Donna. It is **one agent** with one prompt.
1. **Sales:** Donna asks what kind of business they run and what happens to their missed calls.
2. **Demo:** Donna offers to answer as a made-up company in *their* industry, and the prospect plays a customer.
3. **Close:** Donna offers the free audit or a call with the founder. Texts go out after the call.

Demo companies, all fictional:

| Industry | Demo company |
|---|---|
| Home services (HVAC, plumbing, electrical, roofing) | Northbeam Home Services |
| Med spa, salon, beauty | Willow & Ash Studio |
| Dental, chiropractic, clinic (booking only, no medical advice) | Larkfield Family Dental & Wellness |
| Law firm intake (no legal advice) | Hollis & Grey Law |
| Auto repair and detailing | Ironclad Auto Care |
| Real estate agent | Keystone Home Team |
| Cleaning, landscaping, renovation | Fresh Slate Property Care |
| Anything else | "Example & Co." adapted to their business, with no prices quoted |

Donna says she is an AI in her first sentence and says the call is recorded. She calls each demo company made-up, and never claims to be a real business.
One agent instead of eight: one paste, one thing to update, and no handoff between agents to break.

## 1. Why Retell (researched 2026-11-24)

| Platform | Free to start | Numbers (Canada / US) | Per-minute (published) | Latency, p50 to first audio* | Fit for Donna |
|---|---|---|---|---|---|
| **Retell** (chosen) | $10 credits, 20 concurrent calls [1] | Bought in the dashboard: US $2/mo, **Canada $2/mo**, US toll-free $5/mo [2] | $0.07 to $0.31; sample $0.11 [1] | 1,740 ms | Already live with the Kate voice and the 825 number; Cal.com booking by OAuth [3]; post-call analysis built in. SMS only on US numbers [4] |
| Vapi | $5 credits; 4 concurrent calls [5] | 1 free number, **US area codes only**, inbound only; Canada means importing a Twilio number [6] | $0.05/min hosting plus providers; calculator $82 to $129 per 1,000 min [5] | 1,558 ms | Set up earlier as a backup, but it lacks the Kate voice (owner's history) |
| ElevenLabs Agents | Free plan: 15 min/month, 4 concurrent [7] | Not sold on the pricing page; telephony "at cost" [7] | $0.08/min listed [7] | 1,424 ms | Fast, but 15 free minutes and number setup through another provider |
| Synthflow | Small trial pool, amount not published [8] | Native numbers in US, Canada, Australia [8] | From about $0.13/min [8] | not benchmarked | No published free credits; source is a competitor's article |
| Bland | Free to activate; 100 calls/day cap; no free credits stated [9] | Not published [9] | $0.14/min on the free plan [9] | 1,520 ms | No free credits; pricier per minute |

\* OpenBenchmarks Labs, 550 real phone calls, generated 2026-08-01 [10]. Telnyx led at 1,296 ms. Retell was the slowest of the five in that run, by about 0.3 s against ElevenLabs. Not decisive: the gap is small, the agents used mostly default settings, and switching would throw away a working agent, voice and number. Retell's speed settings (`responsiveness` 0.9, ElevenLabs Flash voice model) are set in the config.

**Decision: stay on Retell.** No platform gives a decisive reason to move. Retell is the only one with the Kate voice already working, Canadian numbers for $2 straight from the dashboard, and a Cal.com connection without code.
**The one gap:** Retell's SMS add-on is disabled for non-US numbers [4], so the 825 number cannot text. Texts go out through Make.com plus one of your existing Twilio Canadian numbers (see `MAKE_SCENARIOS.md`).

## 2. What it costs (exact where published)

| Item | Cost |
|---|---|
| Demo number +1 (825) 462-1250 | $2.00/month (already owned) [2] |
| A call minute | about **$0.12 to $0.13 (USD)**: Retell voice infrastructure $0.055 + ElevenLabs Flash voice $0.040 + LLM (gpt-4.1-mini; Retell lists mini models from $0.008 to $0.024) + telephony $0.015 [1]. A 4-minute demo is about $0.50 |
| Call length cap | 15 min, so one call costs at most about $2 |
| Client #1's local number | $2.00/month (Canada, Twilio or Bandwidth in Retell) [2] |
| Texts | Twilio's Canadian per-message rate on your existing Twilio account (check twilio.com/en-us/sms/pricing/ca) |
| Make.com | Free plan: 1,000 credits/month [11]; one call uses about 3 to 5 |
| Cal.com | Free for one user, unlimited bookings [12] |

These are Retell's prices in USD. Your Retell billing settings decide whether credit auto-recharges: that is your call.

## 3. The files

| File | What it is |
|---|---|
| `prompts/demo_line.txt` | The whole demo-line prompt (sales plus the 8 industry demos). Paste it into the existing agent on the 825 number |
| `prompts/client_template.txt` | Prompt template for client #1 (see `../ONBOARDING.md`) |
| `agents.json` | The agent's settings: welcome message, model, voice, post-call fields, tools |
| `retell/demo_line.*.json` | The same, as import-ready request bodies for Retell's API, checked against Retell's published schema |
| `retell_push.py` | Optional: pushes the config by API from your own terminal. It is a dry run unless you add `--apply` |

## 4. Your steps in the Retell dashboard (about 10 minutes)

**Before you change anything:** open the existing agent on the 825 number and copy its prompt and welcome message into a note. That is your rollback.

1. **Prompt:** paste all of `prompts/demo_line.txt` over the old prompt.
2. **Welcome message, AI speaks first:** *"Donna speaking — Donna.AI. Quick heads-up: I'm an AI, and this call is recorded. So you want to know what I'm about. Smart move. Tell me — what kind of business do you run?"* This is your original greeting, with the brand changed to Donna.AI and the AI and recording notice added.
3. **Voice and model:**
   - Voice: keep **Kate** (ElevenLabs).
   - Voice model: ElevenLabs **Flash v2.5**.
   - Model: **gpt-4.1-mini**.
   - Language: English (US). Timezone: America/Toronto.
4. **Post-call analysis:** add the 13 fields listed under `post_call_analysis_data` in `agents.json`. Use the same names, because Make reads them, and set each to "allow empty".
5. **Optional, transfer:** Functions > **Transfer call** > your mobile, named `transfer_to_founder`. Skip it if you can't take calls at work: Donna then takes a message.
6. **Optional, Cal.com:** Functions > **+ Add** > **Cal.com** (connect once by OAuth) [3].
   - Add **Check Availability**, named `check_availability`, and **Book Appointment**, named `book_appointment`, on your "Donna.AI demo" event (20 min, Zoom, timezone America/Toronto).
   - Without these tools, Donna offers to text the booking link, and demo bookings are spoken.
7. **Publish.** Then go to Phone Numbers > +1 (825) 462-1250 and check that this agent is the inbound agent.
8. **Webhook** (after step 1 in `MAKE_SCENARIOS.md`): paste the Make webhook URL into the agent's webhook URL, event `call_analyzed` only, then Publish.

**Or by script**, from your own terminal (keys stay in your shell):
```
export RETELL_API_KEY=...            # Retell > Settings > API keys
export DONNA_DEMO_AGENT_ID=...       # existing agent on the 825 number (updated; its voice is kept)
export DONNA_ALERT_WEBHOOK_URL=https://<your-site>/.netlify/functions/retell-webhook    # optional: lead alerts
python3 launch/donna/voice/retell_push.py push            # dry run
python3 launch/donna/voice/retell_push.py push --apply    # sends it; then Publish in the dashboard
```
The script covers steps 1 to 4 and 8. Cal.com is still added by clicks. The script has not been run against the live API (no key in this environment).

## 5. Test-call checklist (all of it, before the number goes on any outreach)

Call from your own mobile and write the actual result next to each expected one. Fix the prompt and call again until all pass.

| # | Do this | Expected |
|---|---|---|
| 1 | Call 825-462-1250 | Greeting says Donna.AI, AI and recorded, within about 2 s |
| 2 | "Are you a real person?" | "I'm an AI" plainly |
| 3 | "How many clients do you have?" / "Do you guarantee results?" | No numbers, no guarantee; offers the free audit |
| 4 | "What does it cost?" | Founding $497 / $797 / $1,297 a month (standard $697 / $1,097 / $1,797 after the 10 spots), Capture suggested, setup included, month-to-month |
| 5 | "I run a plumbing company", then yes to the demo | Northbeam, introduced as made-up; asks what's happening |
| 6 | In the Northbeam demo: "I smell gas" | Leave the building, call the gas utility or 911 from outside; no booking |
| 7 | New call: "I own a med spa", demo: "I want Botox" | Free consult with the licensed provider; no treatment advice |
| 8 | New call: "dental office", demo: "my tooth hurts, what should I take?" | No advice; books the earliest emergency slot |
| 9 | New call: "law firm", demo: "do I have a case?" | No legal advice; books a consultation; asks about deadlines |
| 10 | New call: "I'm a realtor", demo: "what should I list at?" | No price advice; books a home-value consultation |
| 11 | New call: "I run a bakery" | Example & Co. demo, no invented prices |
| 12 | "Is this company real?" during any demo | Made-up demo company, Donna is an AI from Donna.AI |
| 13 | Book a time (founder call or demo) | Cal.com booking appears, or a spoken demo booking if no tools |
| 14 | Say yes to a text | Text within about 2 min of hanging up, with "Reply STOP to opt out" |
| 15 | New call, say **no** to a text | No text to the caller; you still get the summary |
| 16 | Call and hang up after 3 s | Missed-call text-back arrives |
| 17 | Talk over Donna | She stops and listens |
| 18 | Retell > Call history | Each call has a summary and the post-call fields filled |

## Sources (accessed 2026-11-24 unless dated)
1. Retell pricing: https://www.retellai.com/pricing
2. Retell, purchase a number: https://docs.retellai.com/deploy/purchase-number
3. Retell, Cal.com booking (connection-based; the built-in Cal tools stopped being creatable on 2026-09-30): https://docs.retellai.com/build/book-calendar
4. Retell, enable SMS ("the SMS add-on is disabled for non-US numbers"): https://docs.retellai.com/deploy/enable-sms
5. Vapi pricing: https://vapi.ai/pricing
6. Vapi free telephony: https://docs.vapi.ai/free-telephony
7. ElevenLabs Agents pricing: https://elevenlabs.io/pricing/agents
8. CloudTalk, "Synthflow pricing", updated 2026-07-03 (competitor-written): https://www.cloudtalk.io/blog/synthflow-pricing/
9. Zeeg, "Bland AI pricing", updated 2026-10-30 (competitor-written): https://zeeg.me/en/blog/post/bland-ai-pricing
10. OpenBenchmarks Labs, voice agent latency, generated 2026-08-01: https://github.com/openbenchmarks-labs/voice-agent-latency
11. Make pricing: https://make.com/en/pricing
12. Cal.com pricing: https://cal.com/pricing
13. Retell OpenAPI spec, revision 2026-11-24-cf220c4 (the schema subset in `schema/` comes from it; Apache-2.0): https://docs.retellai.com/openapi.yaml

## Website Donna ("Talk to Donna now" on the site)
A second Retell agent, `web_qualify`, talks with site visitors in the browser: finds their problem, sells with certainty (never promises results), gives a taste, never quotes prices beyond "plans start at $197 a month", and books 20 minutes with our AI specialist.
1. Retell → Agents → import `retell/web_qualify.llm.json` and `retell/web_qualify.agent.json` (or `python3 retell_push.py push web_qualify` with `RETELL_API_KEY` set in your own shell).
2. On that agent, add the Cal.com tools (check availability + book appointment) for your 20-minute "Donna.AI call" event, named `check_availability` and `book_appointment`.
3. Retell → API keys → create a **public** key and restrict it to your site's domain(s) (the Netlify address, later your own domain). Never use the secret key here.
4. Netlify → Site configuration → Environment variables (you paste them): `PUBLIC_DONNA_WEB_KEY` = that public key, `PUBLIC_DONNA_WEB_AGENT` = the web agent's id. Then Deploys → Trigger deploy.
5. Test: open the site on your phone and laptop, click "Talk to Donna now", allow the microphone, and run one call as a plumber, one as a med spa and one as "I need an AI agent for my admin". Check a booking lands in Cal.com.
Until both variables are set, the button calls the demo line instead, so the site never shows a dead button. Calls are capped at 8 minutes; cost is the same per-minute rate as phone calls.
