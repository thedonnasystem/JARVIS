# Make.com scenarios for the demo line and client #1

Retell can't text from Canadian numbers, so texts go out from Make.com using one of your existing Twilio Canadian numbers.
One scenario covers the three jobs and runs once per call:
1. call summary to you;
2. missed-call text-back;
3. booking confirmation or booking link.

These are step-by-step specs, not importable blueprint files. A Make blueprint carries account-specific module versions and connection IDs. One written blind, without your account, would likely import broken, and it could not be tested here.
Building it takes about 15 minutes of clicks.

## Scenario 1: "Donna - after every call"

| # | Module | Settings |
|---|---|---|
| 1 | **Webhooks > Custom webhook** | Add > name `retell-donna` > Save > **Copy address**. Paste it into both Retell agents (webhook URL, event `call_analyzed`). Then click **Run once** and make a test call, so Make learns the data structure. |
| 2 | **Filter** (on the line after 1) | `event` = `call_analyzed` AND `call.direction` = `inbound` |
| 3 | **Router** | three routes below |

Retell sends `{event, call}`.
- `call` holds `from_number`, `to_number`, `agent_id`, `duration_ms`, `disconnection_reason` and `call_analysis`.
- `call_analysis` holds `call_summary` and `custom_analysis_data`, with the post-call fields from `agents.json`.

**Route A: summary to you (always)**
- Module: **Twilio > Create a Message**.
  - From: your Twilio Canadian number.
  - To: your mobile.
- Body:
  `{{if(call.call_analysis.custom_analysis_data.urgent; "URGENT "; "")}}Donna call from {{call.from_number}} ({{call.call_analysis.custom_analysis_data.caller_name}}): {{substring(call.call_analysis.call_summary; 0; 240)}} Booked: {{ifempty(call.call_analysis.custom_analysis_data.appointment_time; "no")}}`
- Alternative: **Gmail > Send an email** to yourself. Use it if you'd rather not pay for the text.

**Route B: missed-call text-back**
- Filter:
  - `call.duration_ms` < `15000`;
  - AND `call.disconnection_reason` = `user_hangup`;
  - AND `call.from_number` starts with `+1`;
  - AND `call.from_number` ≠ your mobile.
- Module: **Twilio > Create a Message** to `{{call.from_number}}`.
- Body:
  - Demo line: `Donna.AI here, sorry we missed you on the demo line. Call back anytime at 825-462-1250, or book a quick call: [YOUR CAL.COM LINK]. Reply STOP to opt out.`
  - Client #1: `Hi, it's [BUSINESS]. Sorry we missed your call. How can we help? Reply here or call us back at [NUMBER]. Reply STOP to opt out.`

**Route C: confirmation or booking link (only with a yes)**
- Filter:
  - `call.call_analysis.custom_analysis_data.sms_ok` = `true`;
  - AND `call.duration_ms` ≥ `15000`.
- Module: **Twilio > Create a Message** to `{{ifempty(call.call_analysis.custom_analysis_data.callback_number; call.from_number)}}`.
- Body for the demo line, both agents in one field:
  `{{if(call.call_analysis.custom_analysis_data.booked; "DEMO - Northbeam Heating & Plumbing (a made-up company) by Donna.AI: you're booked for " + call.call_analysis.custom_analysis_data.appointment_time + ". This is the text your customers would get. "; "")}}Want Donna for your business? Book a free missed-call audit: [YOUR CAL.COM LINK]. Founding prices from $497/mo, 10 spots. Reply STOP to opt out.`
- Body for client #1:
  `[BUSINESS]: you're booked for {{call.call_analysis.custom_analysis_data.appointment_time}}. Questions? Call [NUMBER]. Reply STOP to opt out.`

**Optional Route D: log.** **Google Sheets > Add a row** to a sheet named "Donna calls" with these columns:
- date
- agent_id
- from_number
- duration
- booked
- urgent
- summary

It makes the weekly results text a 2-minute job.

Set the scenario to run **immediately** as data arrives, and switch it **ON**.

**Credits:** about 3 to 5 per call (webhook, router, one to three messages). The free plan's 1,000 credits a month cover about 200 calls.

## Scenario 2 (Capture clients, optional for the demo): "Cal.com booking > you"
1. In Cal.com: Settings > Developer > **Webhooks** > New. Paste a new Make custom-webhook URL. Trigger: Booking created.
2. In Make: Webhook > **Twilio > Create a Message** to your mobile (or the client owner's): `New booking: {{payload.title}} at {{payload.startTime}} - {{payload.attendees[1].name}}`.

Cal.com already emails the attendee a confirmation by itself.

## Rules these texts follow (CASL; not legal advice)
- **Who is texted:**
  - Route B only texts someone who **called** the line in the last few minutes. That is an inquiry, which gives implied consent to reply about it.
  - Route C only texts when the caller **said yes** on the call (the `sms_ok` field).
- **What every text carries:** the sender's name, a way to reach them, and "Reply STOP to opt out". Keep texts under 320 characters.
- **STOP:** Twilio's default opt-out handling on Canadian and US long codes blocks further texts to anyone who replies STOP. Also add them to your do-not-contact list (see `../PLAYBOOK_FIRST_CLIENT.md`).
- **No marketing texts** to callers who didn't say yes.

## Known limits
- Retell signs each webhook with `x-retell-signature`, but this simple Make scenario does not verify it. Keep the webhook URL private. In Route A, filter `call.agent_id` to your agents' IDs so stray posts are ignored.
- If a text doesn't arrive, check Make's scenario history first, then Twilio Console > Monitor > Messaging logs.
