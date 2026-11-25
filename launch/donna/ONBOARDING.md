# Onboarding client #1 in 48 hours (no Jarvis needed)

Stack you already have:
- Tally (intake form)
- Helcim (recurring billing)
- DocuSign (agreement)
- Retell (agent and number)
- Cal.com (booking)
- Make.com plus Twilio (texts)

## Timeline
| When | You | Client |
|---|---|---|
| Hour 0 (he says yes) | Send the DocuSign agreement. Create the Helcim recurring plan at the founding price, starting on go-live day. Send the Tally intake link | Signs, fills the intake (about 15 min) |
| Hours 0 to 24 | Clone the agent, buy his local number, fill the prompt, connect Cal.com, copy the Make scenario | Creates a free Cal.com account and connects his calendar (or does it with you on a 10-min call) |
| Hours 24 to 36 | Text him the **test line** (the new Retell number). Fix whatever he flags | Calls it 3 or 4 times, approves the wording by text ("approved") |
| Hours 36 to 48 | Walk him through call forwarding (below), then run the go-live checklist with him on the phone | Dials the forwarding codes |
| Every Monday | Send the weekly results text | |

## 1. Intake form (Tally: build once, about 20 min; one question per line)
Tally > Create form > add these as fields. Mark the starred ones required.

**Business and contact**
1. \*Business name as callers should hear it
2. \*Legal business name and mailing address (for texts' sender ID)
3. \*Owner first name (Donna says it on calls)
4. \*Owner mobile for urgent texts and transfers
5. \*Email for call summaries
6. \*Main business phone number
7. \*Phone company (Bell, Rogers, Telus, Videotron, Freedom, Fido, Koodo, VoIP such as RingCentral or Ooma, other)
8. \*Is that number a cell phone, a landline or VoIP?

**Hours and urgency**
9. \*Office hours, by day
10. \*Do you take emergency calls after hours? What counts as an emergency for you?
11. \*Hours you want urgent calls transferred to you live (for example 7 a.m. to 9 p.m.)
12. What should Donna promise after hours (for example "a call back first thing in the morning")?
13. Emergency or after-hours fee, if you want it quoted

**Services and prices**
14. \*Services you offer (list)
15. Prices or ranges Donna may quote (leave blank and Donna never quotes prices)
16. \*Service area (cities or postal-code prefixes)
17. Brands you service or install
18. Questions Donna should ask on every call (for example: system age, error code, home or business)

**Booking**
19. \*Which jobs can Donna book straight into your calendar, and which need a callback?
20. \*Appointment length, and how much notice you need
21. Your calendar (Google or Outlook) and any job software (Jobber, Housecall Pro, ServiceTitan)

**Words**
22. \*Your 10 most common customer questions, with your answers
23. Things Donna must never say or promise
24. Payment methods you accept
25. Do you need French? (yes or no)

**Texts and consent**
26. \*Turn on missed-call text-back? (yes or no)
27. \*Who gets call summaries: text, email or both?
28. \*Checkbox: "I authorize Donna.AI to answer calls forwarded to it on behalf of my business, to tell callers they are speaking with an AI assistant and that calls are recorded, and to text callers who call my business or agree to a text."
29. Link to your privacy policy, if you have one

## 2. Clone the demo-line agent in Retell (about 15 min)
1. Agents > the demo-line agent > **⋯ > Duplicate** (this keeps the voice, model and post-call fields). Rename it `[Business] - Receptionist`.
2. Replace the prompt with `voice/prompts/client_template.txt`, filling every `[[...]]` from the intake. Leave `{{current_time}}`, `{{current_calendar}}` and `{{user_number}}` as they are: Retell fills those.
3. Welcome message: *"Thanks for calling [Business], this is Donna, the virtual assistant. This call is recorded. How can I help?"*
4. Functions:
   - keep `end_call`;
   - add **Transfer call** to the owner's mobile, named `transfer_to_owner`;
   - delete `transfer_to_founder` and any of your own Cal.com tools;
   - add **Cal.com** `check_availability` and `book_appointment` on the client's own event type (step 4).
5. Post-call fields: keep `caller_name`, `callback_number`, `booked`, `appointment_time`, `sms_ok` and `urgent`. Delete the demo and sales ones (`business_name`, `business_type`, `avg_job_value`, `demo_company`, `demo_booked`, `demo_appointment_time`, `lead_temperature`). Add `service_needed` (string).
6. Webhook URL: the client's Make scenario (step 5), event `call_analyzed`.
7. **Publish.**
8. **Buy his local number:** Phone Numbers > **Add number** > Buy new number > Twilio > Canada > his area code (for example 613 or 343). **$2.00/month.** Bind the inbound agent to the new agent.
   - Why a local number: forwarding to a number in the same area avoids long-distance charges on landlines. Bell, for example, bills long-distance on forwarded long-distance calls.

## 3. The test line
- The new Retell number is the test line. Text it to the client before any forwarding is set up.
- His approval by text ("approved") goes in his client folder, with the date and the prompt version.

## 4. Cal.com for the client
- **Account:** the client creates a free Cal.com account and connects his Google or Outlook calendar. Cal.com is free for one user.
- **Event type:** create one named "Service visit", with the length and notice from the intake.
- **Connect it in Retell:** Functions > + Add > Cal.com > **add a new connection**, and have the client sign in to his Cal.com in the popup. Doing this on a quick screen-share is easiest.
- **If Retell only allows one Cal.com connection per workspace:** create a separate Retell workspace for the client. Or start him on Answer, where Donna takes details and he books the job himself.

## 5. Make.com for the client
- Duplicate "Donna - after every call" (`voice/MAKE_SCENARIOS.md`) and rename it to the client.
- Replace the texts with the client versions shown there.
- Set Route A to the client's mobile or email.
- Paste the new webhook URL into his agent.

## 6. Call forwarding: conditional only (forward when busy or not answered)
**Never use "forward all calls":** his phone would stop ringing.
Put the client's new Retell number (10 digits) where it says NUMBER. Each carrier's codes are below; confirm them with the carrier if a code is refused.

**Rogers, Fido and chatr mobile** (Rogers' published codes):
- No answer: `*61*NUMBER#`, cancel with `##61#`.
- Busy: `*67*NUMBER#`, cancel with `##67#`.
- Unreachable or off: `*62*NUMBER#`, cancel with `##62#`.
- Rogers notes that conditional forwarding doesn't work while voicemail is active: ask Rogers to turn off voicemail.

**Bell, Virgin and Lucky mobile:**
- Phone > Settings > Call forwarding > choose busy, no answer and unreachable.
- The GSM codes above usually work too.
- Bell charges $0.25/min pay-per-use if call forwarding isn't in the plan: check the plan.

**Telus, Koodo and Public Mobile:**
- Use the same GSM codes (`*61*`, `*67*`, `*62*`).
- Users report Telus codes changing at times: if refused, call Telus business support.

**Freedom, Videotron and others (mobile):** use the same GSM codes, or Phone > Settings > Call forwarding.

**iPhone:** Settings > Phone > Call Forwarding forwards **all** calls, so don't use it. Use the dial codes instead.

**Bell business landline:**
- Busy: `*90` + NUMBER, cancel with `*91`.
- No answer: `*92` + NUMBER, cancel with `*93`. It forwards after 4 rings.
- Bell's page is dated 2014, so confirm with Bell if a code fails.

**Rogers home or business phone:**
- No answer: `*92` + NUMBER, stay on the line at least 5 seconds; cancel with `*93`.
- Busy: see Rogers' "forward calls when line is busy" page, or ask Rogers.

**VoIP (RingCentral, Ooma, Dialpad, OpenPhone, Google Voice and similar):**
- In the admin portal, set "when unanswered after N rings" and "when busy" to forward to NUMBER.
- Pick 4 or 5 rings.

## 7. Go-live checklist (do it with the client on the phone)
| # | Test | Pass when |
|---|---|---|
| 1 | Call his main number from a phone that isn't his, and let it ring out | Donna answers after the ring delay, with his business name and the AI and recording notice |
| 2 | Call while his line is busy | Donna answers |
| 3 | Ask hours, a price, the service area | Matches the intake exactly; no invented prices |
| 4 | One of his urgent situations from the intake (for home services: "I smell gas") | Safety instruction if any, then transfer or urgent text to him |
| 5 | Ask for a booking | A booking appears in his calendar; confirmation text if yes |
| 6 | Hang up after 3 s | Missed-call text-back arrives (if he turned it on) |
| 7 | After each call | He gets the summary by text or email |
| 8 | Ask "are you a person?" | "I'm an AI assistant for [Business]" |
| 9 | Reply STOP to a text | No further texts |
| 10 | Retell call history | Calls logged with summaries |

When all pass:
- start the Helcim plan;
- write the go-live date on his founding-spot record.

## 8. Weekly results text (every Monday, under 2 minutes)
Count from Retell > Call history, filtered to his agent and the last 7 days, or from the "Donna calls" Google Sheet. Report real counts only; never estimate.

> [Business] - Donna weekly, [Mon date] to [Sun date]: [N] calls answered ([N] after hours), [N] missed-call texts sent, [N] appointments booked, [N] urgent calls sent to you. Most asked: [topic], [topic]. Anything to change in what Donna says? Just reply. - Moe, Donna.AI

## Sources
- Rogers wireless call-forwarding codes, accessed 2026-11-24: https://www.rogers.com/customer/support/article/what-are-the-codes-for-call-forwarding-for-my-wireless-device
- Rogers home phone, forward when no answer, accessed 2026-11-24: https://www.rogers.com/support/home-phone/forward-calls-when-no-answer
- Bell small-business call forwarding (page dated 2014-10-27), accessed 2026-11-24: https://business.bell.ca/Support/small-business/phone/calling-features/how-to-use-call-forwarding
- Bell Mobility call forwarding ($0.25/min pay-per-use), accessed 2026-11-24: https://support.bell.ca/mobility/rate_plans_features/how_to_use_call_forwarding_on_my_mobile_phone
- Retell numbers, Canada $2/month: https://docs.retellai.com/deploy/purchase-number
- Cal.com pricing (free for individuals): https://cal.com/pricing
