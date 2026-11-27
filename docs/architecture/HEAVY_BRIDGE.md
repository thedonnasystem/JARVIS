# Heavy bridge: Jarvis hands big jobs to Claude Code

Plain English. Built Nov 23 2026. Off until the Chairman switches it on.

## What it is

Some jobs are too big for Jarvis's free model stack: building a site, fixing an office, a deep quality review, long research. The heavy bridge lets the Chairman hand such a job to **Claude Code running on his own Claude subscription**, as a **scheduled task** on claude.ai/code (Anthropic's own feature, formerly "routines").

1. The Chairman sends Jarvis `/heavy <kind> | <what to do>` on Telegram. Kinds: `site-build`, `office-fix`, `qc-review`, `research`, `other`.
2. Jarvis stores the job in a small private queue in the database. Nothing else happens yet.
3. Once a day the scheduled Claude Code session wakes up, asks the queue for a job, does it on a new branch of `thedonnasystem/JARVIS`, opens a pull request, and writes a one-line result and the pull-request link back into the queue. If nothing is queued it stops at once.
4. Jarvis tells the Chairman on Telegram: one line and the link. Nothing is merged; the pull request waits for his review.

Other commands: `/heavy list` (queue and latest results), `/heavy cancel <id>` (a job that has not started), `/heavy on`, `/heavy off`.

## Why this shape (Anthropic's terms, checked Nov 23 2026)

- **Allowed: a scheduled Claude Code task on a personal subscription.** Anthropic's Claude Code documentation says scheduled tasks are "available on Pro, Max, Team, and Enterprise plans", "belong to your individual claude.ai account", may use the account's connectors to read from and write to external services, and "draw down subscription usage the same way interactive sessions do". The Consumer Terms (effective Oct 8 2025) forbid automated access "except ... where we otherwise explicitly permit it"; a scheduled task is exactly such a permitted, built-in feature. The work is the owner's own: his repository, his queue, his account.
- **Not allowed: putting a subscription's sign-in into a third-party bot.** The Claude Code "Legal and compliance" page says OAuth sign-in is for "ordinary use of Claude Code and other native Anthropic applications", that developers building products must use API keys, and that Anthropic "does not permit third-party developers to ... route requests through Free, Pro, or Max plan credentials". The Consumer Terms also forbid sharing account credentials.
- **So the bridge keeps the two apart.** Jarvis never holds, sees or uses a Claude sign-in or token, and never starts or steers the Claude session. It only writes a row in its own database. The Claude session is started by Anthropic's scheduler, signed in by the Chairman, and reads the row through the Chairman's own Supabase connector. Jarvis's chat brain stays on its own model providers.
- Kept deliberately conservative: schedule trigger only (the bot does not call the task's API trigger), once a day, at most 2 jobs. Anthropic notes that plan limits "assume ordinary, individual usage"; a daily job or two is that. Scheduled tasks are a research preview and the terms can change: re-check them if this is ever scaled up.

Sources: code.claude.com/docs/en/routines (scheduled tasks), code.claude.com/docs/en/legal-and-compliance, anthropic.com/legal/consumer-terms. All read Nov 23 2026.

## Limits (enforced, not just promised)

| Limit | Where it is enforced |
|---|---|
| Only the Chairman can add a job | The `/heavy` command checks the owner id; no agent tool, office or job handler calls the enqueue function (a test pins every caller). Signed-in app users, scoped office / Jarvis / auditor tokens and the backup identity are refused by the database. |
| Jarvis may suggest, never queue | A suggestion is only text. See `docs/proposals/heavy_bridge_suggest_hint.md`. |
| No client data, contacts, keys or personal info in a job | E-mail addresses, phone numbers and secret-looking strings are refused three times: in the bot before sending, in the database function, and by the table itself. The result summary is checked the same way. Best effort and fail-closed: a false alarm only asks for a reword. |
| A job is a task, not a permission | The runner prompt forbids merging, approving, deploying, production migrations, spending, external messages and changing caps, the kill switch or any safeguard, whatever a job says. The session may run only two database calls (claim, finish). |
| Protects the weekly Claude limits | One job at a time, at most 2 a day (database setting, cannot be set above 5), at most 10 waiting. Nothing queued: the session ends immediately. |
| Kill switch | While `/kill` is on, no job is handed out. |
| Result link | Must be a pull request in `thedonnasystem/JARVIS`; anything else is refused. |
| A run that dies | A job with no result after 20 hours is marked failed and the Chairman is told. |
| Audit | Every add, cancel, claim, finish and switch writes an audit row with ids and kinds only, never the text. |

What it does **not** touch: the AI spend cap, the kill switch, dry-run mode, executors, the spend gateway, budgets, the backup. The money fingerprint is identical with and without it (proved by `sqltests/heavy_bridge_check.sql`).

## Known limitations

- The database cannot tell the Chairman's `/heavy` from other code running inside the bot with the same service key. The guarantee is that no such code exists (pinned by test) and that every change to the bot needs owner approval.
- The scheduled session uses the Chairman's Supabase connector, which could technically run any SQL. The prompt restricts it to two calls, and the task should carry only the Supabase connector. A read-only connector cannot be used (claim and finish write).
- The detection of contact details and secrets is pattern matching. It will miss unusual formats and sometimes refuses harmless text (a 10-digit number, a 40-character id).
- Results arrive when the daily run happens, not instantly. Weekdays 08:00 to 17:00 the message is held to 17:00, like other non-urgent messages.
- The repository is public: a job's title appears in its pull request. Do not put anything private in a job.
- Pull requests from the session still need the normal review and owner approval for protected paths. That is intended.

## How to turn it off (one switch)

Send **`/heavy off`**. From that moment nothing can be added and nothing is handed out; queued jobs are kept; a job already in progress can still report its result. To also stop the daily session from waking up, pause the scheduled task at claude.ai/code/routines (it would only wake, see "switched off" and stop).

## Rollback

1. `/heavy off` (instant).
2. Pause or delete the scheduled task at claude.ai/code/routines.
3. Database: run `ops/rollback_heavy_bridge.sql`. It removes the functions and moves the queue to `fz_heavy_archive`. No job or result is deleted; re-applying the migration brings them back. Safe to run twice.
4. Code: revert the pull request (removes `hq_heavy.py`, the `/heavy` handler and menu line). With the functions gone but the code still deployed, `/heavy` simply answers "not installed".

## Parts

- `migrations/20261208_heavy_bridge_v1.sql`: private schema `fz_heavy` (jobs, settings), ten functions, all closed to app roles.
- `hq_heavy.py` and the `/heavy` handler in `hq_commands.py`: the owner's side. No AI call, no spend.
- `docs/heavy_bridge/RUNNER_PROMPT.md`: the full instruction of the scheduled session.
- `ops/rollback_heavy_bridge.sql`, `sqltests/heavy_bridge_check.sql`, `test_hq_heavy.py`.

## Switching it on (owner steps, after this is merged and released)

1. Apply `migrations/20261208_heavy_bridge_v1.sql` to production (release approval) and deploy the bot.
2. At claude.ai/code/routines create a scheduled task: repository `thedonnasystem/JARVIS`, daily, prompt = everything below the line in `docs/heavy_bridge/RUNNER_PROMPT.md`, connectors = Supabase only.
3. Send `/heavy on` to Jarvis.
4. Try it: `/heavy research | <a small question>`, then "Run now" on the task, and wait for Jarvis's message.
