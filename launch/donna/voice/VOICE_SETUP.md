# Donna.AI live demo line: Retell setup

The closer: a prospect calls **+1 (825) 462-1250** and talks to Donna.
- **Sales demo agent** (on the number): Donna sells Donna, then offers "Want to hear me answer as a heating company?"
- **Client demo agent** (Northbeam Heating & Plumbing, a made-up company): the swap target. The prospect plays a customer with a broken furnace and hears answer, qualify, urgent handling and booking. A text arrives after the call.

Both agents say they are AI in the first sentence, say the call is recorded, and never claim to be a real business.

## 1. Why Retell (researched 2026-11-24)

| Platform | Free to start | Numbers (Canada / US) | Per-minute (published) | Latency, p50 to first audio* | Fit for Donna |
|---|---|---|---|---|---|
| **Retell** (chosen) | $10 credits, 20 concurrent calls [1] | Bought in the dashboard: US $2/mo, **Canada $2/mo**, US toll-free $5/mo [2] | $0.07 to $0.31; sample $0.11 [1] | 1,740 ms | Already live with the Kate voice and the 825 number; Cal.com booking by OAuth [3]; agent swap and post-call analysis built in. SMS only on US numbers [4] |
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
| Call length cap | 15 min (sales agent) and 10 min (Northbeam), so one call costs at most about $2 |
| Client #1's local number | $2.00/month (Canada, Twilio or Bandwidth in Retell) [2] |
| Texts | Twilio's Canadian per-message rate on your existing Twilio account (check twilio.com/en-us/sms/pricing/ca) |
| Make.com | Free plan: 1,000 credits/month [11]; one call uses about 3 to 5 |
| Cal.com | Free for one user, unlimited bookings [12] |

These are Retell's prices in USD. Your Retell billing settings decide whether credit auto-recharges: that is your call.

## 3. The files

| File | What it is |
|---|---|
| `prompts/sales_demo.txt` | Sales demo prompt (paste into the existing agent on the 825 number) |
| `prompts/client_demo_hvac.txt` | Northbeam demo prompt (paste into a new agent) |
| `prompts/client_template.txt` | Prompt template for client #1 (see `../ONBOARDING.md`) |
| `agents.json` | Settings for both agents: welcome message, model, voice, post-call fields, tools |
| `retell/*.json` | The same, as import-ready request bodies for Retell's API, checked against Retell's published schema |
| `retell_push.py` | Optional: pushes the config by API from your own terminal. It is a dry run unless you add `--apply` |

## 4. Your steps in the Retell dashboard (about 20 minutes)

**Before you change anything:** open the existing agent on the 825 number, copy its prompt and welcome message into a note. That is your rollback.

**A. Northbeam agent (new)**
1. Agents > **Create agent** > **Single Prompt**. Name it `Donna.AI demo - Northbeam Heating & Plumbing (fictional)`.
2. Paste all of `prompts/client_demo_hvac.txt` into the prompt box.
3. Welcome message: *"Thanks for calling Northbeam Heating and Plumbing, a made-up demo company from Donna.AI. I'm Donna, the AI receptionist, and this call is recorded. How can I help you today?"* AI speaks first.
4. Voice: **Kate** (ElevenLabs). Voice model: ElevenLabs **Flash v2.5**. Model: **gpt-4.1-mini**. Language: English (US). Timezone: America/Toronto.
5. Post-call analysis: add the 8 fields listed under `client_demo_hvac.agent.post_call_analysis_data` in `agents.json`. Use the same names (Make reads them), and set each to "allow empty".
6. Optional but strong: Functions > **+ Add** > **Cal.com** (connect once by OAuth) > **Check Availability**, name it `check_availability`; then **Book Appointment**, name it `book_appointment`. Pick a Cal.com event called "Northbeam demo visit (fictional)", 30 min, timezone America/Toronto [3]. Without these tools Donna does a spoken demo booking instead.
7. Save, **Publish**, and copy the agent ID (keep it out of the repo).

**B. Sales agent (the existing one on the 825 number)**
1. Paste all of `prompts/sales_demo.txt` over the old prompt.
2. Welcome message: *"Donna speaking — Donna.AI. Quick heads-up: I'm an AI, and this call is recorded. So you want to know what I'm about. Smart move. Tell me — what kind of business do you run?"* This keeps your original greeting, with the brand changed to Donna.AI and the AI and recording notice added.
3. Keep Kate. Set voice model Flash v2.5 and model gpt-4.1-mini.
4. Functions > **+ Add** > **Agent swap** > choose the Northbeam agent. Name it `switch_to_hvac_demo`. Keep current voice: on. Post-call analysis: both agents.
5. Optional: Functions > **Transfer call** > your mobile number. Name it `transfer_to_founder`. Skip it if you can't take calls at work: Donna then takes a message.
6. Cal.com: `check_availability` and `book_appointment` on your "Donna.AI demo" event (20 min, Zoom).
7. Post-call analysis: the 10 fields under `sales_demo.agent.post_call_analysis_data`.
8. Save and **Publish**. Then Phone Numbers > +1 (825) 462-1250 > check the inbound agent is this agent.

**C. Webhook (after Make step 1 in `MAKE_SCENARIOS.md`):** paste the Make webhook URL into **both** agents' webhook URL, events: `call_analyzed` only. Publish both.

**Or by script** (instead of A and B, from your own terminal; keys stay in your shell):
```
export RETELL_API_KEY=...            # Retell > Settings > API keys
export DONNA_SALES_AGENT_ID=...      # existing agent on the 825 number (it is updated; its voice is kept)
export DONNA_MAKE_WEBHOOK_URL=...    # optional
python3 launch/donna/voice/retell_push.py push            # dry run: shows what would change
python3 launch/donna/voice/retell_push.py push --apply    # sends it; then Publish in the dashboard
```
The Cal.com tools are still added by clicks (step A6 and B6). The script has not been run against the live API (no key in this environment).

## 5. Test-call checklist (do all of it before the number goes on any outreach)

Call from your own mobile. Write down the actual result next to each expected one. Fix the prompt and call again until all pass.

| # | Do this | Expected |
|---|---|---|
| 1 | Call 825-462-1250 | Greeting says Donna.AI, AI, and recorded, within about 2 s |
| 2 | "Are you a real person?" | "I'm an AI" plainly |
| 3 | "How many clients do you have?" / "Do you guarantee results?" | No numbers, no guarantee; offers the free audit |
| 4 | "What does it cost?" | Founding $497 / $797 / $1,297 a month (standard $697 / $1,097 / $1,797 after the 10 spots), Capture suggested, setup included, month-to-month |
| 5 | "Sure, show me the heating company" | Swaps to Northbeam; the greeting says it is a made-up demo company |
| 6 | "Is Northbeam a real company?" | Says it is made up, and that this is what your customers would hear |
| 7 | "I smell gas" | Leave the building, call the gas utility or 911 from outside; no booking; marked urgent |
| 8 | "My furnace stopped, it's freezing" | Urgent handling, then the earliest slot; asks name, number, area |
| 9 | Book a time | Cal.com booking appears in your calendar (or a spoken demo booking if no tools) |
| 10 | Say yes to a text | Text arrives within about 2 min of hanging up, with "Reply STOP to opt out" |
| 11 | New call, say **no** to a text | No text to the caller; you still get the summary |
| 12 | Call and hang up after 3 s | Missed-call text-back arrives |
| 13 | Ask the price of something not listed | Does not invent one |
| 14 | Talk over Donna | She stops and listens |
| 15 | Retell > Call history | Each call has a summary and the post-call fields filled |

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
