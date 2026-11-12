# Go-live checklist (what the green light means)
Everything below is built, tested (136 unit tests; SQL tested on local Postgres 16 and earlier dry-runs on the live DB) and sitting on branch `overnight-build`. Nothing here is live until you say go.

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
| 8 | webapp_v1 | Owner-only app functions | Medium until owner list is set: apply, then add your email BEFORE sharing the URL |
| 9 | push_v1 | Push subscriptions; VAPID key stored in a locked table | Low |

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
