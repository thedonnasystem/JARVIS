"""Generates growth/donna/presence/CONTENT_CALENDAR.md and content_calendar.csv from one list (so the two never drift)."""
import csv
import sys

OUT = sys.argv[1]
DEMO = "Demo call. Not a real customer."
H_CORE = "#hvac #plumbing #smallbusiness #contractor #aireceptionist"
H_PAIN = "#missedcalls #hvaclife #plumberlife #servicebusiness #tradesbusiness"
H_FOUNDER = "#founder #buildinpublic #smallbusiness #aireceptionist #trades"

# theme, template, hook id, duration, visual, script (VO / on-screen lines), on-screen text, caption, hashtags, source
S = [
 # ---- Day 1
 ("Demo-call clip", "ffm-broll-stitch", "stop-scroll", "20 s",
  "Recorded call to the demo line (you play the homeowner). Transcript appears word by word (karaoke captions). Gold waveform over black.",
  "CALLER: \"My furnace just quit and it's 9 at night.\" / DONNA: \"I'm sorry to hear that. I'm Donna, the AI assistant for this business. I can book a technician. Is first thing tomorrow OK?\" / CALLER: \"Yes.\" / DONNA: \"Booked for 8:30. You'll get a text confirmation now.\"",
  "Stop scrolling if your phone goes to voicemail after 5 p.m. | " + DEMO,
  "9 p.m. No heat. This is what your caller could hear instead of voicemail. Call our demo line and try it yourself (link in bio). " + DEMO,
  "#hvac #furnacerepair #aireceptionist #smallbusiness #contractor", ""),
 ("Missed-call pain", "donna-service-explainer", "question", "15 s",
  "Generated b-roll: service van parked at a job, phone buzzing on the dash, unanswered. Cut to a voicemail icon.",
  "VO: \"Ever wondered what happens to the call you miss while you're on a job? Most callers don't leave a voicemail. They call the next number.\" On screen: \"Under 3% of callers sent to voicemail leave a message (Invoca platform data).\"",
  "Ever wondered where your missed calls go? | Under 3% leave a voicemail (Invoca)",
  "You're under a furnace. The phone rings. By the time you call back, they've booked someone else. Source: Invoca, 2024 (platform data).",
  H_PAIN, "S1"),
 # ---- Day 2
 ("Founder story", "group-short-explainer", "pov", "25 s",
  "Faceless: hands on a phone, sales call log scrolling, city at night. Voiceover by you or the labelled Donna avatar.",
  "VO: \"POV: you sell on commission for a living, so you know a missed call is a missed sale. That's why I built Donna.AI. It answers every call for service businesses, texts back missed callers and books the job. I'm taking 10 founding clients.\"",
  "POV: you know what a missed call costs",
  "I sell on commission. Every missed call is money walking out the door. Donna.AI is for owners who are on the tools all day. 10 founding spots, month-to-month, setup included.",
  H_FOUNDER, ""),
 ("Vertical hook: home services (plumbing)", "group-short-explainer", "pov", "15 s",
  "Generated b-roll: water spreading on a basement floor, a phone ringing out. Then the Donna transcript.",
  "On screen: \"POV: it's 7 a.m., the water tank just burst, and the first plumber who answers gets the job.\" DONNA (demo audio): \"I can get a plumber out this morning. What's the address?\"",
  "POV: the first plumber who answers wins | " + DEMO,
  "Emergency calls don't wait for a callback. Donna answers, takes the details and texts you right away. " + DEMO,
  "#plumbing #plumber #plumberlife #emergencyplumber #aireceptionist", ""),
 # ---- Day 3
 ("Objection busting", "ffm-ugc-presenter", "question", "20 s",
  "Donna avatar (AI presenter, labelled 'AI-generated'), selfie framing, warm office.",
  "AVATAR: \"Ever wondered if your customers will hate talking to an AI? Here's how Donna handles it: she says she's an AI assistant right away, answers the question, and books the job, or texts you if they want a person.\"",
  "\"My customers won't talk to a robot.\" | AI-generated presenter",
  "Fair worry. Donna tells callers she's an AI assistant, keeps it short, and hands off to you when someone wants a person. You approve every word first. AI-generated presenter.",
  H_CORE, ""),
 ("Demo-call clip", "ffm-broll-stitch", "three-reasons", "20 s",
  "Demo-call audio + transcript, numbered overlay 1-2-3.",
  "On screen: \"3 reasons Donna is different from voicemail: 1. she answers the question (hours, prices, areas) 2. she books the time 3. she texts the caller a confirmation.\" Demo audio under it.",
  "3 reasons this beats voicemail | " + DEMO,
  "Voicemail takes a message. Donna takes the booking. Hear it on the demo line (link in bio). " + DEMO,
  H_CORE, ""),
 # ---- Day 4
 ("Before / after", "ffm-broll-stitch", "before-after", "15 s",
  "Split screen. Left 'BEFORE': ring, ring, voicemail beep, hang-up tone. Right 'AFTER': Donna answers on the first ring, booking text arrives.",
  "BEFORE: \"You've reached... please leave a message.\" *click* / AFTER: \"Hi, I'm Donna, the AI assistant for this business. How can I help?\"",
  "Before vs after: your phone at 8 p.m. | Illustration",
  "Same call, two endings. Illustration of a call, not a real customer.",
  H_PAIN, ""),
 ("Missed-call pain", "donna-service-explainer", "stop-scroll", "15 s",
  "Generated b-roll: phone screen showing '3 missed calls' while gloved hands work on a condenser.",
  "VO: \"Stop scrolling if you've ever called back a lead and heard 'we already booked someone'. 78% of customers buy from the first company that responds.\" On screen: source LeanData, cited by CallRail 2025.",
  "Stop scrolling if you call back too late | 78% buy from the first to respond (LeanData via CallRail)",
  "Speed wins the job. Donna answers on the first ring and texts back missed callers within minutes. Source: LeanData, cited by CallRail (2025).",
  H_PAIN, "S2"),
 # ---- Day 5
 ("Demo-call clip", "ffm-broll-stitch", "stop-scroll", "20 s",
  "Demo call: a price shopper. Transcript captions.",
  "CALLER: \"How much for a furnace tune-up?\" / DONNA: \"Our tune-up is [your price] and takes about an hour. I have Thursday at 10 or Friday at 2. Want one?\" (Use a placeholder business and price in the demo; no real business.)",
  "Price shoppers, booked | " + DEMO,
  "Donna quotes the prices you approve and offers a time while they're still on the line. " + DEMO,
  "#hvac #hvactech #aireceptionist #smallbusiness #servicebusiness", ""),
 ("Free audit explained", "group-short-explainer", "question", "20 s",
  "Screen recording style: a simple log '7:42 p.m. → voicemail', '12:15 p.m. → no answer' (fictional rows, labelled example).",
  "VO: \"Ever wondered what a new customer hears when they call you? Our free missed-call audit calls your line during the day and after hours, like a customer would, and shows you what happened. No cost.\"",
  "What does your line sound like at 7 p.m.? | Example log",
  "Free missed-call audit: we call your line during the day and after hours and show you exactly what a new customer gets. Book in bio. Example log shown.",
  H_CORE, ""),
 # ---- Day 6
 ("Trade hook: HVAC", "group-short-explainer", "countdown", "15 s",
  "Generated b-roll: thermostat showing a cold temperature, frost on a window, phone ringing.",
  "On screen: \"10 seconds to lose a no-heat call.\" Ring... ring... voicemail. Then: \"Or 10 seconds to book it.\" Donna demo audio: \"Booked for 8:30 tomorrow.\"",
  "10 seconds to lose (or book) a no-heat call | " + DEMO,
  "In January, every no-heat call is a job. Donna books it while you're on the last one. " + DEMO,
  "#hvac #furnace #heatingrepair #hvaclife #aireceptionist", ""),
 ("Objection busting", "ffm-ugc-presenter", "three-reasons", "25 s",
  "Donna avatar (labelled AI-generated).",
  "AVATAR: \"'I already have an answering service.' 3 things to compare: 1. Does it book into your calendar? 2. Does it text back the callers who hang up? 3. Do they follow up the leads? If yes to all three, keep it.\"",
  "\"I already have an answering service\" | AI-generated presenter",
  "Honest comparison: if your service books, texts back and follows up, keep it. If it only takes messages, call our demo line. AI-generated presenter.",
  H_CORE, ""),
 # ---- Day 7
 ("Missed-call pain", "ffm-broll-stitch", "question", "20 s",
  "Text-on-screen story over b-roll of a van at dusk.",
  "On screen: \"Ever wondered what missed calls cost? 30 calls a week × 27% missed × 40% close × $400 job ≈ $5,600 a month (example numbers).\" Then: \"Run yours: Missed-Call Cost Calculator, link in bio.\"",
  "What are missed calls costing you? | Example numbers",
  "Example numbers, not a promise: plug in your own on our Missed-Call Cost Calculator (link in bio). 27% is from Invoca's 2024 home-services research.",
  H_PAIN, "S1"),
 ("Founder story", "group-short-explainer", "question", "20 s",
  "Faceless: notebook with audit tallies, coffee, phone. Voiceover.",
  "VO: \"Ever wondered how many trade businesses miss calls after hours? This week I called [N] HVAC and plumbing lines after 7 p.m. [X] went to voicemail or rang out. No names, just the numbers.\" (Fill N and X from your tracker; aggregate only.)",
  "I called [N] trade lines after 7 p.m.",
  "Real numbers from my own audit calls this week: [X] of [N] went to voicemail or rang out. No business names. Want yours checked? Free audit, link in bio.",
  H_FOUNDER, "tracker"),
 # ---- Day 8
 ("Demo-call clip", "ffm-broll-stitch", "stop-scroll", "20 s",
  "Demo call: an older caller who speaks slowly. Captions large.",
  "CALLER: \"I'm not good with these machines.\" / DONNA: \"That's alright, take your time. I'm the AI assistant here, and I'll keep it simple. What's going on with the heat?\"",
  "Stop scrolling if your customers are older | " + DEMO,
  "Patient, clear and short. You approve the script and the hand-off to a person. " + DEMO,
  H_CORE, ""),
 ("Before / after", "ffm-broll-stitch", "before-after", "15 s",
  "Split screen: BEFORE a phone with '5 missed calls (Saturday)'; AFTER a calendar with 3 booked slots and 'Booked by Donna (demo)'.",
  "On screen only, no VO: BEFORE: Saturday, 5 missed calls. AFTER: Saturday, 5 calls answered, 3 bookings offered. Label: Illustration.",
  "Before vs after: your Saturday | Illustration",
  "Weekends are when competitors go to voicemail. Illustration, not a client result.",
  H_PAIN, ""),
 # ---- Day 9
 ("Trade hook: electrical", "group-short-explainer", "pov", "15 s",
  "Generated b-roll: an electrician on a ladder, phone ringing in a pocket.",
  "On screen: \"POV: you're up a ladder with both hands in a panel, and your phone rings.\" Then Donna demo audio: \"I can book an electrician for you. What do you need done?\"",
  "POV: both hands in a panel | " + DEMO,
  "Stay on the ladder. Donna takes the call, books the job, and texts you the summary. " + DEMO,
  "#electrician #electricalcontractor #trades #aireceptionist #smallbusiness", ""),
 ("Objection busting", "ffm-ugc-presenter", "question", "20 s",
  "Donna avatar (labelled AI-generated).",
  "AVATAR: \"'What if it books the wrong thing?' You set the rules: which jobs, which areas, which hours. Anything outside them gets a message and a text to you, not a booking. And you test it on a private line before any customer hears it.\"",
  "\"What if it books the wrong job?\" | AI-generated presenter",
  "Your rules, your calendar, your approval. Test line first. AI-generated presenter.",
  H_CORE, ""),
 # ---- Day 10
 ("Demo-call clip", "ffm-broll-stitch", "three-reasons", "20 s",
  "Demo call: after-hours AC failure in summer, labelled.",
  "On screen: \"3 things Donna did on this call: 1. answered at 10:14 p.m. 2. flagged it as urgent and texted the owner 3. booked the first slot.\" Demo audio under it.",
  "3 things that happened at 10:14 p.m. | " + DEMO,
  "Urgent calls get texted to you right away, using the rules you set. " + DEMO,
  "#hvac #acrepair #hvactech #aireceptionist #contractor", ""),
 ("Missed-call pain", "donna-service-explainer", "question", "15 s",
  "Generated b-roll: a laptop showing an ads dashboard, a phone ringing unanswered.",
  "VO: \"Ever wondered what a missed call costs when you paid for it? Contractors pay about $20 to $130+ per Local Services lead, and a missed lead can still be charged.\" On screen: sources Housecall Pro / Blue Grid Media 2026, Niagara Stands Out 2026.",
  "Paying for leads you don't answer?",
  "If you pay per lead, a missed call is money already spent. Sources: Housecall Pro (citing Blue Grid Media), 2026; Niagara Stands Out, 2026.",
  "#googleads #localservicesads #hvac #plumbing #missedcalls", "S7, S8"),
 # ---- Day 11
 ("Before / after", "ffm-broll-stitch", "before-after", "15 s",
  "Split screen: BEFORE a missed call notification; AFTER an auto text-back 'Hi, sorry we missed you. This is Donna, the AI assistant for [Business]. How can we help?'",
  "On screen: BEFORE: missed call, no follow-up. AFTER: text-back within minutes, the caller replies, a booking is offered. Label: Illustration.",
  "Before vs after: the missed-call text-back | Illustration",
  "Missed-call text-back (Capture package): the caller hears from you within minutes, not hours. Illustration.",
  H_PAIN, ""),
 ("Founder story", "group-short-explainer", "pov", "20 s",
  "Faceless: walking into a supply house at 7 a.m. (no faces or logos), coffee cups.",
  "VO: \"POV: 7 a.m. at the supply house counter, asking contractors one question: 'How many calls do you think you're missing a week when your guys are on jobs?' Here's what they said.\" (Summarise real answers, anonymised.)",
  "POV: one question at the supply house",
  "Real answers from real counter conversations, no names. Want to know your number? Free audit, link in bio.",
  H_FOUNDER, "your notes"),
 # ---- Day 12
 ("Objection busting", "ffm-ugc-presenter", "three-reasons", "20 s",
  "Donna avatar (labelled AI-generated), price card graphic.",
  "AVATAR: \"'Too expensive.' 3 numbers: Capture is $797 a month at the founding price. Your average job is $[X]. So it covers its cost if it wins back [797 ÷ X] jobs a month. Run your numbers on the calculator.\"",
  "\"Too expensive?\" Do the math | AI-generated presenter",
  "Founding pricing: Capture $797/month (CAD), month-to-month, setup included. Whether it's worth it depends on your numbers. Use the calculator (link in bio). AI-generated presenter.",
  H_CORE, ""),
 ("Trade hook: roofing / exterior", "group-short-explainer", "pov", "15 s",
  "Generated b-roll: storm clouds, rain on shingles, phone lighting up.",
  "On screen: \"POV: the storm just passed and 20 homeowners are calling roofers at once.\" Then: \"Who answers first?\" Donna demo audio.",
  "POV: storm day, everyone's calling | " + DEMO,
  "Rush days are when calls get missed. Donna answers all of them at once. " + DEMO,
  "#roofing #roofer #contractor #trades #aireceptionist", ""),
 # ---- Day 13
 ("Demo-call clip", "ffm-broll-stitch", "stop-scroll", "20 s",
  "Demo call: a caller who wants a person.",
  "CALLER: \"Can I just talk to someone?\" / DONNA: \"Of course. I'm texting the owner your details now so they can call you back. What's the best number?\"",
  "When they want a person | " + DEMO,
  "Donna never traps a caller. She hands off with a summary, so you call back already knowing the job. " + DEMO,
  H_CORE, ""),
 ("Objection busting", "ffm-ugc-presenter", "question", "20 s",
  "Donna avatar (labelled AI-generated).",
  "AVATAR: \"'Is there a contract?' No. Month-to-month. Setup is included for founding clients. Stay because it books you jobs.\"",
  "\"Is there a contract?\" | AI-generated presenter",
  "Month-to-month, no contracts. Founding clients get setup included and a price locked while they stay. AI-generated presenter.",
  H_CORE, ""),
 # ---- Day 14
 ("Before / after", "ffm-broll-stitch", "before-after", "20 s",
  "Split: BEFORE a 'call log' of a fictional shop's week (labelled example); AFTER the same week with Donna's summaries.",
  "On screen: BEFORE: notes on scraps of paper, missed calls. AFTER: every call summarised, leads in one list. Label: Example, fictional business.",
  "Before vs after: your week of calls | Example, fictional business",
  "Every call answered and summarised; every lead in one list (Capture). Example with a fictional business.",
  H_PAIN, ""),
 ("Missed-call pain + CTA", "donna-service-explainer", "stop-scroll", "15 s",
  "Generated b-roll: ringing phone on a workbench; end card with the gold Donna.AI wordmark.",
  "VO: \"Stop scrolling if you've missed a call today. Industry research says about 1 in 4 calls to home services businesses goes unanswered. Find out yours: free missed-call audit, 10 founding spots.\" On screen: 27% (Invoca, 2024).",
  "Stop scrolling if you missed a call today | 27% go unanswered (Invoca)",
  "About 1 in 4 calls to home services businesses go unanswered (Invoca, 2024). Find out your real number with a free missed-call audit. 10 founding spots.",
  H_PAIN, "S1"),
]

# ---- multi-vertical overrides (owner correction: Donna is not HVAC-only; one core message, per-vertical hooks)
DEMO_T = DEMO + " Vertical demo recorded on a test line set up for that business type."
S[8] = ("Demo-call clip: auto", "ffm-broll-stitch", "stop-scroll", "20 s",
  "Recorded call to a test line set up as a fictional auto shop. Transcript captions.",
  "CALLER: \"How much for front brakes, and can you look at it tomorrow?\" / DONNA: \"Front pads start at [your price], and we confirm after inspection. I have 8:00 or 1:30 tomorrow. Which works?\"",
  "Price-check calls, booked | " + DEMO,
  "Price shoppers call 3 shops. Donna quotes the prices you approve and offers a time while they're still on the line. " + DEMO_T,
  "#autorepair #mechanic #autoshop #aireceptionist #smallbusiness", "")
S[10] = ("Vertical hook: med spa", "group-short-explainer", "pov", "15 s",
  "Generated b-roll: a treatment room, gloved hands, a phone lighting up on the counter (no faces).",
  "On screen: \"POV: you're mid-treatment and the phone won't stop.\" Then Donna demo audio: \"I can book your consultation. Is Thursday or Friday better?\"",
  "POV: mid-treatment, phone ringing | " + DEMO,
  "Consult calls don't wait. Donna answers, books the consult and texts you a summary. No medical advice, ever. " + DEMO_T,
  "#medspa #aesthetics #spaowner #aireceptionist #smallbusiness", "")
S[14] = ("Demo-call clip: salon", "ffm-broll-stitch", "stop-scroll", "20 s",
  "Recorded call to a test line set up as a fictional salon. Captions large.",
  "CALLER: \"Can I get a cut and colour Saturday? I'm not good with apps.\" / DONNA: \"No problem, I can book it right here. I have 10:00 or 2:30 on Saturday.\"",
  "For the clients who won't use the booking app | " + DEMO,
  "Not everyone books online. Donna books the callers, patiently, into your calendar. " + DEMO_T,
  "#salonowner #hairsalon #beautybusiness #aireceptionist #smallbusiness", "")
S[16] = ("Vertical hook: dental and clinics", "group-short-explainer", "question", "15 s",
  "Generated b-roll: an empty reception desk at lunch, a phone ringing (no faces, no patient data).",
  "VO: \"Ever wondered where new-patient calls go when the front desk is at lunch?\" Then Donna demo audio: \"I can book your first visit. Morning or afternoon next week?\"",
  "Lunch hour, front desk away | " + DEMO,
  "Donna books new-patient visits when the desk is busy, collects only booking details, and hands everything else to your team. " + DEMO_T,
  "#dentaloffice #chiropractor #clinicowner #aireceptionist #smallbusiness", "")
S[18] = ("Demo-call clip: real estate", "ffm-broll-stitch", "three-reasons", "20 s",
  "Recorded call to a test line set up for a fictional agent. Numbered overlay 1-2-3.",
  "On screen: \"3 things Donna did on this sign call: 1. answered while the agent was in a showing 2. asked the buyer's timeline and pre-approval 3. booked a showing request for Saturday.\" Demo audio under it.",
  "3 things that happened during a showing | " + DEMO,
  "Sign calls go cold fast. Donna answers, qualifies and books the showing request for you to confirm. " + DEMO_T,
  "#realestateagent #realtor #realestate #aireceptionist #leadgeneration", "")
S[20] = ("Before / after: cleaning and landscaping", "ffm-broll-stitch", "before-after", "15 s",
  "Split screen: BEFORE a missed call from a quote request; AFTER an auto text-back 'Hi, sorry we missed you. This is Donna, the AI assistant for [Business]. What can we quote for you?'",
  "On screen: BEFORE: missed quote call, no follow-up. AFTER: text-back within minutes, the caller replies, a quote visit is offered. Label: Illustration.",
  "Before vs after: the spring-rush quote call | Illustration",
  "Missed-call text-back (Capture package): the quote request hears from you within minutes. Illustration, fictional business.",
  "#landscaping #lawncare #cleaningbusiness #smallbusiness #missedcalls", "")
S[23] = ("Vertical hook: law firm intake", "group-short-explainer", "question", "15 s",
  "Generated b-roll: an office after hours, a desk phone ringing, city lights (no faces).",
  "VO: \"Ever wondered what happens to the 6 p.m. call from a new client?\" Then Donna demo audio: \"I'm the firm's AI assistant. I can't give legal advice, but I can book a consultation. What's the matter about, in a sentence?\"",
  "The 6 p.m. call from a new client | " + DEMO,
  "Intake only: Donna books consultations and never gives legal advice. You decide what it asks. " + DEMO_T,
  "#lawfirm #lawyer #legalintake #aireceptionist #smallbusiness", "")

assert len(S) == 28, len(S)

rows = []
for i, s in enumerate(S):
    day, slot = i // 2 + 1, ("AM" if i % 2 == 0 else "PM")
    theme, tpl, hook, dur, visual, script, ost, cap, tags, src = s
    rows.append({"id": f"D{i+1}", "day": day, "slot": slot, "theme": theme, "creative_studio_template": tpl, "hook": hook, "duration": dur,
                 "visual": visual, "script": script, "on_screen": ost, "caption": cap, "hashtags": tags, "source": src})

with open(f"{OUT}/content_calendar.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

md = ["# 14-day content calendar: 28 short-video scripts",
      "",
      "**Formats:** IG Reels, TikTok, YouTube Shorts and FB Reels. Post the same file on all four.",
      "",
      "**Schedule:** 2 a day (AM 7:00 to 8:00, PM 19:00 to 21:00 [ASSUMPTION: test your own times]). Schedule with Metricool and edit in CapCut. Spreadsheet version: [content_calendar.csv](content_calendar.csv).",
      "",
      "## How these map to Creative Studio",
      "Templates are from `creative_studio/presets/library.json` on `build/creative-studio-m8c`.",
      "",
      "| Template | Used for | Settings from the library |",
      "|---|---|---|",
      "| `ffm-broll-stitch` (edit) | Demo-call clips, before/after | Hook first, b-roll, karaoke captions, loudnorm −14, max 20 s, crossfade 0.25. Hooks: stop-scroll, three-reasons, before-after |",
      "| `donna-service-explainer` (video) | Missed-call pain b-roll | 5 s shots, dolly-right, soft light, serene mood, 'modern small business front desk, phone ringing, {subject}'. Negative prompt bans real-person likeness and text. Hooks: question, stop-scroll |",
      "| `group-short-explainer` (video) | Trade hooks, founder story | 5 s push-in shots, karaoke captions. Hooks: question, pov |",
      "| `ffm-ugc-presenter` (ugc) | Objection busting with the Donna avatar | AI presenter **labelled as AI**, selfie framing, karaoke captions. Hooks: question, three-reasons, stop-scroll |",
      "| `ffm-ad-still` (image) | Optional cover frames | Warm prime, golden hour |",
      "",
      "Hook formulas used, from the library: `POV: {subject}`, `Stop scrolling if you {pain}`, `Ever wondered {question}?`, `3 reasons {subject} is different`, `Before vs after {subject}`, `{n} seconds to {outcome}`.",
      "",
      "**One core message, per-vertical hooks.** The calendar rotates through all 7 verticals ([CHANNELS.md §2](../CHANNELS.md); hooks in [../outreach/VERTICAL_HOOKS.md](../outreach/VERTICAL_HOOKS.md)). Home services gets the most slots because it ranks first on fit. Vertical demo clips need a test line set up for that business type (`donna-launch`). Until one exists, record on the demo line with the generic prompt.",
      "",
      "## Rules (every script)",
      "",
      "- **Demo-call audio** is you (or a helper who agreed) calling the demo line as a pretend customer. Label it on screen and in the caption: **\"Demo call. Not a real customer.\"** Use a placeholder business name and prices in the demo agent, never a real business.",
      "- **Avatar videos** are labelled **\"AI-generated presenter\"** on screen.",
      "- **Before/after** clips are labelled **\"Illustration\"** or **\"Example, fictional business\"**. They are not client results.",
      "- **Industry figures** only with a source on screen or in the caption ([SOURCES.md](../SOURCES.md)).",
      "- **Your own audit numbers** are aggregated only, with no business names, numbers or greetings.",
      "- **Never:**",
      "  - testimonials;",
      "  - \"clients say\";",
      "  - invented results;",
      "  - client counts;",
      "  - \"guaranteed\";",
      "  - real businesses' audio.",
      "- **CTA:** demo line, calculator, or free audit (link in bio).",
      "",
      "## Calendar",
      ""]
md.append("| ID | Day | Slot | Theme | Template / hook | Length |")
md.append("|---|---|---|---|---|---|")
for r in rows:
    md.append(f"| {r['id']} | {r['day']} | {r['slot']} | {r['theme']} | `{r['creative_studio_template']}` / `{r['hook']}` | {r['duration']} |")
md += ["", "## Scripts", ""]
for r in rows:
    md += [f"### {r['id']}: Day {r['day']} {r['slot']}, {r['theme']}",
           "",
           f"- **Creative Studio:** `{r['creative_studio_template']}`, hook `{r['hook']}`, {r['duration']}",
           f"- **Visual:** {r['visual']}",
           f"- **Script:** {r['script']}",
           f"- **On-screen text:** {r['on_screen']}",
           f"- **Caption:** {r['caption']}",
           f"- **Hashtags:** {r['hashtags']}"]
    if r["source"]:
        md.append(f"- **Source:** {r['source']} ({'see SOURCES.md' if r['source'].startswith('S') else 'fill from your own data; aggregate only'})")
    md.append("")
with open(f"{OUT}/CONTENT_CALENDAR.md", "w") as f:
    f.write("\n".join(md))
print("ok", len(rows))
