# Donna.AI: first-client playbook

The product has been ready since April and has zero clients, because nobody sold it every day. This playbook is a daily sales routine, not a plan to read.
The rule: **no new building or tweaking until 50 businesses have been audited and called.** The demo line, the site and the offer sheet are good enough to sell today.

## 1. Niche: HVAC first, plumbing second
Why (from `docs/research/donna_competitors_2026.md`, researched 2026-11-23):
- **The money in AI receptionists is in home services.** The vertical leader, Avoca, sells AI front offices to HVAC, plumbing, roofing and electrical companies. It raised $125M+ at a $1B valuation and reports 800+ customers (Fortune, 2026-04-27). Yelp bought Hatch, a home-services lead converter, for about $300M (Localogy, 2026-01). Owners in this trade already pay for this.
- **Those leaders sell to big shops.** Avoca is quote-only and mid-market; Hatch is annual and per location. The 1-to-15-truck owner who answers his own phone from a crawl space is not their customer. He is ours: done-for-you, published price, month-to-month.
- **Now is the season.** A furnace that quits in a Canadian winter is an emergency call that goes to whoever picks up first. After-hours and weekend calls are exactly what Donna answers.
- **The demo already speaks HVAC.** Northbeam is a heating and plumbing company, so the demo call is the prospect's own world.

Plumbing is the same demo and the same pitch: start mixing it in after the first 25 HVAC audits. Leave dental, legal and medical for later, since they bring more privacy rules.

## 2. Build the list of 50 (method only; you build it, about 60 minutes)
Use public sources only. Do not buy lists and do not scrape personal data.

1. **Google Maps:** search "furnace repair [your city]", "HVAC [suburb]", "heating and cooling [city]". Open each listing.
2. **Keep** owner-operated shops:
   - one location;
   - a website or listing that shows a phone number;
   - listed hours that close (for example, 5 p.m. weekdays);
   - signs of a small team (owner named on the site, a few trucks, under about 200 reviews).
3. **Skip:**
   - franchises and big brands with a call centre;
   - anyone whose site says "24/7 live answering";
   - anyone whose site says they don't want sales calls or marketing email.
4. **Cross-check** HomeStars, Yelp, the BBB, your Chamber of Commerce directory and trucks you see on the road.
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
   > "Hi, this is Moe from Donna.AI. I'm not a customer, sorry. I'm checking how local heating companies handle after-hours calls. Who's the best person to talk to about that, and when's a good time?"
   Log `ANS-H` or `ANS-S` and the callback time.
5. **Do a daytime call too, at lunch (12 to 1).** That's when crews are on jobs and the phone often goes unanswered.

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
| 10 | **Last call** | "I'll close your file. Want me to keep a founding spot open for a week?" |

Then stop. Anyone who says no or stop goes on your **do-not-contact** list the same day.

**Audit opener (call or walk-in):**
> "Hi, is this [owner]? Moe from Donna.AI. Quick one. I called your line Tuesday at 7:40 at night, like a customer with no heat would. It rang out to voicemail. Not calling to shame you, most shops are the same. When a no-heat call hits voicemail at night in January, what usually happens to that customer?"

Then listen. Ask what one average job is worth to him, and use his number, never a made-up one.

**Email template** (CASL: identification, mailing address, unsubscribe):
> **Subject:** Your after-hours line, Tuesday 7:40 p.m.
> Hi [owner], I called [business] on [date] at [time] as a test and it went to [voicemail / rang out]. Donna.AI answers those calls for you with an AI receptionist, texts back missed callers, and books the job into your calendar. Hear it yourself: call 825-462-1250 and pretend your furnace just quit. Founding price from $497/month, setup included, month-to-month, 10 spots (one-page offer attached).
> Moe [last name], Donna.AI, [mailing address], [phone]. Reply "unsubscribe" and I won't email you again.

## 5. The demo-call moment (the closer)
Do it in person or on the phone, the moment he says "huh" or "how does it work".
1. "Don't take my word for it. Call this number from your own phone right now: 825-462-1250. Say yes when she offers the heating company, then pretend your furnace just died."
2. **Stay quiet.** Let him hear the AI disclosure, the urgent handling, the booking.
3. When the text lands on his phone: "That's what your 7:40 caller would have gotten, instead of your voicemail."
4. Then: "Want yours set up with your hours and prices? You'd test it on a private line before any customer hears it."

## 6. Close on founding pricing
- **Recommend Capture at $797/month.** It turns missed calls into booked appointments; Answer alone only takes messages.
  - Answer: $497 founding, $697 standard.
  - Capture: $797 founding, $1,097 standard.
  - Command: $1,297 founding, $1,797 standard.
  - All plus applicable taxes, in CAD.
- What you can say, all of it true:
  - setup included for founding clients;
  - the founding price is locked in for as long as he stays;
  - month-to-month, no contract;
  - only 10 founding spots;
  - free missed-call audit, plus a test line before go-live.
- What you must not say:
  - "regular price", "was $1,097" or anything struck through. The standard price is the price new clients pay **after** the 10 spots;
  - any guarantee, refund, client count, result or review. You have none yet, and the honesty is part of the pitch.
- **The ask:** "Want me to hold one of the 10 spots? I'll have your test line ready in 48 hours."
- **Recommended terms** (owner decision): sign the agreement now, and charge month 1 only when he approves the test line and goes live. It removes the risk without a guarantee.
- **Paperwork:**
  - DocuSign: send the month-to-month service agreement. Counsel should review its wording once.
  - Helcim: create a recurring payment plan at the founding price, starting at go-live.
  - Founding-spot record: write the spot number and the date sold in `scoreboard.csv` (the founding_spots columns). The Competition Act needs these records (see the research doc).

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
- founding spots sold.

After 50 audits, look at the numbers. Change the opener, never the product.

## Sources
- `docs/research/donna_competitors_2026.md` (and its sources: Fortune 2026-04-27 on Avoca; Localogy 2026-01 on Hatch).
- CRTC, Key Unsolicited Telecommunications Rules, accessed 2026-11-24: https://crtc.gc.ca/eng/phone/telemarketing/tobligations/rules-regles.htm
- National DNCL, exemptions ("rules do not apply to telemarketing calls made to businesses"), accessed 2026-11-24: https://lnnte-dncl.gc.ca/en/Organization/Exemptions
- CRTC, CASL guidance on implied consent (conspicuous publication; 6-month inquiry; identification; unsubscribe within 10 business days), accessed 2026-11-24: https://crtc.gc.ca/eng/com500/guide.htm
