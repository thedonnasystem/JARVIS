# Launching a new venture on the shared infrastructure

Applies once `migrations/20261114_venture_generic_v1.sql` is applied (it is placed before the lockdown migration, which stays last) and the matching bot code is deployed. Every step below is an owner action or an owner-approved action; nothing here sends email, spends money or raises a limit.

## Steps (in order)

1. **Create it, inactive.** `/venture new <name> | <one-sentence idea>`. This makes the venture (`proposed`), its department, a paused `<slug>-manager`, a validation mission and an activation card. Nothing spends until step 7.
2. **Add the revenue-loop agents, paused.** `/venture agents <slug>` (calls `ensure_venture_agents`). It creates `<slug>-researcher` (lead capture: the engine only stores leads from agents whose slug ends in `researcher`) and `<slug>-division` (drafting: `queue_outreach_drafts` needs an active `<slug>-division`). Both are cheap tier, 15c/day cap, cannot contact the owner, and are forced to `paused`. It goes through the existing `create_agent`, so the 3-agents-per-week limit applies: two agents per venture means roughly one new venture per week, and it refuses cleanly (creating nothing) when the limit would be exceeded. Safe to re-run.
3. **Write the prospecting brief.** Ask Jarvis (the `hq_save_procedure` tool) or use a procedure with the exact title `prospecting brief` for the venture: who to find, where, size and signals. Without it `queue_prospect_task` does nothing, by design.
4. **Set the CASL profile (required before any email).** `/setaddress <slug> 123 Example St, City ON A1A 1A1`, then `/venture profile <slug> sender <name>` and `/venture profile <slug> brand <name>`. A venture without all three cannot have a draft approved (the tap is released, the draft stays a draft) and `hq_mail` will not send for it. The footer is built from that venture's row and resolved from the draft's lead, so a second venture can never go out under Donna's brand or address.
5. **Money.** `/money in|out <amount> <slug> <note>` now resolves any venture slug or name. An unknown name is an error. Use the word `company` for a company-wide entry.
6. **Missions and asks.** `/mission new @<slug> <objective>`; `/ask <slug> <task>` goes to the venture's manager.
7. **Activate (owner tap).** Approve the activation card or `/venture activate <slug>`. This wakes the manager, researcher and division together (their caps add up to 55c/day). Note `activate_venture` does not re-check the company cap total; that is existing behaviour.
8. **Prospecting.** `select public.queue_prospect_task('<slug>')` queues one research task (needs: active venture, active researcher, a brief, fewer than 15 unworked emailable leads, no open or recent prospect task, system not paused). `queue_all_prospect_tasks()` loops every active venture except donna that has a brief. **It is not scheduled.** To run it daily, an owner-approved one-liner is needed: `select cron.schedule('hq-venture-prospects', '30 15 * * *', 'select public.queue_all_prospect_tasks()')`. Donna's own cron (`hq-donna-prospects`) is untouched.
9. **Measure.** `/venture kpis <slug>` (leads, drafted, approved, sent, won deals, revenue received, from real rows via `venture_kpis`). Read-only.

Agents created by step 2 for a venture that is already `active` stay paused until the owner resumes them (the app or `/agents`; verify the resume path before relying on it).

## What remains per-venture by design

- The offer, price, call to action and the draft wording (company knowledge and the brief). Nothing is generic about what a venture sells.
- The prospecting brief and any geography, trade or size filter. Donna's HVAC/plumbing/electrical rotation stays hard-coded in its own function.
- The sender identity and legal mailing address (steps 4). The owner supplies them; they are never defaulted.
- Terms and pages that are still Donna-specific: setters (`hq_setters.py`, `setter_apply`, payouts), the `/apply` page, `VENTURE_TEAM` in `hq_missions.py` (a mission for a new venture falls back to the idea-lab team), the valuation task's hard-coded venture, `queue_daily_planning`.
- What counts as a "won" deal. `venture_kpis` counts stages `won`, `closed`, `closed_won`, `paid` and also returns `deals_by_stage` so the real vocabulary is visible; confirm it against live data.
- `venture_goals.current_value` is still not written automatically; KPIs are reported, not stored. Revenue is only ever entered through `/money` or existing payment flows.
- Budget (`/venture budget`), activation, stage moves, any send, domain/account creation, ad spend: owner gates as before.

## Known limits

- `hq_mail.deliver_approved` requires the body to already contain the venture's footer address; the footer is currently appended only in the owner's approval message (the send-it-yourself flow). The automated sender stays dormant, and strict, until that is wired deliberately.
- A hand-made draft with no venture and no lead can still be approved on the legacy Donna path; the automated sender refuses it.
- `scripts/replica/run.sh` does not run `sqltests/venture_generic_check.sql`; run it after the replica (see its header), since run.sh's rollback drill drops the new functions at the end.
