# FENDEZY GROUP Phase 1, M3: Approvals kernel + office wiring

Branch `build/p1-m3-approvals`, stacked on `build/p1-m2-office-money` (M2, unmerged). Migration `migrations/20261129_approvals_kernel_v1.sql`, rollback `ops/rollback_approvals_kernel.sql`, proof `sqltests/approvals_kernel_check.sql` and `test_hq_approvals.py`.
Nothing is live until the owner applies M1, M2 and M3. Payment behaviour stays exactly the same until the owner sets `FZ_OFFICE_SPEND_GATE=1`.

## 1. What was built

| Piece | What it is |
|---|---|
| One queue | `fz_approval_queue` (view): every request waiting on the owner, from both sources: `approval_requests` (red / approve-first actions) and the M2 office money proposals. Columns: type, source id, office, requester, action, amount, risk (policy tier, or `money`), effective status (pending past expiry shows `expired` at once), created, expires, decided, and **how it is decided**. Metadata only: no recommendation or rationale text. |
| Read access | Scoped office identity: its own office's rows. Jarvis and the auditor: all rows. anon / authenticated: nothing. Dormant, forged or refused tokens: nothing. Same filter as M2, using only M1's already-granted helpers, so the scoped roles' function allowlist is unchanged. |
| Decisions | **No new approval route.** An action approval is decided by the owner's existing Telegram tap (owner_messages, then `hq_commands.apply_decision`, then `hq_policy.decide_approval`), consumed once by the unchanged `authorize_action`. A money proposal is decided by `fz_owner_decide_office_proposal` (signed-in owner only, M2). The queue only shows them. |
| Expiry + cap | `fz_queue_expire()` (service path, every 15 min via pg_cron): one expiry rule for both types (pending past `expires_at` becomes `expired`), plus at most **5 pending action approvals per office per action** (the oldest extras are superseded and expired). Money proposals are already capped at insert (M2: 3 pending per office). |
| Audit | Every change `fz_queue_expire()` makes writes one audit_log row (from, to, reason). Every status change of a money proposal (executed, rejected, expired) writes one, via an AFTER UPDATE trigger on the M2 proposals table. Nothing is ever deleted. |
| Office wiring | `fz_prepare_office_payment()`: the office layer in front of the **unchanged** `prepare_payment()`, the one paid path that carries a venture. The office is the venture's office. It can only refuse (office not active, or available balance short); otherwise it returns exactly what `prepare_payment()` decides. Group ventures and no venture pass straight through. Service path only. |
| Feature flag | `hq_payments.prepare()` calls the office gate only when `FZ_OFFICE_SPEND_GATE=1` and the payment has a venture. **Default OFF** gives exactly today's call. |
| Telegram | `/approvals`, read-only, owner chat only: one line per pending item. It is not `/queue`, because Jarvis hands already owns `/queue` (its action queue). No approve or decline buttons were added: the existing approval messages keep their own buttons and handler, unchanged. |

## 2. Why this architecture

- **A view, not a new approvals table.** Both sources stay authoritative where their existing code reads and writes them (`authorize_action` consumes `approval_requests`; M2's functions own proposals). A copy would drift, and moving `approval_requests` would mean touching the protected approval flow. M3 adds **no table**, so the backup classification and the registry are unchanged.
- **Decision paths unchanged.** The two existing paths have different strength. A Telegram tap goes through the bot's service key and is checked by chat id. A money proposal needs the signed-in owner. A unified "approve anything" button would either weaken money decisions down to the Telegram path or need a change to the protected owner checks. Neither is acceptable, so the queue unifies **reading** and leaves **deciding** where it is already verified.
- **Expired is the safe state.** `authorize_action` consumes only `approved` and unexpired requests, and `decide_approval` only changes `pending` ones. So expiring or superseding a request can never grant anything; the worst case is that the owner is asked again.
- **The cap is enforced by expiry, not by a trigger on `approval_requests`.** A trigger on that table would change a protected approval path: today's `request_approval` would start failing. The money tables' trigger list is pinned by the tests.
- **The office gate wraps `prepare_payment`** instead of `reserve_spend`, because `prepare_payment` already reserves. Wrapping `reserve_spend` would reserve twice. The reservation carries the venture, so M2 stamps it to the venture's office automatically.

### Where I changed the brief

1. `/approvals` instead of `/queue`: `/queue` already exists (Jarvis hands).
2. **No Telegram approve or decline for money proposals.** They need the signed-in owner, and the Telegram handler is the weaker, service-key path. Action approvals already have approve buttons through the existing handler.
3. **The cap for action approvals is "supersede oldest" at expiry time**, not "refuse at insert" (see section 2).
4. **No AI-spend gating** (hq_llm is protected). That is an owner decision, listed below.

## 3. Classification

No new table. One view (`fz_approval_queue`, metadata of confidential approval tables): service_role and the three scoped roles have select, filtered by office as above; nobody else has anything. Functions `fz_queue_expire`, `fz_queue_audit_proposal` (trigger) and `fz_prepare_office_payment` are service path only (revoked from public, anon, authenticated and the fz roles; each refuses a scoped session even if granted by mistake).

## 4. Test evidence

`sqltests/approvals_kernel_check.sql` (replica step, and again after the rollback drill):
- **K1** money controls unchanged: the M2 fingerprint (332 rows: protected functions and ACLs, money-table triggers, contents and ACLs, `capital_snapshot`, and the `authorize_action` / `reserve_spend` decision matrix) is identical with M3, after rolling it back twice, and after re-applying it. `scripts/replica/run.sh` also compares it right before vs right after the migration.
- **K2** one queue holds both types, with office, requester, amount, risk, expiry, status and decision path; it is complete (rows = requests + proposals); no free text.
- **K3** each of two offices sees exactly its own rows, both types (non-vacuous); 6 refused, dormant or forged token shapes see nothing; Jarvis and the auditor see all; anon and authenticated are denied.
- **K4** for 5 identity shapes (office, Jarvis, auditor, dormant, forged `sub`), 9 attempts to approve, consume or modify all fail: update or delete a request, insert an approved request, update a proposal, update the view, call the owner decision, call expiry, call the payment gate, propose. With a grant added by mistake, expiry and the payment gate still refuse the scoped role. A scoped preview leaves an approved request approved. The M1 allowlist is unchanged; no M3 function is executable by anyone but the service path.
- **K5** decisions through the existing paths show in the queue: approved, then consumed once by `authorize_action` (`used`); the bot is refused on a money proposal; the owner executes (audited by the new trigger) and rejects (audited).
- **K6** an overdue request shows `expired` before the job runs, and `authorize_action` will not use it; the job expires it plus an overdue proposal and supersedes the 2 oldest of 7 same-office same-action requests (newest 5 kept); one audit row per change; nothing deleted; a second run changes nothing; the job is scheduled.
- **K7** payment gate: a dormant office and a $0 office are refused; over 3 modes x 5 amounts x (office, group, no venture) it matches `prepare_payment` exactly (12 allow points); an office never allows more; a real payment is reserved against the office and the owner is asked through the existing message; the money-table trigger list is unchanged; nothing unclassified or unregistered.
- **K8** on the state the checks left, the rollback changes no money control, deletes no request or proposal, and keeps the queue snapshot.
- M2's `office_money_check` and M1's `org_access_check` still pass unchanged in assertions (M2's test now rolls M3 back before rolling M2 back, because M3 reads M2's table).
- Mutation-checked: 14 mutants, all killed: view filter widened (2 ways), queue readable by anon, raw status instead of effective expiry, expiry or payment gate opened to scoped roles (refusal removed + grant), payment gate granted to office agents, payment gate without its dormant or balance check, expiry not audited, cap keeping the oldest, proposal audit trigger missing, a trigger added to approval_requests (caught by the before / after fingerprint), expiry deleting history. Two first survived (anon was still stopped by function privilege; the dormant office was also refused for being at $0), so the test now checks the table privilege directly and the exact dormant reason.
- `test_hq_approvals.py`: 8 unit tests (one line per item, empty / not installed, the module never writes or decides, `/approvals` registered and owner-only, flag off is today's call (and "0", "", "true", "yes" do not count as on), flag on routes venture payments to the office gate with the same arguments, flag on without a venture is unchanged, an office refusal is relayed). The full unit suite passes.

## 5. Risks

- **Action approvals can still pile up between expiry runs** (the cap is applied every 15 minutes, not at insert).
- **The Telegram tap remains the weaker owner check** (chat id plus service key) for action approvals, as it is today. Moving action approvals to the signed-in owner path is an owner decision (it touches the protected owner-identity checks).
- **AI spend is not office-gated** (hq_llm, protected).
- **Flag on means a dormant or unfunded office's payments are refused.** That is intended, but the owner should fund and activate the office before turning the flag on.
- If M3 is rolled back while the flag is on, office payments fail closed (the RPC is gone) until the flag is turned off.

## 6. Rollback

`psql -v ON_ERROR_STOP=1 -f ops/rollback_approvals_kernel.sql` (one transaction, idempotent, **before** `ops/rollback_office_money.sql`). It writes a snapshot of the whole queue into one audit_log row, unschedules the expiry job, and drops the view, the proposal audit trigger and the three functions. M3 owns no data, so nothing else changes. Set `FZ_OFFICE_SPEND_GATE` back to 0 first if it was on. The replica drill runs it twice, checks that M3 is gone, M2 is intact and one snapshot was kept, then re-applies everything and re-runs the sqltest.

## 7. Owner actions

1. Approve PRs #35 (M1), #36 (M2) and this one in order, then apply the three migrations in the release window.
2. When an office is active and funded and you want its payments checked against its balance, set `FZ_OFFICE_SPEND_GATE=1` in Railway Variables and redeploy. Leave it unset to keep today's behaviour.
3. Decide: gate AI spend per office (an hq_llm change)?
4. Decide: should action approvals require the signed-in owner (app) instead of the Telegram tap?

## 8. Next milestone (recommended)

**M4: First live office.** Activate FF Marketing or Donna with its manager token, fund it, turn the flag on in a release, move Jarvis's read paths onto its scoped token, and add app buttons for the owner decisions (activate, allocate, decide proposals, approve actions) so nothing needs the SQL editor.
