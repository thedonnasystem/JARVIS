# Connect session checklist (FENDEZY GROUP, Phase 1 M7)

One sitting, top to bottom. Every step is a click, a sign-in, an "Authorize" button, or a copy from a provider page into a Railway variable box.
**You never type or paste a secret into a chat** (Telegram, Claude or anywhere else). Values go only into Railway Variables or the provider's own OAuth screen.
Connecting something activates nothing: every office stays DORMANT until you activate it (section 4), and every paid or outgoing action still waits on your approval.

How to check progress at any time: ask Jarvis/Claude to run `python3 scripts/check_integrations.py` (or `--office donna`) on the Railway service. It shows only which variable **names** are set, never a value.

Jarvis hands name FF Marketing's division `ffm` (Jarvis core's active divisions are donna, wolf-squad, ffm); the M1 office slug is `ff-marketing`. Use `ffm` in `/connect`.
Set the Railway variable `HANDS_OAUTH_REDIRECT` to the bot's OAuth return page first if you have one: then every "Allow" returns by itself. Without it, the bot asks you to paste the address the browser lands on; that address carries a one-time code that expires in 15 minutes and is not a password. Never use `/connect <connector> <division> <site> <key>` (it puts an API key in a chat); skip API-key connectors such as Netlify in this session.

Where a step says "Railway variable": Railway -> FENDEZY project -> the bot service -> **Variables** -> **New Variable** -> name exactly as written -> paste the value from the provider tab -> **Add**. Railway redeploys by itself; one redeploy after the whole session is fine (the variables are saved before that).

## 1. Inventory

Tier = risk tier of what the connection lets Jarvis do (Green: just do it; Yellow: within limits; Red: asks you every time; Prohibited: never). "Code" = the repo already uses it.

| Key | What it is for | Offices | Env var / secret name | Code | Tier |
|---|---|---|---|---|---|
| telegram | Your command channel, approvals, alerts | all | `TELEGRAM_BOT_TOKEN`, `JARVIS_OWNER_ID` | yes (bot.py) | Red |
| supabase | HQ database, every ledger and control | all | `HQ_SUPABASE_URL`, `HQ_SUPABASE_SERVICE_KEY` | yes (hq.py) | Red |
| scoped_tokens | Per-office database identities (M1) | all | `FZ_SCOPED_TOKENS` (+ `FZ_GATEWAY_APIKEY`) | yes (hq.py) | Red |
| anthropic | Jarvis's LLM; the $3.30/day AI cap is enforced in the database | all | `ANTHROPIC_API_KEY` (models: `CLAUDE_MODEL`, `HQ_MODEL_*`) | yes (hq_llm.py) | Yellow |
| railway | Hosting; deploy metadata set by Railway itself | all | `RAILWAY_*` (automatic) | yes | Red (deploys) |
| vault | Bitwarden Secrets Manager: stores every OAuth/API token Jarvis gets | all | `BW_ACCESS_TOKEN`, `BW_ORGANIZATION_ID`, `BW_PROJECT_ID` | yes (bot.py, hq_hands.py) | Red |
| backup | Encrypted off-site backup (Backblaze B2 via the gateway) | all | `BACKUP_PUT_URL`, `BACKUP_AUTH`, `BACKUP_KEY` (+ `BACKUP_READER_JWT`, `BACKUP_GATEWAY_APIKEY`) | yes (hq_backup.py) | Red |
| resend | Sending email (CASL consent, suppression, outreach gate enforced) | donna, wolf-squad, monopoly, ff-marketing | `RESEND_API_KEY`, `MAIL_FROM` (+ `MAIL_REPLY_TO`) | yes (hq_mail.py) | Red |
| google | Google OAuth app: Calendar (`/connectcalendar`), YouTube uploads | donna, wolf-squad, monopoly, ff-marketing, b2b-records, pimp-ai | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | yes (bot.py, hq_hands_adapters.py) | Yellow |
| meta | Facebook Pages + Instagram posting (official Graph API) | ff-marketing, donna, the-trap, pimp-ai, b2b-records | `META_APP_ID`, `META_APP_SECRET` (+ `HANDS_OAUTH_REDIRECT`) | yes (hq_hands_adapters.py) | Red |
| tiktok | TikTok video posting | ff-marketing, the-trap, pimp-ai, b2b-records | `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET` | yes | Red |
| linkedin | LinkedIn posting | ff-marketing, wolf-squad | `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` | yes | Red |
| x | X / Twitter posting | ff-marketing, pimp-ai | `X_CLIENT_ID` (+ `X_CLIENT_SECRET`) | yes | Red |
| automation | n8n / Make webhooks | donna | `N8N_BASE_URL`, `N8N_API_KEY`, `MAKE_WEBHOOK_URL` | yes (bot.py) | Yellow |
| wholesale_db | Separate Supabase project for real estate | monopoly | `WHOLESALE_SUPABASE_URL`, `WHOLESALE_SUPABASE_SERVICE_KEY` | yes (bot.py) | Red |
| github | Jarvis dev pull requests (never merges or deploys alone) | fruition-factory | `GITHUB_TOKEN`, `GITHUB_REPO` (+ `GITHUB_BASE_BRANCH`, `JARVIS_GITHUB_TOKEN`) | yes (hq_dev.py) | Red |
| llm_free | Free / backup LLM providers (no-training providers only) | fruition-factory | `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `CEREBRAS_API_KEY`, `NVIDIA_API_KEY`, `GITHUB_MODELS_TOKEN` (all optional) | yes (hq_llm.py) | Yellow |
| openai_voice | Voice-note transcription | all | `OPENAI_API_KEY` (+ `TRANSCRIBE_MODEL`) | yes (hq_voice.py) | Yellow |
| whatsapp | Owner alerts on WhatsApp (off until `JARVIS_WHATSAPP=1`) | all | `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_OWNER_NUMBER` | yes (hq_channels.py) | Yellow |
| emergency_call | Twilio call to you for emergencies only (off until `JARVIS_EMERGENCY_CALL=1`) | all | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `OWNER_PHONE_NUMBER` | yes (hq_channels.py) | Yellow |
| rbc | Bank: **manual reconciliation only**. You download the statement CSV and send it with `/bank`; no RBC credential ever exists in the system | all | none | yes (hq_bank.py) | Red (money) |
| stripe | Customer payments | donna, the-trap, b2b-records, pimp-ai | none yet | **no** | Red |
| meta_ads | Paid Meta campaigns (spend) | ff-marketing | none yet | **no** (posting only) | Red |
| elevenlabs | AI voice | b2b-records, pimp-ai | none yet | **no** (placeholder) | Yellow |
| gmail | Reading the inbox | donna, wolf-squad | none yet | **no** (sending is Resend) | Yellow |
| google_drive | Files | fruition-factory | none yet | **no** | Yellow |
| airtable | Bases | donna | none yet | **no** | Yellow |

Not built = nothing to connect today. Each one needs its own reviewed build (and, for Stripe and Meta Ads, your money approval) before a credential is useful. Do not create keys for them yet.

## 2. Before you start (2 min)

1. Open three tabs: Railway (FENDEZY project), Bitwarden Secrets Manager, Telegram with the bot.
2. In Telegram send `/hq`. A reply means Telegram, Supabase and the bot are live. Nothing else to do for those three.

## 3. The session, in order

Core (all offices need these):
1. **Anthropic**: console.anthropic.com -> API Keys -> Create Key -> Copy -> Railway variable `ANTHROPIC_API_KEY`. Skip if `/hq` already answers with AI replies.
2. **Vault**: Bitwarden -> Secrets Manager -> Machine accounts -> New -> give it access to the Jarvis project -> Access tokens -> Create -> Copy -> Railway variables `BW_ACCESS_TOKEN`, then copy the organization id and project id from the page URL into `BW_ORGANIZATION_ID`, `BW_PROJECT_ID`.
3. **Backup**: follow `BACKUP_ACTIVATION_RUNBOOK.md` (its own click list; already reviewed). Skip if `/backup` shows OK.

Donna (activation 1):
4. **Resend**: resend.com -> Domains -> Add your sending domain -> click each DNS record's copy button into your DNS provider -> Verify. API Keys -> Create (Sending access) -> Copy -> Railway variable `RESEND_API_KEY`. Railway variable `MAIL_FROM` = the verified sender address.
5. **Google** (Calendar now, YouTube later): console.cloud.google.com -> APIs & Services -> Credentials -> Create OAuth client ID (type: TV and limited input) -> Copy client id and secret -> Railway variables `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`. After the redeploy send `/connectcalendar` in Telegram, open the link it gives, sign in, **Allow**.
6. **Automation** (only if Donna uses n8n/Make today): copy the webhook URL / API key from n8n or Make into `N8N_BASE_URL` + `N8N_API_KEY` or `MAKE_WEBHOOK_URL`.

Wolf Squad (activation 2):
7. Uses Resend and Google from steps 4-5. **LinkedIn** (optional): linkedin.com/developers -> Create app -> Auth -> copy Client ID / Secret -> Railway variables `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET`. Then in Telegram `/connect linkedin wolf-squad`, open the link, **Allow**.

FF Marketing (activation 3):
8. **Meta**: developers.facebook.com -> My Apps -> Create App (Business) -> Settings -> Basic -> copy App ID / App Secret -> Railway variables `META_APP_ID`, `META_APP_SECRET`. Telegram `/connect meta-facebook ffm` and `/connect meta-instagram ffm`, open each link, pick the pages, **Allow**.
9. **TikTok**: developers.tiktok.com -> Manage apps -> Create -> copy Client key / secret -> `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`. Telegram `/connect tiktok ffm`, **Authorize**.
10. **YouTube**: uses Google from step 5. Telegram `/connect youtube ffm`, open the device link, **Allow**.
11. **X** (optional): developer.x.com -> Projects & Apps -> your app -> Keys and tokens -> OAuth 2.0 Client ID (and secret) -> `X_CLIENT_ID`, `X_CLIENT_SECRET`. Telegram `/connect x-twitter ffm`, **Authorize**.

Optional, any time:
12. Free LLM backups: create keys on OpenRouter / Groq / Cerebras and paste into `OPENROUTER_API_KEY` / `GROQ_API_KEY` / `CEREBRAS_API_KEY`. They only route within the same $3.30/day cap.
13. Voice notes: platform.openai.com -> API keys -> Create -> `OPENAI_API_KEY`.
14. WhatsApp alerts or the emergency call: leave off for now (both need a business number and a template approval).

Bank (no connection, by design):
15. **RBC**: nothing to connect. Monthly: RBC online banking -> Account -> Download transactions (CSV) -> send the file to the bot with `/bank`. Jarvis reconciles it and reports gaps; it never logs in to RBC or moves money.

Finish:
16. Ask Jarvis/Claude to run `python3 scripts/check_integrations.py --office donna` (then `wolf-squad`, `ff-marketing`). Every row your offices need should read `present`.

## 4. Activating an office (after the session, one office at a time)

Activation is yours only, one office at a time, in this order once you approve: **Donna, Wolf Squad, FF Marketing**. In the Supabase SQL editor, each line with your app user id (see `ops/OWNER_OFFICE_OS.sql`):
1. Appoint the manager: `office_os_set_manager('donna', '<manager label>')`.
2. Ask to activate: `office_os_activate('donna')` -> Telegram shows an approval message -> tap **Approve**.
3. Run `office_os_activate('donna')` again -> the office is active. Check with `/office donna` in Telegram.
4. Give it money only when it needs it: `fz_owner_allocate('donna', <cents>, 'why')` (M2). There are no fixed budgets.
