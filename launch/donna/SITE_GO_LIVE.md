# Put the Donna.AI site live (free, about 15 minutes)

## Host: Netlify Free (researched 2026-11-24)

| | Netlify Free (chosen) | Cloudflare Pages Free |
|---|---|---|
| Contact form | **Built in (Netlify Forms). Free on credit plans since 2026-04-14** [1][2]. The site's form is already a Netlify form, with honeypot and CASL wording | None. It needs a third-party form service, plus changing the form and the Web Studio QA that checks it |
| Monthly allowance | **300 credits, hard limit.** When they run out, the site shows "Site not available" until next month. You can't buy more on Free [2] | 500 builds a month [3]. The limits page lists no bandwidth cap for static files |
| What uses credits | Production deploy 15; bandwidth 20 per GB; 2 per 10,000 requests; forms 0; previews 0 [2] | n/a |
| Our site | 1.2 MB per first visit, so 300 credits cover about 10 deploys plus about 7 GB, roughly 5,000 first visits a month | same site, no form |

**Choice: Netlify.** It is the only free option with a working form and no backend, and the form is already built and QA-checked for it.
**Watch the credits.** Don't redeploy more than you need: 15 credits each. If the site ever outgrows 300 credits, the fallback is Cloudflare Pages plus a form service.

## Option A (recommended): connect GitHub
Every edit to the site rebuilds by itself, and the address is right in the sitemap.
1. Go to **app.netlify.com/signup** > **Sign up with GitHub**. Use the GitHub account that owns `thedonnasystem/JARVIS`.
2. **Add new project** > **Import an existing project** > **GitHub** > authorize > pick `thedonnasystem/JARVIS`.
3. Settings:
   - **Branch to deploy:** `build/donna-launch`.
   - **Base directory:** `launch/donna`.
   - Leave the build command and publish directory empty: `launch/donna/netlify.toml` sets them.
4. **Deploy**. The first build takes about 3 minutes and installs from the template's lockfile. You get an address like `https://<name>.netlify.app`.
5. Project > **Forms** > **Enable form detection** [4]. Then **Deploys** > **Trigger deploy** > Deploy project, so Netlify sees the form. That costs 15 credits once.
6. Forms > **Form notifications** > Add notification > **Email** > your email > form `donna-contact`.
7. Test: open the site, send the form with your own details, check that the submission appears under Forms and that the email arrives.

Nothing is merged for this. Netlify builds the `build/donna-launch` branch directly. When the PR is merged later, switch the branch to `main` under Project configuration > Build & deploy.

## Option B: drag and drop (no GitHub)
1. Sign up at app.netlify.com (GitHub or email).
2. **Add new project** > **Deploy manually**. Drag the folder `/tmp/claude-0/-home-claude/35f9477b-fe0f-5ebf-aa85-6b2b4f07c2a7/scratchpad/donna_launch/dist`, or unzip `donna-site-dist.zip` next to it and drag that folder.
3. Do steps 5 to 7 above. For "trigger deploy", drag the folder in again.

Limits of B:
- Each change means a new build from the repo and another drag.
- The canonical link, sitemap and robots file point at a placeholder address (`example.invalid`). Visitors and the form are unaffected, but search engines need Option A, which fills in the real address.

## Two things to fill in before you send anyone to the site
1. **Sender identification (CASL).**
   - What to send: your legal business name and a mailing address and email for the site footer and contact form. Send it to Claude, or edit `legal` in `sites/donna/site.json`.
   - Why: CASL requires sender identification, and the footer shows `[OWNER: ...]` until you do.
2. **The Cal.com link.** One value: `links.booking` in `sites/donna/site.json`.
   - Now: it is `#contact`, so every "Book a demo" button scrolls to the working contact form.
   - In Cal.com: create a 20-minute "Donna.AI demo" event (Zoom), copy its link (`https://cal.com/<you>/donna-demo`), and send it to Claude or paste it into the file in GitHub (pencil icon > edit > Commit).
   - With Option A, Netlify rebuilds by itself.
   - Also set `booking_is_placeholder` to `false`.

The demo line `+1 (825) 462-1250` is already on the site: the hero and the contact section have a "Call the demo line" button.

## Custom domain (later, when you buy it)
1. Buy the domain from any registrar (donna.ai or a .ca: check availability and price yourself).
2. Netlify > Project > **Domain management** > **Add a domain** > follow the DNS records it shows (an A/ALIAS record and a CNAME for www). HTTPS is free and automatic.
3. With Option A, redeploy once, so the sitemap uses the new address.

## Sources
1. Netlify changelog, "Free unlimited seats on Pro, unlimited form submissions, & updated credit rates", 2026-04-14: https://www.netlify.com/changelog/2026-04-14-pricing-updates-april-2026/
2. Netlify docs, "How credits work", accessed 2026-11-24: https://docs.netlify.com/manage/accounts-and-billing/billing/billing-for-credit-based-plans/how-credits-work/
3. Cloudflare Pages limits, accessed 2026-11-24: https://developers.cloudflare.com/pages/platform/limits
4. Netlify Forms setup ("enable form detection"), accessed 2026-11-24: https://docs.netlify.com/manage/forms/setup
5. Netlify build software (Node 24 default, Python 3 available, NODE_VERSION / PYTHON_VERSION), accessed 2026-11-24: https://docs.netlify.com/build/configure-builds/available-software-at-build-time/

## Lead alerts on your phone (Telegram), about 5 minutes
Every website form submission and every analyzed Donna call (website or phone line) pings you on Telegram within seconds: who, what problem, what fits, booked or not.
1. Netlify → Site configuration → Environment variables. Add these yourself (Claude never handles them):
   - `TELEGRAM_BOT_TOKEN`: your bot's token (Jarvis's bot works).
   - `TELEGRAM_CHAT_ID`: your chat id with that bot.
   - `RETELL_API_KEY`: your Retell API key. It is only used to check that a webhook really came from Retell.
   - Optional: `DONNA_AGENT_IDS` (your two agent ids, comma-separated) and `DONNA_MAKE_WEBHOOK_URL` (to keep Make's text-backs running).
2. Deploys → Trigger deploy.
3. In Retell, on both agents, set Webhook URL to `https://<your-site>/.netlify/functions/retell-webhook` (event: call analyzed).
4. Test: submit the site form once and make one Talk to Donna call. Both should reach Telegram.
Form alerts need no Retell setup: Netlify runs `submission-created` on every verified form submission.
