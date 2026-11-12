# Go-live checklist (what the green light means)
Everything below is built, tested (172 unit tests; SQL tested on local Postgres 16 and earlier dry-runs on the live DB) and sitting on branch `overnight-build`. Nothing here is live until you say go.

Exact file order: `migrations/APPLY_ORDER.txt`.

## Order (each step is reversible by dropping what it added; none deletes existing data)
| # | Migration | What changes | Risk |
|---|-----------|--------------|------|
| 1 | permissions_v1 | Action policy (default-deny), approvals, action log. Dry-run mode stays on. | Low: agents get stricter, not looser |
| 2 | chat_meter | Jarvis chat model calls count against the daily cap | Low |
| 3 | capital_v1 | Fund, reserve, per-purchase and weekly limits; low-cost mode | Low; fund starts at the $300 example, change with /capital |
| 4 | bank_v1 | Bank balance caps spendable cash; statement import | Low; with no balance recorded it only alerts |
| 5 | learning_v1 | Measures mission forecasts, writes lessons (no AI cost) | Low |
| 6 | org_v1 | Structured proposals, scorecard, richer weekly review | Low |
| 6b | holding_v1 | Holding P&L (received cash only), weekly earn-your-keep review proposing to pause costly idle agents (you approve) | Low |
| 7 | ventures_v1 | Venture factory (inert until you approve) | Low |
| 8 | webapp_v1 | Owner-only app functions (incl. follow-ups-due card, day-job log, drafts, idea lab) | Medium until owner list is set: apply, then add your email BEFORE sharing the URL |
| 7b | agents_v1 | Jarvis can create departments/agents inside hard limits (cheap/standard, <=50c/day, max 3 a week, asleep if budget full) | Low |
| 7c | opportunity_v1 | Weekly (Wed) opportunity scan per ACTIVE venture: manager agent sends <=2 structured proposals for your approval (apply after 7) | Low; inert until a venture is active |
| 8c | venture_view_v1 | Venture Details drill-down in the app (goals, recent work, what it knows); owner-only (apply after 7 and 8) | Low |
| 8d | office_v1 | Corporate office (spec 11): the nine functions as live views over real agents, tasks, spend and data (apply after 8) | Low; adds one nullable agents column |
| 8e | payments_v1 | Payment instructions: Jarvis reserves funds and asks; YOU pay in RBC and confirm with the bank reference (/pay done). No money movement, no credentials. Needs capital_v1, bank_v1 (apply after 8) | Low |
| 8f | assets_procedures_v1 | Per-venture websites/assets/integrations and operating procedures (names and URLs only; credentials refused); shown in venture Details | Low |
| 8g | accounts_v1 | Account requests: Jarvis asks, you approve and sign up yourself (captcha/codes/ID are yours), `/account done` records the login as an asset; no passwords (apply after 8f) | Low |
| 7d | allocation_v1 | `/venture budget <slug> <$>`: owner-only monthly ceilings whose total can never exceed real available money (apply after 7) | Low |
| 8b | brief_v3 | 7pm brief gains P&L, bank alerts, forecast accuracy, pending proposals (apply after 3-7) | Low |
| 9 | push_v1 | Push subscriptions; VAPID key stored in a locked table | Low |

## Verified
All migrations apply cleanly in order to a replica of the live schema, and an end-to-end script (venture, payment, account, allocation, office, app snapshot as the owner) passes: `scripts/replica/run.sh` (also runs in CI).

## After the migrations
1. Supabase Auth: email provider on, signups OFF, add your user, insert your email in `app_owners`.
2. Merge `overnight-build` into the deploy branch; Railway redeploys Jarvis (new: /bank, /venture, push, web poller).
3. Generate the VAPID pair, store it in `push_config`, set the contact email.
4. Open the app from Safari, Add to Home Screen, turn on notifications.
5. Send `/bank balance <amount>` (your real RBC balance) so the real number caps spending.

## What stays in dry-run (needs your explicit later approval)
Sending email, spending money, signing, contacting leads, any call. Ventures start inactive.

## Still on your list (I cannot do these)
- Top up Anthropic API credit and turn on auto-reload (HQ has been paused since Nov 8).
- Paste `WHOLESALE_SUPABASE_SERVICE_KEY` into Railway (unlocks the deal funnel numbers).
- `/setaddress` (unblocks 15 Donna drafts), rotate the Telegram token, make the Jarvis repo private (then reconnect Render to GitHub so the app site can redeploy).
- For Jarvis to edit his own code: a GitHub token limited to this repo with pull-request-only rights (design in ROADMAP_SECTIONS_10_12.md).

## One-paste go-live (Nov 12)
- `dist/APPLY_ALL.sql` = all 19 migrations in order (140 KB, idempotent; tested on the live-schema replica, applied on top of itself).
- `dist/POST_APPLY.sql` = registers owner emails in `app_owners`.
- Supabase dashboard -> SQL editor -> paste APPLY_ALL -> Run -> paste POST_APPLY -> Run.
- The assistant's own attempt to apply to production was blocked by the permission system; it needs the owner's explicit approval.
