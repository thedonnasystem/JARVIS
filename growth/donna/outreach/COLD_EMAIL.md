# Cold email sequences (CASL implied consent): DRAFTS, nothing is sent

## Before any email leaves your outbox [S9]
1. **Who you may email:**
   - Only addresses **conspicuously published** by the business: its website contact page, its directory listing, its own social profile.
   - No "we don't accept unsolicited messages" statement may be published with the address.
   - The email must relate to their business. Their phone line qualifies.
2. **Evidence:** save the URL, a dated screenshot and the date checked in the tracker (`consent_basis = implied_published`, `consent_evidence`). You carry the burden of proof [S9].
3. **Do not email:**
   - addresses from purchased or scraped lists;
   - personal addresses that are not published as the business contact;
   - anyone marked `unsubscribed_date` or `X`.
4. **Every email carries the footer below:** sender ID, mailing address, a contact method and an unsubscribe.
   - The unsubscribe must work for at least 60 days after sending [VERIFY: CASL regulations].
   - Process unsubscribes within 10 business days [S9]. Do it the same day.
5. **Deliverability:**
   - a separate sending domain [OWNER: buy], with SPF, DKIM and DMARC;
   - plain text;
   - no attachments;
   - at most 1 link from email 2 onward;
   - 10 a day in week 1, then 20 to 30;
   - hand-sent or a sequencer [OWNER: confirm tool].
6. **Personalise from the audit.** `[AUDIT_LINE]` is a true sentence from your tracker, for example:
   - "I called at 7:42 p.m. on Tuesday and it rang out";
   - "I called at 12:10 p.m. Wednesday and got voicemail".
   - **Never invent one.** If the audit was answered, use variant B or C, not A.

## One core version, per-vertical hooks
The 3 variants below are the core. Fill `[OPENER]`, `[DEMO_PROMPT]`, `[PAIN_LINE]` and `[COST_LINE]` from [VERTICAL_HOOKS.md](VERTICAL_HOOKS.md) for the prospect's vertical. Keep the source with any cited figure. Write `[VERTICAL]` in the tracker so reply rates can be compared per vertical.

## Footer (on every email; fill the placeholders once)
```
--
Moe [OWNER: last name] · Founder, Donna.AI
[OWNER: legal entity name] · [OWNER: mailing address]
[OWNER: phone] · [OWNER: website]
You're receiving this because your business email is published at [SOURCE_URL] and this message is about your business's phone line.
Not interested? Reply "unsubscribe" or use [UNSUBSCRIBE_LINK] and you won't hear from us again.
```

Timing: email 1 on day 0, email 2 on day 3, email 3 on day 7, email 4 on day 14. 4 touches, 3 to 4+ days apart, matches the benchmark advice [S3]. Stop at the first reply of any kind and move to a conversation.

---

## Variant A: audit-led (lines that missed a call)

**A1, day 0.** Subject: `Called [Business] at [time] [day]`
> Hi [First name],
>
> [AUDIT_LINE]. I wasn't a customer, I was checking, but a customer calling then would have got the same thing.
>
> I run Donna.AI. It answers those calls for service businesses, texts back anyone who hangs up, and books the job into your calendar. Callers are told it's an AI assistant.
>
> Hear it yourself in 60 seconds: [DEMO LINE]. [DEMO_PROMPT]
>
> Worth a 15-minute look at what your line did this week?
>
> Moe

**A2, day 3.** Subject: `Re: Called [Business] at [time] [day]`
> Hi [First name], quick follow-up. I also called at [second audit time], and [second result].
>
> I can show you both calls, and what Donna would have done, in 15 minutes. Free, no obligation. Does [day] at [time] or [day] at [time] work?
>
> Moe

**A3, day 7.** Subject: `What a missed call is worth to [Business]`
> Hi [First name],
>
> Rough math with example numbers: 30 calls a week, a quarter of them missed, 40% of those booking, at $400 each, is about $5,000 a month. Industry research puts unanswered calls around 27 to 28% (Invoca, 2024, home services; CallRail, 2025, all businesses). Your numbers will differ. You can run them here: [SITE]/calculator.
>
> Founding pricing for 10 clients: from $497 a month, month-to-month, setup included, and you test it on a private line before any customer hears it.
>
> Want me to run a full day-and-evening audit on your line?
>
> Moe

**A4, day 14.** Subject: `Closing the loop`
> Hi [First name], I won't keep emailing. If missed calls ever become a headache, the demo line stays open: [DEMO LINE]. And if you'd like the free audit later, just reply "audit".
>
> All the best with the season,
> Moe

---

## Variant B: cost-led (paid-lead businesses, or lines that answered the audit)

**B1, day 0.** Subject: `Quick question about [Business]'s calls`
> Hi [First name],
>
> [OPENER]
>
> I ask because [COST_LINE]
>
> I run Donna.AI: it answers every call, texts back missed callers within minutes and books the job. You can hear it on our demo line: [DEMO LINE].
>
> Open to a 15-minute look?
>
> Moe

**B2, day 3.** Subject: `Re: Quick question about [Business]'s calls`
> Hi [First name], one more thing: there's a free calculator that estimates what missed calls cost from 4 numbers (calls a week, share missed, job value, close rate): [SITE]/calculator. The math runs in your browser.
>
> If the number surprises you, reply and I'll check your real line for free.
>
> Moe

**B3, day 7.** Subject: `Month-to-month, setup included`
> Hi [First name],
>
> Most AI receptionist and messaging platforms either hide their prices or lock you into a year. Donna.AI's founding prices are on the page:
> - Answer $497
> - Capture $797 (answers, texts back, books)
> - Command $1,297 a month
>
> All CAD, month-to-month, setup included for 10 founding clients.
>
> 15 minutes this week?
>
> Moe

**B4, day 14.** Subject: `Should I close your file?`
> Hi [First name], no reply needed if the timing's wrong. I'll stop here. The demo line stays open if you're curious: [DEMO LINE].
>
> Moe

---

## Variant C: demo-line-led (curious or tech-friendly owners)

**C1, day 0.** Subject: `Try to stump her`
> Hi [First name],
>
> I built an AI receptionist for local businesses called Donna. Instead of a pitch, call her: [DEMO LINE]. [DEMO_PROMPT] Ask about prices, ask for a real person. See what she does.
>
> If you think your customers would hate it, tell me why. I'm collecting honest feedback from owners.
>
> Moe

**C2, day 3.** Subject: `Re: Try to stump her`
> Hi [First name], did you get a chance to call? If not, it takes 60 seconds: [DEMO LINE].
>
> The version I'd build for [Business] would know your services, prices, areas and calendar, and you'd test it on a private line before any customer hears it.
>
> Moe

**C3, day 7.** Subject: `What owners ask first`
> Hi [First name], the 3 questions owners ask me most:
> 1. **Will callers know it's AI?** Yes, Donna says so.
> 2. **Contract?** No, month-to-month.
> 3. **Setup cost?** Included for the 10 founding clients.
>
> Want a free missed-call audit of your line, day and evening?
>
> Moe

**C4, day 14.** Subject: `Last note`
> Hi [First name], last email from me. If you ever want to hear what a caller gets when you can't pick up, the demo line is [DEMO LINE], and the free audit is one reply away.
>
> Moe

---

## Reply handling
- **Positive** → book the 15-minute audit review the same day (`donna-launch` closing script).
- **"Not now"** → move to Nurture with a date; one check-in in 60 days.
- **"Unsubscribe" or any request to stop** → mark it in the tracker at once (`unsubscribed_date`, stage `X`). Never email again.
- **Questions** → answer from [OBJECTIONS.md](OBJECTIONS.md).
