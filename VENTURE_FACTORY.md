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

## Review follow-ups (Nov 13)
- Approval of a draft stamps `outbox.venture_id` with the venture resolved from the draft's lead (one resolver, `_outbox_venture_id`), so the approval gate and `hq_mail.deliver_approved` always agree.
- `sqltests/*.sql` now run inside `scripts/replica/run.sh` (so CI), including the service_role-only grant checks for the new functions.
- Known limit unchanged: Donna's legacy address check is a warning, not a block.

## Deals, replies and do-not-contact (migration `20261115_venture_deals_replies_v1.sql`, code `hq_venture_ops.py`)

Nothing here sends anything. Jarvis still only drafts; the owner approves; every state change below is an owner command and the database also refuses a non-owner actor. No spend, cap, kill-switch, dry-run, permission or capital code is touched.

### Replies and opt-outs
- `/reply <lead#> <interested|not_interested|question|unsubscribe|booked> [note]` (`<lead#>` is the number `/lead` and `/done` show). Stored in `lead_replies`; lead status moves `interested`/`question` -> `replied`, `booked` -> `booked`, `not_interested` -> `lost`. A later reply never demotes a booked or won lead.
- **`unsubscribe` is immediate and covers every venture.** `mark_do_not_contact` flags every lead sharing the address (case/whitespace-insensitive, any venture), writes the address to `contact_suppressions` (kept even if the lead is deleted), and rejects every open draft (`draft`, `qa_passed`, `approved`) to that address. Already `sent` drafts are left as the record.
- No lifting path exists: a reply from an opted-out lead is logged but never clears the flag. Re-consent is a deliberate manual step outside this feature.
- Enforced in four places so no drafting or approval path can bypass it: (1) `leads_suppression_guard` trigger: a suppressed address cannot be inserted clean or un-flagged; (2) `leads_dnc_cascade` trigger: setting `do_not_contact` by ANY path (raw update, old code) cascades to the address; (3) `outbox_dnc_guard` trigger: no insert, `qa_passed`, `approved` or `sent` for a do-not-contact lead or suppressed address (rejecting is always allowed); (4) Python: `_outbox_casl_gate` -> `hq_venture_ops.dnc_problem` refuses approval and releases the tap, `hq_mail.deliver_approved` skips a suppressed address, and the engine's draft insert already filters `do_not_contact=false`. The Python checks fail closed (an unreadable list blocks); only a 404 (migration not yet applied) is tolerated, and the triggers are the backstop.
- **Address normalisation** (`normalize_addr`, SQL and `hq_mail.normalize_addr`, one shared case table in the sqltest that a Python test also runs): the address inside `<...>` if present, lowercased, `+tag` dropped from the local part, dots untouched. `bob@x.com` opting out therefore also covers `bob+z@x.com` and `Bob <bob@x.com>`. A recipient containing `;` or `,` (a list) is refused by the outbox guard and by the approval gate.
- **The suppression list is append-only**: update, delete and truncate raise (trigger) and are revoked from service_role. There is deliberately NO unsuppress path in this sprint; re-consent is an owner decision for later. Deleting a lead deletes its replies but never its opt-out.
- Limit: matching is by email address only. A phone-only lead (the day-job flow) is flagged on that one lead; there is no phone-number suppression.

### Deals (owner-confirmed; revenue only on confirmation)
- Stage names: the repo only evidences `pitched` (table default) and the won-like names `venture_kpis` already counts (`won`, `closed`, `closed_won`, `paid`). The pipeline is therefore `pitched -> negotiating -> won | lost` (`negotiating -> pitched` allowed). Legacy won-like names are treated as already won and terminal. No CHECK constraint was added, so existing rows are never invalidated.
- Amounts (deal value and win confirmation) are capped at 10,000,000 cents (CAD $100,000) in SQL and in the bot. One open deal per lead: `create_deal` refuses a second, and a unique partial index backs it only when the existing `deals` rows contain no duplicates (the core table never forbade them).
- `/deal new <lead#> [value]`, `/deal move <code> pitched|negotiating|lost [note]`, `/deal list [venture]`, `/deal won <code> <amount> received|expected [note]`. `<code>` is the first 8 characters shown by `/deal list`. A deal cannot be opened for a do-not-contact lead.
- **`/deal won` is the only thing that records revenue.** `confirm_deal_won` requires the owner as actor, a typed positive amount and an explicit `received` or `expected`, then writes exactly one `ledger` revenue row (the same table `/money in` writes), sets the deal and lead to `won`, and audits it. It refuses a second confirmation (no double revenue) and any deal already won/lost. `set_deal_stage` refuses `won`. Nothing infers or defaults an amount; KPIs still count only `received` revenue.

### Funnel and KPIs (read-only)
- Lead funnel per venture: `new, drafted, approved_to_send, sent, replied, booked, won, lost, do_not_contact`, plus `other` for any status not in that list (so the buckets always add up to the lead total, and nothing is hidden). `contacted` (what `/sent` and `hq_mail` write today) counts as `sent`; the dayjob `closed` status falls in `other`. `do_not_contact` is decided by the flag, so it overrides status.
- `/venture funnel <venture>` shows the funnel, replies by kind and replies waiting longer than the reply SLA (a lead still `replied` whose last interested/question reply is older than the SLA). `/venture kpis` and `venture_kpis()` now also carry `funnel`, `replies_by_kind`, `replies_over_sla`, `reply_sla_hours` (existing keys unchanged). `/venture deals [venture]` lists deals.

### Per-venture operating config
- `/venture config <venture>` shows it; `/venture config <venture> offer|cta|sla <value|clear>` and `... brief <text>` set it. Offer, call to action and reply SLA live in `venture_config` (a short value cannot fit `venture_procedures`, which needs 20+ characters); the **prospecting brief stays a `venture_procedures` row** titled `prospecting brief`, because `queue_prospect_task` already reads it.
- Fail-closed defaults: no offer or call to action means `drafts_ready` is false and **a draft for that venture cannot be approved** (tap released, draft untouched), checked after the CASL profile gate. Donna keeps its legacy flow. The reply SLA defaults to 24h and is shown as `(default)`. Credential-looking values are refused.
- Honest scope: the draft-writing prompt itself lives in `hq_engine.py` (another owner) and still reads the offer from company knowledge. The config is enforced at approval, not injected into the prompt; wiring it into the prompt is a small follow-up for whoever owns the engine.

### Rollback and checks
- `ops/rollback_phase1.sql` drops the triggers and new functions and restores the 20261114 `venture_kpis` body (then the generic block drops it). Tables (`contact_suppressions`, `lead_replies`, `venture_config`) are left in place by design; the suppression list is a legal record.
- `sqltests/venture_deals_replies_check.sql` (run by `scripts/replica/run.sh`) proves anon/authenticated cannot execute any new function and the do-not-contact, owner-only, revenue-only-on-confirm and funnel rules. Python: `test_hq_venture_ops.py`, plus additions to `test_hq_mail.py`.
