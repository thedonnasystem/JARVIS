# Jarvis core v2: owner guide

Plain English, for you, sir. Everything below is built and tested on a dev branch and is **switched off**. Nothing runs, spends or calls anyone until you turn it on.
Engineering detail: `JARVIS_CORE_V2_DESIGN.md`. Free model terms: `FREE_PROVIDER_TERMS.md`. Self-hosted brain: `ops/selfhost/README.md`. Switches: `ops/OWNER_JARVIS_CORE.sql`.

## 1. What Jarvis can do (once on)
- **Run 24/7 as the only always-on agent.** A durable job queue per division (Donna, Wolf Squad, FF Marketing; the rest dormant). Other agents sleep until Jarvis wakes them for a real queued job, with the reason logged; they keep going while they have work, then sleep again (queue empty, no progress, or 10 jobs). Retries with backoff, failed jobs parked, every step logged.
- **Respect your hours** (Toronto): 22:00-07:00 emergencies only; weekdays 08:00-17:00 urgent only; otherwise anything. Held messages are delivered when allowed.
- **07:00 daily report** on Telegram: revenue, costs, net, runway, spend per division, missions, approvals waiting, agent wakes and sleeps, changelog, and what the next dollar would buy.
- **Chairman briefing** (`/briefing`): who he is, who you are (from your memory file), what he can do, his limits, what still needs you.
- **Memory seed**: send your private markdown file to the bot with the caption `/seedmemory`. It is read in memory, never saved as a file or put in the repo. The bot can only **stage** it; you apply it with one owner-only line (`ops/OWNER_JARVIS_CORE.sql`), because the database, not the bot, decides who is the owner. Duplicates are skipped; items over 500 are reported, not silently dropped; one audit row (counts only).
- **Other commands** (no AI, $0): `/core` (status), `/report` (daily report now).
- Always calls you "sir".

## 2. What it costs: $0 by default
- **Brain = free tiers in rotation** (Groq, OpenRouter free models, GitHub Models, NVIDIA, Cerebras trial) plus a **free self-hosted** small Hermes model on an always-free CPU VM. When one free tier is full Jarvis moves to the next; when all are full he queues the work and tells you. **He never switches to a paid model on his own.**
- **Client and personal data never goes to a free provider, enforced in code**: every prompt names its sources (memory kinds, lead / client tables, workspace data, the job type). A prompt goes to a free provider only if **every** source is on a short code-only list of public sources **and** the scan finds nothing personal: phones, emails, ids, cards, names next to client words ("Client Jane Roe", "name: ..."), postal codes, street addresses, policy / account numbers, medical words, income and other money amounts, dates of birth. **No job type is public by name** (whoever queues a job picks its type), so queued prompts and anything from client, lead, workspace, insurance or real-estate tables or your private profile go only to your own self-hosted model or plain code, or the call is refused. Unknown = private. The scan is a pattern list: it can miss a cleverly worded fact, which is why the source rule comes first.
- Every call still goes through the spend gateway, so the kill switch, the daily cap (unchanged), the agent cap and **mission budgets** (now also for Jarvis's own calls) all apply. Free calls are recorded at 0 cents. The large model needs your single-use approval every time. Paid vendors exist only in code: a setting cannot declare a paid vendor free or change its price.
- **Self-funding rule** (his standing top objective): paid models or a GPU can only be paid from your chosen share (0-50%) of revenue **you** confirm as Jarvis's, after bank reconciliation. Confirming and the share are yours only; caps and approvals still apply.

## 3. What is locked (the never-edit list, `ops/PROTECTED_PATHS.json`)
Money controls; the kill switch and dry-run/live mode; Jarvis's own permissions; consent/opt-out, client data protection, backups and the insurance guard; the tests and CI that judge his work (and this list itself); audit history; destructive data changes.
Also locked: **every top-level Python module** of the bot, present or new (the core engine: any change to it needs you), the web app (`webapp/`, it runs in your signed-in app), Jarvis's skills (`jarvis_skills/`), every test file, every deploy or start config (Dockerfile, railway / railpack / nixpacks / render / fly / compose / heroku files, Procfile variants, package.json, .env files, start scripts, requirements files), and anything Python loads by itself (packages, `sitecustomize`, `.pth`, `.gitattributes`). Writes to an agent's status (the paused agents are a dormancy control), REST writes whose table name is built at run time, split-up, commented-out or disguised database statements and dynamic SQL count as locked too.
Any change touching these fails CI unless **you** approve that exact commit. The judge (the checker and the list) always comes from the **base branch**, never from the pull request, so a PR cannot weaken its own judge; a push to a protected branch with unapproved locked changes fails too.
**Be clear on what the checker is:** a **tripwire**, not a proof. Locking files by path is solid; the line patterns (monkey-patching, built table names, comments) catch the known tricks, but no pattern list can catch every way code can change other code in the same program. **The control is the independent review plus your approval of the exact commit**; the checker makes sure locked areas cannot change without that approval.
**Self-edit mode** (`ops/SELF_EDIT_MODE`, locked): **allowlist** (your decision, the default): Jarvis may auto-ship only text: `docs/` and `prompts/`. `webapp/hq/` (runs in your signed-in app) and `jarvis_skills/` were taken out of his zone on Nov 17 2026 and need you, until skills run fully isolated (they now run in a separate process with an empty environment, but that process can still use the standard library, so it is not a jail). The zone is checked on every Jarvis pull request, including the `jarvis/integration` release PR. `denylist` would let him ship anything not locked.

## 4. How approvals work
- **Code changes to locked areas**: on the pull request in GitHub, your account taps **Review -> Approve** (this re-runs the `protected-paths` check by itself), or adds the label `owner-ok-<the full 40-character latest commit id>` (49 characters; GitHub's limit is 50). A new commit cancels the approval. If the check still shows red after your approval, press **Re-run** on the `protected-paths` check. The approval counts only from `owner_login` in `ops/PROTECTED_PATHS.json`, and only if that account is **not** the agents' account and **not** the PR's author.
- **Today this fails closed on purpose**: the agents and you share `thedonnasystem`, so any approval could have come from an agent. No locked change can pass until you have your own account (your decision, Nov 16 2026). Steps, once:
  1. Create a new personal GitHub account for yourself (sign out, github.com -> Sign up). Turn on two-factor login (Settings -> Password and authentication).
  2. With the new account, create a free organization (profile menu -> Your organizations -> New organization -> Free). You are its owner.
  3. Invite `thedonnasystem` to the organization (organization -> People -> Invite member) and, in organization Settings -> Member privileges, allow members to create repositories for the move only.
  4. Signed in as `thedonnasystem`: repository JARVIS -> Settings -> General -> Danger Zone -> Transfer ownership -> type the organization name -> confirm.
  5. Back on your new account: organization Settings -> Member privileges -> Base permissions **No permission**, repository creation **off**. Repository JARVIS -> Settings -> Collaborators and teams -> `thedonnasystem` role **Write** (not Maintain, not Admin). The agents can then push branches and open PRs but cannot change rules or merge past them.
  6. **Railway and Render lose access when the repo moves** (their GitHub apps were installed on the old personal account), so deploys stop until you reconnect them. Railway: project -> bot service -> Settings -> Source -> Disconnect, then Connect Repo -> Configure GitHub App -> install it on the new organization, only repository JARVIS -> pick branch `claude/telegram-claude-bot-59nusk`. Render: service -> Settings -> Build & Deploy -> Repository -> connect GitHub -> install the Render app on the new organization (only JARVIS) -> select JARVIS, branch `overnight-build`. Check the next deploy of each. (Menu names may differ slightly in their current dashboards.) GitHub keeps the old URL redirecting, so the agents' clones keep working; their tools should switch to the new `org/JARVIS` path.
  7. **Before any ruleset exists**: one PR sets your new login as `owner_login` in `ops/PROTECTED_PATHS.json` and in `.github/CODEOWNERS`. Bootstrap: the base still names the shared account, so this one PR cannot pass the gate; you merge it yourself as organization owner (the only time; afterwards the gate works and nobody bypasses it). Doing this before step 8 is what makes it possible: step 8's empty bypass list would block it.
  8. Repository -> Settings -> Rules -> Rulesets -> New branch ruleset: targets `overnight-build`, `main`, `claude/telegram-claude-bot-59nusk`, `jarvis/integration`; enforcement Active; **bypass list empty**; tick Restrict deletions, Block force pushes, Require a pull request (Require review from Code Owners, **Dismiss stale pull request approvals when new commits are pushed**, **Require approval of the most recent reviewable push**), Require status checks: `unit`, `migrations`, `secret-scan`, `protected-paths` (pick the `protected-paths` that comes from GitHub Actions). Save. Only the `protected-paths` check is relied on for locked areas: the copy inside `unit` runs after the PR's own tests and is only an early warning.
- **Switches** (core, worker, self-edit, WhatsApp, calls, self-funding, large model tier, memory seed): only you, signed in as the app owner. In the Supabase SQL editor that means setting your app user id first (`ops/OWNER_JARVIS_CORE.sql` shows how); a plain database session is refused, like the bot.
- **Why not a Telegram button for code approvals?** CI cannot read the production database without another secret, and anything the bot can write, the bot could forge. A GitHub action by your own account, which no agent can use, is the simplest marker Jarvis cannot fake.

## 5. Channels and privacy (honest)
- **Telegram** (main channel): bot chats are **not** end-to-end encrypted.
- **WhatsApp Business Cloud API** (built, off): encrypted in transit, but processed on Meta's servers, so **not** end-to-end like a normal WhatsApp chat.
- **Emergency phone call** (built, off): only for kill switch tripped, security incident, runaway spend, production down, or a time-critical deal/legal deadline (`ops/CRITICAL_EVENTS.json`, which you approve and which is locked). Short scripted message: "check Telegram". At most 2 calls a day, no repeats within 24 h, every decision logged. A phone call is **not** end-to-end encrypted.
- **Live two-way voice**: design only (`hq_channels.VoiceConversation`), no vendor chosen.
- None of these channels carries secrets or client personal data.

## 6. Self-edit (built, off)
Jarvis writes code on a branch with his own GitHub machine account (not yours, not the agents'), opens a PR, CI runs, a different model reviews the **whole** diff of one exact commit (too big = refused, never cut), the locked-list check and the safe-zone check pass on every file, then it auto-merges **only into `jarvis/integration`**, and only that reviewed commit: if anything was pushed after the review, nothing merges.
**Important:** merging into `overnight-build` redeploys the Render app, and Railway deploys the bot from `claude/telegram-claude-bot-59nusk`. So Jarvis never merges there. Proposed activation: you promote `jarvis/integration` to `overnight-build` with one approved PR (label), then fast-forward the Railway branch as in `DEPLOY_RUNBOOK.md`; after each deploy Jarvis health-checks and, if it fails, opens the revert for your one-tap approval (fully automatic revert only if you later allow it). Every merge, refusal and rollback appears in the 07:00 report.
Self-automation (off): when a task type repeats past your thresholds (default 20 runs or $2 of AI), Jarvis drafts plain code for it through this pipeline. Never for locked areas. Since skills are locked now, a skill draft is refused by the pipeline and needs your approval like any locked change.
Jarvis's base branch must be a plain `jarvis/<name>` branch (no `..`, no trailing `/`); while the system is in dry-run mode, queued jobs that would send, call, post, pay, deploy, merge or open a revert are held, not run.

## 7. Turning things on (in this order)
1. Approve and release the migration `20261123_jarvis_core_v1` (release path; it is additive).
2. Set at least one free provider key in Railway Variables (section 8), then `JARVIS_CORE=1`.
3. Run steps 1-3 of `ops/OWNER_JARVIS_CORE.sql`. Send `/core`, then `/briefing`.
4. Optional: self-hosted brain, WhatsApp, calls, self-edit, self-funding, each separately.

## 8. Your checklist
- [ ] **Your own GitHub account and the repository move** (section 4, steps 1-8, in that order: the bootstrap PR, step 7, before the ruleset, step 8). Until then every locked change fails closed. (never paste keys in chat; put them only in Railway Variables)
- [ ] **Branch protection** (GitHub, repo Settings -> Rules -> Rulesets -> New branch ruleset): target `overnight-build` and `claude/telegram-claude-bot-59nusk`; enforcement Active; no bypass list; tick "Restrict deletions", "Block force pushes", "Require a pull request before merging" (required approvals 0, so your own PRs still work; tick "Require review from Code Owners"), "Dismiss stale pull request approvals when new commits are pushed", "Require approval of the most recent reviewable push", "Require status checks to pass" and add `unit`, `migrations`, `secret-scan`, `protected-paths`; Save. Do it after the bootstrap PR (section 4 step 7). (Section 4 step 8 is the full version.)
- [ ] **This PR's locked changes** (it adds the check itself, edits CI, migrations, backup classification and judge tests): it fails closed until your own account exists; then approve it from that account (or merge it as the bootstrap PR, section 4 step 7).
- [ ] **Free model keys** (each takes a few clicks, $0): Groq console -> API keys -> `GROQ_API_KEY` (turn on Zero Data Retention in Data Controls); OpenRouter -> Keys -> `OPENROUTER_API_KEY` (Settings -> Privacy: keep model training OFF); optional `GITHUB_MODELS_TOKEN`, `NVIDIA_API_KEY`, `CEREBRAS_API_KEY` (trial only).
- [ ] **Free self-hosted brain** (optional but needed for client data): an always-free ARM VM, then `ops/selfhost/README.md`; set `JARVIS_SELFHOST_BASE_URL`, `JARVIS_SELFHOST_API_KEY`.
- [ ] **Jarvis's GitHub machine account** (for self-edit): create a separate free GitHub account, add it to the repo, create a fine-grained token for this repo only (Contents read/write, Pull requests read/write, Checks read) -> `JARVIS_GITHUB_TOKEN`; create branch `jarvis/integration`.
- [ ] **WhatsApp** (optional): Meta Business account -> WhatsApp -> API setup; add a phone number, verify the business, create a permanent System User token -> `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_OWNER_NUMBER` (your number), approve a message template for messages outside the 24-hour window (`WHATSAPP_TEMPLATE`); `JARVIS_WHATSAPP=1`. Cost: Meta charges per business-initiated template message (check current Canadian rates).
- [ ] **Emergency calls** (optional): Twilio account, buy one Canadian number (roughly US$1-2/month) -> `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `OWNER_PHONE_NUMBER`; `JARVIS_EMERGENCY_CALL=1`. Calls cost about US$0.01-0.03 per minute in North America (check current pricing); 2 calls a day max means cents per month. Approve `ops/CRITICAL_EVENTS.json` (status line).
- [ ] **Paid GPU** (only later, from self-funding): create the GPU account yourself, approve the monthly cost, paste the endpoint key into Railway (`JARVIS_GPU_*`).

## 9. Nous "Hermes Agent" vs our Jarvis core
Hermes Agent (Nous Research, MIT licence) is an agent framework with memory across chats (including Telegram), self-improving skills and scheduled tasks. **We do not replace Jarvis with it**: it has none of our spend gateway, kill switch, consent and suppression rules, HQ database, missions or never-edit enforcement, and swapping it in would bypass all of them. Ideas worth borrowing (not built): its skill files as a format for the self-automation drafts; its per-chat memory summaries as an input to `/seedmemory`; its scheduled-task syntax for owner-defined jobs (still through our queue and gateway). We do use the Hermes **models** as the default open-weight brain (confirm the exact model id, licence and tool-call format at activation, `ops/selfhost/models.json`).

## 10. Limits (stated plainly)
The new Jarvis tables (queue, logs, wakes, approvals) are NOT in the encrypted off-site backup yet (the export needs a reviewed redaction rule per column first; follow-up); your database provider's own backups still hold them. Nothing here is proven in production: tests use a scratch database and mocked providers. Free-tier limits and terms change without notice. Rate tracking is in memory (a restart forgets it; providers' own limits still apply). The protected-path check is a tripwire plus an approval gate: the ruleset must require it, and a cleverly disguised change can still slip past pattern checks in the few places that are not locked by path (for example a file under `integrations/`), so the independent review and your approval are the control. The skill process is isolated from our code and keys but is not a jail. The personal-data scan is a pattern list. Telegram, GitHub rules and labels were tested only with mocks, not on GitHub or Telegram themselves.

## 11. Jarvis's hands (accounts + posting), built and OFF
What it is: one action pipeline (post, upload, send, update, deploy) over a connector registry. Every action: Jarvis drafts, you approve (one tap, `/approve <id>`, or a standing approval you set), the database re-checks kill switch, dry-run, connector on, account connected and the daily limit, the personal-data scan runs, then the executor gate and spend gateway, then the platform's **official API**. Every step is in `audit_log`.

Accounts are **assisted only, for every service**. Jarvis proposes (platform, handle, name, bio, image); you approve; Jarvis sends you the official sign-up page with everything filled in for you to copy; **you sign up yourself and keep the password** (Jarvis never generates, stores or sees it); you send `/accounts done <id>`; then `/connect <platform> <division>` hands Jarvis posting through the official OAuth / API connection. Only the token goes to the Bitwarden vault; the database keeps the vault id.

Connectors shipped: Facebook Page and Instagram professional (Meta Graph API), TikTok (Content Posting API), YouTube (Data API uploads), X (API v2, text), LinkedIn (Posts API, text), Email (drafts into the existing outbox: consent, suppression and `/drafts` still decide every send), Netlify (static deploy). New services are code adapters (`hq_hands_adapters.py`, template class inside): locked path, your approval.

Telegram (owner only, "sir"): `/accounts` (list, `new`, `done`), `/connect`, `/queue`, `/approve <id> [no]`, `/post <id>` (run an approved one now).

### Once per platform (what you do, ~10-20 min each)
- **Meta (Facebook Page + Instagram):** create the Page yourself; switch Instagram to a professional account and link it to the Page; create an app at developers.facebook.com (type Business), add Facebook Login, set the redirect URL to the value of `HANDS_OAUTH_REDIRECT`; request `pages_manage_posts`, `instagram_content_publish` (App Review needed before it works for anyone but you as app admin). Railway Variables: `META_APP_ID`, `META_APP_SECRET`. Cost: $0. Meta caps API-published Instagram posts per 24 h.
- **TikTok:** developers.tiktok.com app, add Content Posting API + Login Kit, redirect URL as above, verify the domain your videos are served from (pull-from-URL). Variables: `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`. Cost: $0. Until TikTok audits the app, posts are private (SELF_ONLY).
- **YouTube:** Google Cloud project, enable YouTube Data API v3, OAuth client of type "TVs and Limited Input devices" (no redirect page needed; `/connect youtube <division>` shows a code). Reuses `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` if that client is that type, else set new ones. Cost: $0 within the default 10,000 units/day quota (an upload is about 1,600 units, so about 6 uploads/day). Uploads stay private until Google audits the project.
- **X:** developer.x.com app with OAuth 2.0 (confidential client), redirect URL as above. Variables: `X_CLIENT_ID`, `X_CLIENT_SECRET`. Cost: X's free tier allows only a small number of posts per month and X changes its API pricing often; check the developer portal before turning it on (it may be paid).
- **LinkedIn:** linkedin.com/developers app, add "Sign In with LinkedIn using OpenID Connect" and "Share on LinkedIn", redirect URL as above. Variables: `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET`. Cost: $0. Posts as your member profile (company pages need LinkedIn's Community Management approval).
- **Netlify:** sign up yourself, create the site, create a personal access token, then `/connect netlify <division> <site id> <token>` (the message is deleted). Cost: $0 on the free tier.
- **Email:** nothing new; it uses the existing outbox and mail provider.
- **All OAuth platforms:** one Railway Variable `HANDS_OAUTH_REDIRECT` = an https page you control (e.g. the HQ app URL). After you approve on the platform, the browser lands there; send `/connect <platform> <division> <that full link>`.

### Turning a hand on (after the migration is released)
In the Supabase SQL editor as the app owner (same pattern as `ops/OWNER_JARVIS_CORE.sql`: set your auth uid in the same transaction):
```
select public.hands_owner_enable(true, 10, 1);                       -- the action executor: 10 runs/day, 1 cent per run against the spend gateway
select public.hands_owner_set_connector('meta-instagram', true, 5);  -- each platform you want, with its daily limit
select public.hands_owner_set_standing('division', 'donna', true);   -- OPTIONAL: posts/uploads for a division skip the tap (default off)
```
Also needed: the Jarvis core worker on (section 7), the system out of dry-run (`auto_in_caps`; in dry-run every approved action is logged as "would post" and nothing is sent), and the Bitwarden variables (`BW_ACCESS_TOKEN`, `BW_ORGANIZATION_ID`) the bot already uses. Turn off: `select public.hands_owner_enable(false);` or the kill switch.

### Limits (plain)
- The adapters are written against each platform's documented API and tested with mocked responses only; the first real post on each platform is the real test.
- X and LinkedIn are text-only in v1; Facebook takes text or one image; Instagram one image or one video; TikTok and YouTube one video by URL.
- Approvals are recorded by the bot's owner-only Telegram handlers; the database checks the `owner:` marker but cannot itself prove the tap came from your phone (same model as account and payment approvals today).
- No HQ app panel yet (it would need a new app function on the locked lockdown list).

## 12. FF Marketing engine (client brief -> draft campaign pack), built, needs release

Turns one client brief into a full campaign pack, stored as drafts only: positioning and offer angle, 3 audience angles (in words), 3 ad sets, 9 ad variants (headline, text, CTA), 9 image/video prompts with an AI-disclosure note, landing page copy plus a simple HTML page, the lead form (name, email, phone only; consent wording comes from the client), 5 follow-up texts/emails (templates), a 14-day organic calendar, KPI targets and the weekly report template (`ffm_weekly_report`). Vertical playbooks: generic, mortgage, insurance, home_services, real_estate (`prompts/ffm/`), each with a "confirm with the client" list (items to confirm, not legal advice).

### Run it (3 steps, Telegram)
1. `/ffm new` with the brief in the same message (send `/ffm new` alone to get the template): name, vertical, offer, area, customer, goal, budget (as stated, or unset). Creates a DRAFT workspace (no budget) and its onboarding checklist.
2. `/ffm pack <slug>`: generates and stores the pack, sends you `<slug>-pack.json` and `<slug>-landing.html`. Run it again to regenerate (new version; the old one is marked superseded).
3. `/ffm show <slug>`: summary, items to confirm with the client, your actions, and the two files. `/ffm list` lists workspaces. Optional: `/ffm queue <slug> <account-id>` turns the 14 posts into hands drafts for a connected account (each waits for your approval; refused while a standing approval covers that account).

### Cost
3 calls to the cheap model (`claude-haiku-5-5`) through the same spend gateway as your chat, inside the existing $3.30/day cap: about 3 cents per pack (each call reserves the 1-cent minimum). Hard per-pack ceiling 10 cents (`FFM_PACK_CEILING_CENTS`, max 30), at most 5 calls. If the cap, the kill switch or the ceiling would be hit, it stops, stores nothing and tells you.

### What stays manual (yours or the client's)
Budget, activation and creative approval (owner-only, unchanged); client sign-off on every ad, page and message; exact consent wording and licence/registration text; publishing the page, ads and posts; any message to a lead (outbox, consent and outreach gates unchanged). Nothing is launched, published, sent or spent by the engine.

### Limits (plain)
- Privacy screen: every generated text is screened; anything flagged is blanked and listed in `screened_out` for you to rewrite. The database classifier treats every vertical except mortgage as insurance context (20261122 design) and there only accepts the owner-approved marketing vocabulary (~830 words) plus approved terms. The engine gives the model that vocabulary, but trade words like "furnace" are refused: for home services, real estate and generic clients, expect blanked texts until you approve their words (`ws_add_vocab_word` / `ws_add_approved_term`, owner-only; no Telegram command for it yet). Mortgage packs pass the strict screen normally.
- Opt-out lines, consent placeholder, compliance items and the HTML page are added from code when shown, not stored (they would not pass that vocabulary screen).
- Packs are excluded from off-site backups (all `ffm_*` tables are), so a restore loses them; regenerate.
- The model output is checked for shape and screened, not for truth or compliance: the client and you review everything.

## 13. FF Marketing execution (Jarvis runs the launch), built, needs release

One tap per client launch (at most 30 days); then Jarvis runs paid ads, posts, works the leads and reports, alone, inside the numbers you approved.

### Run it
1. Once per client: `/ffm sender <slug> <from email> | <sender name> | <brand> | <mailing address>` (the CLIENT's own CASL identity; its emails never carry Donna's).
2. `/ffm launch <slug> <daily $> <total $> [days, max 30] [start YYYY-MM-DD]` (after `/ffm pack`; total cap at least $100, not above the workspace monthly budget). You get ONE message: platforms, daily budget (an average: Meta may spend up to ~75% more on a single day), total cap (the hard stop), dates, and `/ffm plan <id>`, which lists every ad, post and email. Tap Approve.
3. Jarvis then (every 5 minutes, plain code): Meta campaign (spend cap = your total), ad sets and ads created PAUSED, then switched on; landing page; organic posts; new leads followed up by email; daily optimizing; Monday report to you plus a client draft.
   Client emails: automatic sending is OFF per client by default, so the emails waiting for a launch come to you as ONE message per launch (Approve sends them, Reject withdraws them). `/ffm autosend <slug> on` lets that client's emails go without a tap (first email within about 5 minutes when live); `off` turns it back.
4. `/ffm status <slug>`, `/ffm stop <slug>` (pauses on Meta first, tells you if Meta did not confirm), `/ffm budget <slug> <daily $> <total $>` (a new tap; the new cap is set on Meta and ad sets are cut before anything resumes), `/ffm lead <id> replied|booked|stop|lost`.
At the cap every ad is paused and you are told once. Kill switch: nothing runs; Jarvis only pauses live ads. When you switch the kill switch off, a launch that the kill switch paused is switched back on (only inside its approved budget and dates, re-checked); a launch stopped or capped is not.

### Unsubscribes (CASL)
Every email has an unsubscribe link (mailto to the client's address) and asks people to reply "unsubscribe". Those replies land in the CLIENT's inbox: they are not read automatically. Record each one with `/ffm lead <id> stop` (it withdraws consent and suppresses the address). CASL requires an unsubscribe to take effect within 10 business days, so you (or the client) must record them within that time.

### Go live (in this order). A launch approved in dry-run mode stays DRY RUN to its end: launch again after going live.
1. Merge and release this PR (migration `20261126_ffm_run_v1`, rollback `ops/rollback_ffm_run.sql`).
2. Connect for division `ffm`: `/ffm connectads` (Meta ad account), `/connect meta-facebook ffm` (the Page), `/connect netlify ffm <yoursite>.netlify.app <Netlify token>`, optionally LinkedIn / X.
3. Switch those connectors on (`hands_owner_set_connector`) and the hand (`hands_owner_enable`), as in section 11. Set `META_APP_SECRET` (appsecret proof) and `RESEND_API_KEY`, and verify the client's sending domain in Resend.
4. Per client: `/ffm sender`, onboarding inputs `consent_wording` and `booking_link`, a registered consent wording version, workspace budget and activation (unchanged owner steps).
5. Kill switch off; mode from `dry_run` to `auto_in_caps` (emails send only when the policy engine allows `send_email`).
6. Outreach gate open (suppression verified) and consent captures sealed by the form endpoint: until then leads are stored as `needs_consent` and never emailed.
7. `/ffm launch ...` and tap Approve.

### Limits (plain)
- Emails: with automatic sending OFF (default) each batch waits for your tap; with it ON they go under the launch approval. Either way each is re-checked at send time (consent, opt-out, suppression, outreach gate, kill switch, mode, policy caps, the sender's gate mark) and carries a per-email idempotency key (no duplicate on a provider retry).
- Approval security: the approval checks the message and a single-use nonce, which blocks replayed, stale and wrong-message taps. It does not stop someone holding the bot's service key (same trust as hands approvals today); anon / app users are fully blocked. What such a key could approve is bounded by your workspace monthly budget, 30 days per approval and your workspace activation.
- The sealing form endpoint (capture signing key) is not built: until it is, no lead has verified consent, so no email goes out.
- SMS is a stub. Instagram, TikTok and YouTube posts need media and are skipped. Leads are polled (no webhook). Targeting: the brief's city (25 km) or Canada.
- The launch tap approves the hand actions for the exact approved posts and page (`owner:launch:<id>`) and the emails: review that design before release.
- `hq_mail.live()` checks for a mode named `live`, which does not exist (modes are dry_run / approve_first / auto_in_caps / exceptions_only), so the legacy outbox sender never sends today. Not changed here; FF Marketing does not use that path.
