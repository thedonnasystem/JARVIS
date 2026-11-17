# Jarvis core v2: owner guide

Plain English, for you, sir. Everything below is built and tested on a dev branch and is **switched off**. Nothing runs, spends or calls anyone until you turn it on.
Engineering detail: `JARVIS_CORE_V2_DESIGN.md`. Free model terms: `FREE_PROVIDER_TERMS.md`. Self-hosted brain: `ops/selfhost/README.md`. Switches: `ops/OWNER_JARVIS_CORE.sql`.

## 1. What Jarvis can do (once on)
- **Run 24/7 as the only always-on agent.** A durable job queue per division (Donna, Wolf Squad, FF Marketing; the rest dormant). Other agents sleep until Jarvis wakes them for a real queued job, with the reason logged; they keep going while they have work, then sleep again (queue empty, no progress, or 10 jobs). Retries with backoff, failed jobs parked, every step logged.
- **Respect your hours** (Toronto): 22:00-07:00 emergencies only; weekdays 08:00-17:00 urgent only; otherwise anything. Held messages are delivered when allowed.
- **07:00 daily report** on Telegram: revenue, costs, net, runway, spend per division, missions, approvals waiting, agent wakes and sleeps, changelog, and what the next dollar would buy.
- **Chairman briefing** (`/briefing`): who he is, who you are (from your memory file), what he can do, his limits, what still needs you.
- **Memory seed**: send your private markdown file to the bot with the caption `/seedmemory`. It is read in memory, never saved as a file or put in the repo; duplicates are skipped; one audit row (counts only).
- **Other commands** (no AI, $0): `/core` (status), `/report` (daily report now).
- Always calls you "sir".

## 2. What it costs: $0 by default
- **Brain = free tiers in rotation** (Groq, OpenRouter free models, GitHub Models, NVIDIA, Cerebras trial) plus a **free self-hosted** small Hermes model on an always-free CPU VM. When one free tier is full Jarvis moves to the next; when all are full he queues the work and tells you. **He never switches to a paid model on his own.**
- **Client personal data never goes to a free provider**: only to your own self-hosted model, or it is handled by plain code.
- Every call still goes through the spend gateway, so the kill switch, the daily cap (unchanged), the agent cap and mission budgets all apply. Free calls are recorded at 0 cents.
- **Self-funding rule** (his standing top objective): paid models or a GPU can only be paid from your chosen share (0-50%) of revenue **you** confirm as Jarvis's, after bank reconciliation. Confirming and the share are yours only; caps and approvals still apply.

## 3. What is locked (the never-edit list, `ops/PROTECTED_PATHS.json`)
Money controls; the kill switch and dry-run/live mode; Jarvis's own permissions; consent/opt-out, client data protection, backups and the insurance guard; the tests and CI that judge his work (and this list itself); audit history; destructive data changes.
Any change touching these fails CI unless **you** approve that exact commit. Jarvis's self-edit pipeline refuses them outright.

## 4. How approvals work
- **Code changes to locked areas**: on the pull request in GitHub, either tap **Review -> Approve** (works when Jarvis's machine account opened the PR), or add the label `owner-approved-<first 12 characters of the latest commit>` (for PRs opened from your own account, because GitHub does not let you approve your own PR). A new commit cancels the approval. CI re-checks automatically.
- **Switches** (core, worker, self-edit, WhatsApp, calls, self-funding, large model tier): only you, in the Supabase SQL editor (`ops/OWNER_JARVIS_CORE.sql`). The bot is refused.
- **Why not a Telegram button for code approvals?** CI cannot read the production database without another secret, and anything the bot can write, the bot could forge. A GitHub action by your own account is the simplest marker Jarvis cannot fake, as long as Jarvis uses a **separate** GitHub account (the pipeline refuses your token).

## 5. Channels and privacy (honest)
- **Telegram** (main channel): bot chats are **not** end-to-end encrypted.
- **WhatsApp Business Cloud API** (built, off): encrypted in transit, but processed on Meta's servers, so **not** end-to-end like a normal WhatsApp chat.
- **Emergency phone call** (built, off): only for kill switch tripped, security incident, runaway spend, production down, or a time-critical deal/legal deadline (`ops/CRITICAL_EVENTS.json`, which you approve and which is locked). Short scripted message: "check Telegram". At most 2 calls a day, no repeats within 24 h, every decision logged. A phone call is **not** end-to-end encrypted.
- **Live two-way voice**: design only (`hq_channels.VoiceConversation`), no vendor chosen.
- None of these channels carries secrets or client personal data.

## 6. Self-edit (built, off)
Jarvis writes code on a branch with his own GitHub machine account, opens a PR, CI runs, a different model reviews it, the locked-list check passes, then it auto-merges **only into `jarvis/integration`**.
**Important:** merging into `overnight-build` redeploys the Render app, and Railway deploys the bot from `claude/telegram-claude-bot-59nusk`. So Jarvis never merges there. Proposed activation: you promote `jarvis/integration` to `overnight-build` with one approved PR (label), then fast-forward the Railway branch as in `DEPLOY_RUNBOOK.md`; after each deploy Jarvis health-checks and, if it fails, opens the revert for your one-tap approval (fully automatic revert only if you later allow it). Every merge, refusal and rollback appears in the 07:00 report.
Self-automation (off): when a task type repeats past your thresholds (default 20 runs or $2 of AI), Jarvis drafts plain code for it through this pipeline. Never for locked areas.

## 7. Turning things on (in this order)
1. Approve and release the migration `20261123_jarvis_core_v1` (release path; it is additive).
2. Set at least one free provider key in Railway Variables (section 8), then `JARVIS_CORE=1`.
3. Run steps 1-3 of `ops/OWNER_JARVIS_CORE.sql`. Send `/core`, then `/briefing`.
4. Optional: self-hosted brain, WhatsApp, calls, self-edit, self-funding, each separately.

## 8. Your checklist (never paste keys in chat; put them only in Railway Variables)
- [ ] **Branch protection** (GitHub, repo Settings -> Rules -> Rulesets -> New branch ruleset): target `overnight-build` and `claude/telegram-claude-bot-59nusk`; enforcement Active; no bypass list; tick "Restrict deletions", "Block force pushes", "Require a pull request before merging" (required approvals 0, so your own PRs still work; tick "Require review from Code Owners" only once Jarvis uses a machine account), "Require status checks to pass" and add `unit`, `migrations`, `secret-scan`; Save.
- [ ] **Approve this PR's locked changes** (it adds the check itself, edits CI, migrations, backup classification and two judge tests): add the label `owner-approved-<head 12>` once you have reviewed it.
- [ ] **Free model keys** (each takes a few clicks, $0): Groq console -> API keys -> `GROQ_API_KEY` (turn on Zero Data Retention in Data Controls); OpenRouter -> Keys -> `OPENROUTER_API_KEY` (Settings -> Privacy: keep model training OFF); optional `GITHUB_MODELS_TOKEN`, `NVIDIA_API_KEY`, `CEREBRAS_API_KEY` (trial only).
- [ ] **Free self-hosted brain** (optional but needed for client data): an always-free ARM VM, then `ops/selfhost/README.md`; set `JARVIS_SELFHOST_BASE_URL`, `JARVIS_SELFHOST_API_KEY`.
- [ ] **Jarvis's GitHub machine account** (for self-edit): create a separate free GitHub account, add it to the repo, create a fine-grained token for this repo only (Contents read/write, Pull requests read/write, Checks read) -> `JARVIS_GITHUB_TOKEN`; create branch `jarvis/integration`.
- [ ] **WhatsApp** (optional): Meta Business account -> WhatsApp -> API setup; add a phone number, verify the business, create a permanent System User token -> `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_OWNER_NUMBER` (your number), approve a message template for messages outside the 24-hour window (`WHATSAPP_TEMPLATE`); `JARVIS_WHATSAPP=1`. Cost: Meta charges per business-initiated template message (check current Canadian rates).
- [ ] **Emergency calls** (optional): Twilio account, buy one Canadian number (roughly US$1-2/month) -> `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `OWNER_PHONE_NUMBER`; `JARVIS_EMERGENCY_CALL=1`. Calls cost about US$0.01-0.03 per minute in North America (check current pricing); 2 calls a day max means cents per month. Approve `ops/CRITICAL_EVENTS.json` (status line).
- [ ] **Paid GPU** (only later, from self-funding): create the GPU account yourself, approve the monthly cost, paste the endpoint key into Railway (`JARVIS_GPU_*`).

## 9. Nous "Hermes Agent" vs our Jarvis core
Hermes Agent (Nous Research, MIT licence) is an agent framework with memory across chats (including Telegram), self-improving skills and scheduled tasks. **We do not replace Jarvis with it**: it has none of our spend gateway, kill switch, consent and suppression rules, HQ database, missions or never-edit enforcement, and swapping it in would bypass all of them. Ideas worth borrowing (not built): its skill files as a format for the self-automation drafts; its per-chat memory summaries as an input to `/seedmemory`; its scheduled-task syntax for owner-defined jobs (still through our queue and gateway). We do use the Hermes **models** as the default open-weight brain (confirm the exact model id, licence and tool-call format at activation, `ops/selfhost/models.json`).

## 10. Limits (stated plainly)
The new Jarvis tables (queue, logs, wakes, approvals) are NOT in the encrypted off-site backup yet (the export needs a reviewed redaction rule per column first; follow-up); your database provider's own backups still hold them. Nothing here is proven in production: tests use a scratch database and mocked providers. Free-tier limits and terms change without notice. Rate tracking is in memory (a restart forgets it; providers' own limits still apply). The protected-path check is a tripwire plus an approval gate: branch protection must require it, and a cleverly disguised change can still slip past pattern checks, so locked-area PRs need your reading.
