# Donna.AI: first-client playbook

The product has been ready since April and has zero clients, because nobody sold it every day. This playbook is a daily sales routine, not a plan to read.
The rule: **no new building or tweaking until 50 businesses have been audited and called.** The demo line, the site and the offer sheet are good enough to sell today.

## 1. Who to sell to: several service verticals at once
Donna is for any service business that loses money when the phone isn't answered. Don't bet on one niche. Run the same audit across several verticals in parallel, and let your own audit numbers show where the misses are.

**Start with these 7, 7 to 8 businesses each, for the first 50:**
| Vertical | Why they miss calls | Demo company on the demo line |
|---|---|---|
| Home services (HVAC, plumbing, electrical, roofing) | Owner and crew on jobs; emergencies after hours | Northbeam Home Services |
| Med spa, salon, beauty | Staff busy with clients; evening and weekend bookings | Willow & Ash Studio |
| Dental, chiropractic, clinic | Front desk on the other line; lunch and after-hours new-patient calls | Larkfield Family Dental & Wellness |
| Law firms (family, real estate, wills, small business) | Lawyers in meetings or court; intake calls on evenings and weekends | Hollis & Grey Law |
| Auto repair and detailing | Techs under cars; no one at the counter | Ironclad Auto Care |
| Real estate agents | At showings; buyers call at night | Keystone Home Team |
| Cleaning, landscaping, renovation | Crews on site; quote requests go to voicemail | Fresh Slate Property Care |

**Why this mix** (from `docs/research/donna_competitors_2026.md`, researched 2026-11-23):
- **Owners across service businesses already pay for call answering.**
  - Podium claims 100,000+ businesses, Smith.ai 5,000+ and Ruby two decades in market (vendor claims on their pricing pages).
  - In home services, Avoca raised $125M+ at a $1B valuation (Fortune, 2026-04-27), and Yelp bought Hatch for about $300M (Localogy, 2026-01).
- **The big players leave the small owner-operator underserved.**
  - The vertical leaders are enterprise, quote-only or on annual contracts.
  - The cheap tools ($29 to $349 a month) make the owner build and maintain the agent.
  - Donna is the done-for-you middle, with a published price and month-to-month terms.
- **The demo line covers every vertical above,** so each prospect hears a call from their own world.

**Notes for regulated verticals** (dental, clinics, law):
- Donna only books and takes contact details. She gives no advice.
- Any rules their regulator sets for AI phone answering are a question for the client. Put it on the intake form.

**After 50 audits:** look at which verticals had the most after-hours voicemails and the warmest conversations, and put more of the next 50 there. Don't decide it before you have the data.

## 2. Build the list of 50 (method only; you build it, about 60 minutes)
Use public sources only. Do not buy lists and do not scrape personal data.

1. **Google Maps:** search per vertical, for example "plumber [city]", "med spa [city]", "dentist [suburb]", "family lawyer [city]", "auto repair [suburb]", "realtor [city]" and "cleaning company [city]". Open each listing.
2. **Keep** owner-operated shops:
   - one location;
   - a website or listing that shows a phone number;
   - listed hours that close (for example, 5 p.m. weekdays);
   - signs of a small team (owner or practitioner named on the site, one location, under about 200 reviews).
3. **Skip:**
   - franchises and big brands with a call centre;
   - anyone whose site says "24/7 live answering";
   - anyone whose site says they don't want sales calls or marketing email.
4. **Cross-check** Yelp, HomeStars (trades), the BBB, your Chamber of Commerce directory, professional directories (law society and dental association "find a" pages), and businesses you pass every day.
5. **For each business, record in `audit_log.csv`:**
   - name, phone, website, the published business email if any, and the owner's name if published;
   - the **URL and date where you saw the email**. Take a screenshot. This is your CASL proof (section 7).

## 3. The missed-call audit (evenings, about 40 minutes for 20 businesses)
The audit is the proof: you show the owner his own missed calls, not anyone's statistics.

**When:**
- Weekdays 6:00 to 9:00 p.m., after they close and inside the telemarketing calling hours (9 a.m. to 9:30 p.m. weekdays).
- Saturdays 10 a.m. to 6 p.m. for shops closed on weekends.

**How:**
1. Call from your own phone with caller ID on. Let it ring up to 6 times.
2. Log, right away:
   - date, time, rings to answer;
   - the outcome code;
   - what the greeting said (offers a callback? mentions emergencies? a full mailbox?).
3. **Voicemail or no answer:** hang up. Leave no message.
4. **A person answers:** be straight, never pose as a customer:
   > "Hi, this is Moe from Donna.AI. I'm not a customer, sorry. I'm checking how local businesses handle calls they can't pick up. Who's the best person to talk to about that, and when's a good time?"
   Log `ANS-H` or `ANS-S` and the callback time.
5. **Do a daytime call too, at lunch (12 to 1).** That's when owners and staff are with customers and the phone often goes unanswered.

**Outcome codes:**
| Code | Meaning |
|---|---|
| `ANS-H` | Owner or staff answered |
| `ANS-S` | Answering service |
| `VM` | Voicemail |
| `VM-FULL` | Mailbox full |
| `NA` | Rang out |
| `IVR` | Phone menu |
| `AI` | An AI already answers |

`VM`, `VM-FULL` and `NA` after hours are your best prospects.

## 4. The sequence (5 touches in 10 days, then stop)
| Day | Touch | What you say or send |
|---|---|---|
| 1 (lunch) | **Call** the `VM`/`NA` businesses back | The audit opener below |
| 1 | **Email**: only to a published business email, and only about their phone handling (it is relevant to the owner's role) | Audit result in 3 lines, demo line, offer sheet attached, your ID and an unsubscribe line (template below) |
| 3 or Saturday | **Walk in** if they have a shop or showroom | Printed offer sheet, plus their audit result written on the back |
| 5 | **DM** the business page (Facebook or Instagram), only if the page invites messages | Same 3 lines as the email, with ID and "reply STOP and I won't message again" |
| 10 | **Last call** | "I'll close your file. Setup is free until December 31 if you want to look again before then." |

Then stop. Anyone who says no or stop goes on your **do-not-contact** list the same day.

**Audit opener (call or walk-in):**
> "Hi, is this [owner]? Moe from Donna.AI. Quick one. I called your line Tuesday at 7:40 at night, like a new customer would. It rang out to voicemail. Not calling to shame you, most businesses are the same. When a new customer hits voicemail at night, what usually happens to them?"

Optional vertical line, after he answers:
- **Home services:** "...and in January that's a no-heat call."
- **Med spa or salon:** "...that's someone booking their next appointment from the couch."
- **Clinic:** "...that's a new patient."
- **Law:** "...that's an intake call for a matter worth thousands."
- **Auto:** "...that's a car going to the next shop."
- **Real estate:** "...that's a buyer calling about your listing."
- **Cleaning or landscaping:** "...that's a quote request."

Then listen. Ask what one average job is worth to him, and use his number, never a made-up one.

**Email template** (CASL: identification, mailing address, unsubscribe):
> **Subject:** Your after-hours line, Tuesday 7:40 p.m.
> Hi [owner], I called [business] on [date] at [time] as a test and it went to [voicemail / rang out]. Donna.AI answers those calls for you with an AI receptionist, texts back missed callers, and books the job into your calendar. Hear it yourself: call 825-462-1250, tell Donna what business you run, and play a customer. Plans from $197/month, month-to-month, setup free until December 31 (one-page offer attached).
> Moe [last name], Donna.AI, [mailing address], [phone]. Reply "unsubscribe" and I won't email you again.

## 5. The demo-call moment (the closer)
Do it in person or on the phone, the moment he says "huh" or "how does it work".
1. "Don't take my word for it. Call this number from your own phone right now: 825-462-1250. Tell her what you do, say yes to the demo, and be one of your own customers."
2. **Stay quiet.** Let him hear the AI disclosure, the urgent handling, the booking.
3. When the text lands on his phone: "That's what your 7:40 caller would have gotten, instead of your voicemail."
4. Then: "Want yours set up with your hours and prices? You'd test it on a private line before any customer hears it."

## 6. Close: the package comes out of the audit
The site and the offer sheet show **Essential from $197** and three **Tailored** packages. You quote the tailored ones on the call, from what the audit found.

| Package | What it fixes | Your guide price (internal, not published) |
|---|---|---|
| Essential | One leak, his pick | from $197 / month |
| Front Desk | Every call and lead answered | about $497 / month |
| Growth | Every lead chased, every slot filled | about $797 / month |
| AI Systems | Busywork gone, systems connected | from $1,297 / month |

All prices are in CAD, plus applicable taxes. Websites are optional: $497 / $997 one-time.

- **Recommend from his own numbers.** Use the leak he said costs him most (the audit brief shows his calculator numbers). If that's missed calls → Front Desk. If it's quotes and no-shows → Growth. Either way, Essential is the yes-today option.
- What you can say, all of it true:
  - setup is free until December 31, 2026 (a real deadline; on January 1 the offer ends);
  - month-to-month, no contract;
  - free Revenue Leak Audit, plus a test line before go-live.
- What you must not say:
  - "regular price", "normally", "was $…" or anything struck through;
  - any guarantee, refund, client count, result or review. You have none yet, and the honesty is part of the pitch;
  - scarcity you haven't set ("only 10 spots").
- **The ask:** "Want me to set it up? You'll have your test line within 48 hours."
- **Recommended terms** (owner decision): sign now, and charge month 1 only when he approves the test line and goes live. It removes the risk without a guarantee.
- **In Telegram, the moment he says yes:**
  1. `/donna won <lead #> <package> <monthly $>`: records the deal and drafts the welcome email with the setup questions. Tap Approve.
  2. `/invoices link donna <monthly $> <package>, <business>`: a payment link for you to send him (Jarvis never sends it). Needs FZ_STRIPE_INVOICING=1. Until then, use Helcim as before.
  3. When his answers come back: `/donna intake <lead #> | hours: ...; services: ...; faq: q = a; urgent: ...; booking: https://...`
  4. `/donna agent <business>`: preview his phone agent, then `create` it with the code shown.
  5. `/donna stuck` any time: every deal waiting on you, each with the command that moves it. The 6 pm digest lists them too.
- **Paperwork:** DocuSign the month-to-month service agreement. Counsel should review its wording once.

## 7. CASL and telemarketing rules (Canada; not legal advice)
- **Calls to businesses** are exempt from the National DNCL rules. You must still:
  - say who you are and who you're calling for at the start of the call;
  - keep an internal do-not-call list (add within 14 days; keep for 3 years and 14 days);
  - register with the National DNCL before making telemarketing calls, even exempt ones;
  - call only 9 a.m. to 9:30 p.m. weekdays and 10 a.m. to 6 p.m. weekends.
  The rules page states the registration and hours rules generally, so follow them.
- **Emails, DMs and texts are CEMs.** Each one needs:
  - consent;
  - your identification (name, business, mailing address, a contact);
  - a working unsubscribe, honoured within 10 business days.
- **Consent you can rely on:**
  - **Published business contact (implied consent):** the address is published on their site or listing, with no "no marketing" statement, and the message relates to their business role. Pitching phone handling to an owner does. Keep the screenshot, URL and date.
  - **Inquiry (implied consent):** they asked you about Donna (form, call, demo line). It lasts 6 months.
  - **Express:** they said yes, for example the box on the website form or "yes, text me" on the demo line.
- **Walk-ins and in-person conversations** are not CEMs. Hand over paper freely.
- **Never** text a prospect a pitch cold. Texts go only to people who called the demo line or said yes.

## 8. The daily routine (fits around a day job)
| When | Do | Minimum |
|---|---|---|
| Lunch, Mon to Fri, 12:00 to 1:00 | Call back yesterday's `VM`/`NA` businesses; do daytime audit calls | 10 dials |
| Evening, Mon to Fri, 6:00 to 7:00 p.m. | After-hours audit calls; send the day's emails | 20 audits, 5 emails |
| Saturday, 10 a.m. to 2 p.m. | Walk-ins with offer sheets; Saturday audits | 10 walk-ins |
| Every night, 5 minutes | Add a row to `scoreboard.csv` | |

**Scoreboard** (activity you control):
- audits done;
- conversations;
- demo calls heard;
- offers made;
- deals won (`/donna won`).

After 50 audits, look at the numbers. Change the opener, never the product.

## Sources
- `docs/research/donna_competitors_2026.md` (and its sources: Fortune 2026-04-27 on Avoca; Localogy 2026-01 on Hatch).
- CRTC, Key Unsolicited Telecommunications Rules, accessed 2026-11-24: https://crtc.gc.ca/eng/phone/telemarketing/tobligations/rules-regles.htm
- National DNCL, exemptions ("rules do not apply to telemarketing calls made to businesses"), accessed 2026-11-24: https://lnnte-dncl.gc.ca/en/Organization/Exemptions
- CRTC, CASL guidance on implied consent (conspicuous publication; 6-month inquiry; identification; unsubscribe within 10 business days), accessed 2026-11-24: https://crtc.gc.ca/eng/com500/guide.htm
