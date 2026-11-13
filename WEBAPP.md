# Fendezy HQ web app (private PWA)

Live URL: https://fendezy-hq-app.onrender.com  (static site, free; source: `webapp/`, branch overnight-build)
Owner-only: the page is public, the data is not. Every read/write goes through `app_*` database functions that check `is_app_owner()`.
Until `20261112_webapp_v1.sql` is applied and your email is in `app_owners`, the app shows "not authorized". That is intended.

## Install on iPhone
1. Open the URL in Safari (must be Safari, not Chrome).
2. Share button -> Add to Home Screen -> Add.
3. Open from the Home Screen icon (full screen, no browser bar).

## Turn on owner login (needs your green light, one-time)
1. Apply migrations in order: permissions_v1, chat_meter, capital_v1, bank_v1, learning_v1, org_v1, holding_v1, ventures_v1, agents_v1, brief_v3, webapp_v1, push_v1 (missions already live).
2. Supabase dashboard -> Authentication -> Providers -> Email: on. Disable "Allow new users to sign up".
3. Authentication -> Users -> Add user: your owner email (auto-confirm).
4. `insert into app_owners(email) values ('<owner email>');`
5. Authentication -> URL config: Site URL = the app URL. Email template: make sure the 6-digit `{{ .Token }}` is in the magic-link email (the app signs in with the code).
6. Open the app, enter the email, type the code. A stranger who somehow gets a session is refused by the database.

## What is on each tab
- Jarvis: chat (same brain as Telegram, metered as 'jarvis-chat'), mic button (browser speech recognition), optional spoken replies.
- Inbox: everything waiting on you in one ranked list (approvals, questions, blocked missions; with the full inbox also payments, drafts, alerts, escalations, blocked tasks). The tab shows the count. Approve/Reject/answer/Resume use the existing decision path (same `app_send` kinds as Home), nothing new. See "Inbox sign-off" below.
- Home: day-job quick log (dials, pitches, submissions, paid deal), fund, Follow-ups due (call link, Called +3d / No answer +1d / Close) with an Add lead form, outreach drafts to approve, Needs you (Approve/Reject/answer buttons), ventures (Details: goals, recent work, what it knows), pipeline, systems, kill switch.
- Missions: idea lab (start a 7-day test or park), open a mission or set up a new venture (inactive until you approve), pause/resume/abandon, budget bar, evidence verdicts. Action results show in a banner within seconds.
- Agents: Corporate office (Executive, Business Development, Research, Engineering, Marketing, Sales, Finance, Operations, Agent Management; each computed from real agents and data, unstaffed ones say so), then all agents grouped by Company and each venture; status, spend vs cap, scorecard flags, pause/resume; proposals and org changes below.
- Money: Payments to make (approved instructions: pay in RBC yourself, then confirm with the reference), capital snapshot (received cash only), P&L, bank card (type your real balance, import a statement CSV, reconcile), 7-day AI spend, permission tiers.
- Feed: live activity. Refreshes every 8s and on app focus.

## Voice
Browser-only: Web Speech API for speaking to Jarvis, speechSynthesis for replies. Works in Safari/iOS; the screen must be open. No cost.

## Push notifications (built, needs keys at apply time)
- Code is in: service worker `push` handler, Home > Notifications > "Turn on notifications", `hq_push.py` (sent right after each Telegram delivery; fails silent), migration `20261112_push_v1.sql`.
- iPhone needs iOS 16.4+, the app added to the Home Screen and opened from the icon, then tap the button (iOS only asks on a tap).
- At apply time: generate a VAPID key pair, store it in `push_config` (the private key goes only into that locked table, never into git or env), set the contact address, apply push_v1 after webapp_v1. `pywebpush` is added to requirements.txt.
- Telegram stays the reliable channel; push is the faster extra.

## Incoming calls (investigation note)
- A web app cannot ring the phone like a call; iOS PWAs cannot use CallKit.
- Options, cheapest first: (1) push notification "Jarvis needs you" (free); (2) Twilio/Retell outbound phone call to the owner's number for emergencies only (per-minute cost, ~CAD cents per call; needs Twilio number, owner consent, within budget); (3) in-app WebRTC voice with a realtime model (cost per minute, only while the app is open).
- Recommendation: push first, phone call only for red-level events, both behind the capital controller.

## Security notes
- No third-party scripts: supabase-js is self-hosted in `webapp/vendor/`, and a Content-Security-Policy limits scripts to the app itself and network calls to your Supabase project. The app never uses innerHTML (all text is set as text).
- Publishable key in `app.js` is public by design (RLS deny-all; only owner-checked functions are callable).
- Kill switch is available from Home. Agents cannot change policy or capital limits from the app.

## Inbox sign-off (one owner decision)
- `needs_you()` (database) ranks the inbox; Telegram `/needs` and the brief use it with the service key and work as soon as `20261115_inbox_needs_you_v1.sql` is applied.
- The PWA reads `app_needs_you()`. To be callable by the signed-in owner its name must be in the lockdown keep-open list (an applied migration), so it is created closed and the Inbox tab falls back to approvals, questions and blocked missions from `app_snapshot` (it says so on the page). Exact 7-step change: `ops/pending_signoff/inbox_open_app_needs_you.txt`. `scripts/check_app_rpcs.py` keeps this honest (it fails if the pending entry goes stale).

## Tests that run in CI (no browser)
- `python3 scripts/check_app_rpcs.py` (gate step `appcheck`, always runs): fails on drift between the functions `app.js` calls, the lockdown keep-open list, the pasted copies in `ops/verify_live.sql`, `ops/preflight_live.sql` and `scripts/replica/e2e.sql`, the migrations' grants; between the message kinds the app sends, the `web_messages` constraint and `hq_web.py`; and checks `sw.js` caches every shipped asset (index.html references, manifest icons, every file under `webapp/` except `sw.js`, `vendor/README.txt` and the public `apply/` page).
- `webtests/` (gate step `webjs`, OPTIONAL): `node --test` with jsdom 24.1.3 (pinned, dev only, `npm ci --ignore-scripts`; skipped cleanly without node). Boots the real `index.html` + `app.js` against a fake backend: every tab renders from fixture data and from an empty database, Approve/Reject/answer/Resume call `app_send` with the exact kind and payload, the Inbox refuses any action kind other than decision/answer/mission, errors show a banner and keep the last screen (a malformed snapshot shows an error on the page, not a blank tab), the functions called at runtime are all in the lockdown list, no `innerHTML`, CSP matches the Supabase URL, and the real `sw.js` is executed (install caches the shell, offline falls back to cache, old caches dropped). Run locally: `cd webtests && npm ci --ignore-scripts && npm test`.
- These are synthetic tests with a fake backend; they prove the page logic, not production behaviour.
