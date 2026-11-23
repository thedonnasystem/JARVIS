# Legacy offices, Office Doctor and Quality Control (proposal for owner approval)

Branch `build/legacy-offices`. Built Nov 23 2026 from the five legacy repos the Chairman named (read in local shallow clones, never copied here) and the in-repo real-estate bridge (`hq_wholesale.py`). Private repos are named only. No lead, contact, key or personal data is in this repository.

## What is on the branch (all outside the protected paths)
- `legacy_offices/offices/<slug>.json`: four offices in the `offices/TEMPLATE.json` format, plus a `legacy` block (repo, stack, entry points, env NAMES, tests, dry run) and a `qc` block (funnel stages, targets, changes ranked by revenue impact). `legacy_offices/registry.json` lists all five systems; n8n-railway is marked not viable.
- `legacy_offices/doctor.py`: `/doctor <office>|all [plan]`. Checks: last commit, last successful run and the reason GitHub gives for failures, env/secret names, the repo's own tests (local clone only), data age, spend vs cap (GitHub Actions minutes vs the free quota), unpinned dependencies. It gives a plain diagnosis and a ranked fix list. `plan` drafts an improvement plan through `hq_llm.complete` with `sources=["system","repo_code"]`, and only redacted structure and error text are sent. hq_llm's own client-data routing still applies.
- `legacy_offices/qc.py`: `/qc <office>|all`. Funnel (found, qualified, contacted, replied, booked, closed, $ per week), a 0-5 rubric (lead fit, message quality, duplicates and junk, freshness, deliverability), targets, the previous run (aggregates in `LEGACY_QC_STATE`), the bottleneck, a keep / fix / kill verdict and the top 3 changes. Collectors return counts only. The LLM judge accepts samples marked synthetic only.
- `legacy_offices/runner.py`: the only place a process is started (a legacy repo's tests or dry-run job in a local clone). The child gets an empty environment plus PATH/HOME, any flag that looks like a credential is refused, argv is a list (no shell), and every run has a timeout. **The protected-paths tripwire flags this file by design (it uses `subprocess`), so the owner reviews it on its own.**
- `legacy_offices/commands.py` (`register(app, CommandHandler)`) and `legacy_offices/cli.py` (`python3 -m legacy_offices.cli doctor|qc|dryrun ...`).
- `legacy_offices/tests/test_legacy_offices.py`: 21 tests, stdlib only, synthetic data, a fake GitHub.

## Owner approvals needed (each touches a locked path, so none is done on this branch)
1. **Wire the commands** (`hq_commands.py`, locked). Add to `register()` next to the other dormant modules:
   ```python
       try:  # legacy offices: /doctor, /qc (owner only, read-only; no AI unless '/doctor <office> plan')
           from legacy_offices import commands as legacy_commands
           legacy_commands.register(app, CommandHandler)
       except Exception:  # never block startup over the legacy offices
           logger.exception("legacy office commands not registered")
   ```
   (`from legacy_offices import commands as ...` is itself a tripwire line. Plain `import legacy_offices.commands` works too.)
2. **Run the tests in the gate** (`scripts/gate.sh`, locked). `python3 -m unittest discover` does not find tests in a folder with no `__init__.py`, and `__init__.py` is locked too. Add a step:
   `run legacy "legacy offices tests" python3 -m unittest -q legacy_offices.tests.test_legacy_offices`
3. **Make them real offices** (database + `offices/`, locked). `test_hq_office_os` pins the exact file list in `offices/`, and every office needs an M1 `fz_offices` row and an M7 `fz_office_profiles` row (a migration, then a production release). When the owner wants any of them active: one migration that adds the rows (dormant, as M7 requires), moves the JSON into `offices/`, and updates `hq_office_os.OFFICES` / `ALIASES` and that test. One office at a time, as the M7 rules say.
4. **Credentials for remote checks (optional):** `LEGACY_GITHUB_TOKEN`, a fine-grained read-only token on the five legacy repos (Contents, Actions, Metadata: read). Without it the doctor reports `unknown`. Railway-hosted offices have no telemetry Jarvis can read. Either give the services a daily heartbeat, or write host observations to `LEGACY_HOST_STATE` from a read-only Railway check.

## Inventory (verified Nov 23 2026)
| system | stack | runs on | last commit | tests | state | why it is not working |
|---|---|---|---|---|---|---|
| canada-wholesale-pipeline | Python, Actions cron, Supabase store, Pages | GitHub Actions daily | 2026-11-21 (bot) | 5 suites pass offline (76 checks) | **stopped Nov 22** | GitHub refused to start the job ("recent account payments have failed or your spending limit needs to be increased"). Runs grew to 85-113 min/day (pipeline ~52, ARV refresh ~47): about 2,900 min/month projected vs 2,000 free. Outcome tracking stops at buyer-matched, so revenue cannot be measured. Latest funnel: 30 open leads, 12 priced, 8 buyer-matched, 6 with no comps. |
| freelance-pipeline | Python, APScheduler, SQLite, Telegram, Anthropic | Railway (removed) | 2026-07-29 | none on main | **not running** | Railway deployment removed since Jul 29. The filter passed 70 of 370 live posts, almost all full-time roles. Freelancer.com bids auto-submitted with no review. Needs ANTHROPIC_API_KEY billing, Telegram, and a Freelancer.com OAuth app. |
| dialer (+ coach) | Node 20, Telnyx, Deepgram, Chrome extension | Railway `sales-coach` (SUCCESS, Nov 14) | 2026-11-07 | dialer + coach suites pass in mock mode | running | Technically fine. Compliance risk: 4 parallel lines abandon about 9-26% of live answers against a 5% rule. The README described Twilio. Call outcomes live only in its volume. |
| mss-ifvg-paper | Python 3.12, FastAPI, SQLite, Alpaca paper / Yahoo | Railway (SUCCESS, redeployed today) | 2026-11-23 | 44 pass (needs fastapi) | running, paper only | Not broken. It earns $0 by design, and its edge is unproven. Another session was changing this repo today, so no PR was opened here. |
| n8n-railway | Dockerfile `FROM n8nio/n8n` + `USER root` | Railway (removed) | 2026-07-29 | none | dead | Not a system. Kill as an office. If n8n is wanted, run it as a shared service with a pinned image and a non-root user. |
| `hq_wholesale.py` (in Jarvis) | Python bridge to the funnel's Supabase | Jarvis | - | `test_hq_engine` | dormant | Waits on `WHOLESALE_SUPABASE_SERVICE_KEY`. It belongs to the realestate-ca office. |

## Rollback
Nothing on this branch is wired into the bot, the database or a deploy. To roll back, revert the merge commit, or delete `legacy_offices/` and this file. The legacy-repo PRs are separate and unmerged: close them.
