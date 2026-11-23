# FENDEZY GROUP Phase 1, M6: Monitoring + shared brain

Status: built and tested on a scratch replica. Not applied to production. Stacked on M5 (`build/p1-m5-shared-services`).

## 1. What was built

### Monitoring
- **`fz_health_report()`** is read-only. It runs eight checks, each with status ok, warn or bad:

  | Check | What it reads |
  |---|---|
  | `ai_cap_day` | spend so far today against the company daily AI cap (`system_state.daily_spend_cap_cents`) |
  | `spend_week` | the weekly limit, from `capital_snapshot()` |
  | `kill_switch` | the kill switch and mode |
  | `job_backlog` | queued, overdue and stale-lease jobs |
  | `failed_jobs` | dead jobs in the last 24 hours |
  | `approval_backlog` | pending items in the M3 queue |
  | `audit_chain` | the M4 chain verify |
  | `security` | M4 standing findings, unexpected grants and definer changes |

  It only reads: the caps, the kill switch and the security functions are called, never changed.
- **`fz_health_check()`** is the scheduled check (`fz-health-check` cron job, every 10 minutes).
  - It sits behind **`fz_health_config.alerts_enabled`, which defaults to off**. While off, it does nothing.
  - When on, it alerts Jarvis on Telegram (`owner_messages`, kind `health`) **only when a check's status changes**, with one message per run that has changes.
  - Each change gets a dedupe key `health:<check>:<status>:<generation>`, which is unique, so no change alerts twice.
  - A new check that is ok is recorded silently.
  - Only the scheduler, a database session or the owner can run it. The service key cannot trigger alerts.
- **`fz_owner_set_health_alerts(on)`**: owner only, audited.
- **`/health`** (`hq_health.py`) is the owner's read-only view.

### Shared brain
- **`fz_brain_facts`** is append-only.
  - `office_id NULL` means a group-wide fact; otherwise the fact belongs to that office.
  - Each fact records topic, fact, source, confidence (0–1), provenance (json), created_by_office and created_by.
  - A fact is never edited or deleted. A new fact *supersedes* it, and the only change ever made to a row is setting `superseded_by`/`superseded_at` once.
- **Reads:** `fz_brain_read()` is the **only** read path. It returns active group facts plus the caller's **own** office facts, and nothing else. The table has no API privileges at all, not even for the service key.
  - A scoped identity reads its own office.
  - The service key and database sessions act for the group, so they read group facts only.
- **Writes:** `fz_brain_add()`.
  - A scoped identity writes to its own office.
  - The service key writes for an office it names (`p_office`), never for the group.
  - Group-wide facts come only from the owner or a database session (fully redacted), or from an approved promotion.
- **Promotion from office to group:**
  1. `fz_brain_propose_promotion()` creates `fz_brain_promotions`. It holds **only the redacted text**, made by the existing leak redaction (`backup_redact_text`, strict), and only allowlisted provenance keys: kind, source_table, source_id and url. Client fields such as `client_email` are dropped.
  2. The request appears in the **M3 approval queue**: `fz_approval_queue` gains a `brain_promotion` branch, office-scoped like the rest.
  3. The client-name context (`backup_redaction_context`) is reserved to the backup identity and database sessions (`backup_assert_reader`, protected). A request made by the bot or an office therefore starts at `redaction_level = 'patterns'`.
  4. The **full pass** (`fz_brain_redact_pending()`, run by the same cron job or by the owner) re-redacts it with the client-name context, and it can only ever strengthen.
  5. Approval requires `full`.
- **Who can decide:**
  - The owner: `fz_owner_decide_brain_promotion`, which runs the full pass first.
  - Jarvis: `fz_jarvis_decide_brain_promotion`, only if the owner switched `fz_brain_config.jarvis_may_approve` on (default **off**). Jarvis can never decide its own request, and never one without the full redaction.
  - Requests are decided once, expire after 7 days (an expired request is never approved), and every decision is audited.
- **`/brain [words]`** (`hq_brain.py`, report `fz_brain_report`): the owner searches group facts and sees per-office **counts** only, never another office's text. There is no model call, and `hq_llm` and its cap are untouched.

### M5 review LOWs folded in (M5 is frozen)
- **#6:** the M5 office stamp (`fz_service_stamp_office`) now ignores a caller-given `office_id` unless the caller is the owner or a database session. Otherwise the office is derived as before, else the group. This one condition is the only change. The M6 rollback restores the M5 function text exactly. Tested in sqltest H8, and H1 checks the restore.
- **#7:** the mission engine's live-mission cap (`create_mission`) now uses a complete, service-key read (`hq_missions._get_complete`), never a scoped read that could return fewer rows. Any other scoped read that returns fewer rows only means fewer rows are processed: no action is taken on an incomplete list. Tested in `test_hq_mission_scoped.py`, behind `FZ_SERVICES_SCOPED_READS=1`, and a mutant reverting it is killed.

### M6 review fixes (one push)
- **MED 1 (Jarvis self-approval).** The requester of a promotion is now derived from the caller's role, never from `p_by`:
  - an office identity: its own slug, `requested_via = scoped`;
  - the owner or a database session: `owner`;
  - the service key or any other bot caller: `jarvis`, `service`.

  `p_by` survives only as an unverified label in the audit row. Jarvis may decide only `scoped` requests. Office identities hold no grant yet (that is the owner decision on the M1 allowlist), so **the Jarvis approval path is unusable today and promotion is effectively owner-only**. It becomes usable only if the owner grants brain access to office identities and switches `jarvis_may_approve` on.
- **MED 2 (provenance).** `fz_brain_clean_provenance()` builds provenance for both promotions and owner-added group facts:
  - only allowlisted keys are kept (kind, source_table, source_id, url);
  - every value goes through the strict redaction (`fz_brain_redact`);
  - URLs lose their query string and fragment.
- **LOW 3 (flapping).** A status must hold for 2 consecutive runs before it alerts (a one-run flap never alerts), and each check alerts at most once per hour. A change inside the hour is recorded as `quiet`, not sent.
- **LOW 4 (cap day).** The AI cap day now uses the same Toronto-day boundary, and the same low-cost cap, as `reserve_llm_budget`.
- **#5 skipped, as asked.** Office-identity access to `fz_brain_read` stays an owner decision.

## 2. Why this architecture
- **Additive.** New tables and functions. The M3 queue view only gains a branch, and its decision paths are unchanged.
- **The never-edit list is untouched.** No change to the money tables or controls, the caps, kill switch, mode, `authorize_action`, `action_policy`, executors, the redaction functions or the backup-identity guard (the last two are only called). The money fingerprint is identical with M6, without it and after a re-apply.
- **Strict by default.** Alerts are off, Jarvis approval is off, and the scoped roles get no grant on any M6 function: the M1 allowlist (O8) is unchanged. Giving office identities their own brain access is an owner decision, a one-line grant listed in section 7. The sqltest proves the scoping with an in-transaction grant.
- **No direct table reads.** Office isolation does not depend on RLS policies anyone could later loosen. The single definer function is the boundary.

## 3. Classification
- The six tables are in the M1 registry: monitoring tables are internal; `fz_brain_facts` and `fz_brain_promotions` are confidential and office-scoped.
- In `backup_classification()` all six are `secret`, so they are not in the off-site export. Exporting brain facts needs reviewed redaction-spec rows (protected, owner).

## 4. Test evidence
- `sqltests/monitoring_brain_check.sql` (H1–H7, one transaction, rolled back):
  - **H1:** the money controls are identical with, without and re-applied. The rollback (run twice) leaves nothing behind, archives the data, restores the M3 view and the M5 classification exactly, and a re-apply brings the facts and the owner setting back.
  - **H2:** all eight checks are present and valid, the report writes nothing, the kill switch and dead jobs are reflected, and scoped roles are refused.
  - **H3:**
    - Alerts off does nothing.
    - The service key cannot run the check or switch it on, even with RLS bypassed and a mistaken grant.
    - With alerts on, the first run alerts exactly the non-ok checks. An unchanged status never alerts again.
    - Every flip and recovery alerts once with a new generation, there are no duplicate keys, and alerts are append-only.
  - **H4:**
    - Office A reads group facts plus A's facts, not B's, and B likewise.
    - The service key and group-scope Jarvis read group facts only.
    - There is no direct table read for anyone, and anon is refused even with a mistaken grant.
    - The service key cannot write group facts but can write for a named office. A scoped caller cannot write into another office.
    - LIKE wildcards are escaped.
  - **H5:**
    - Facts cannot be edited, deleted, truncated or "superseded plus edited".
    - Supersede works, the superseded fact is no longer read, another office cannot supersede it, and nothing is superseded twice.
  - **H6:**
    - Office B cannot propose A's fact.
    - The request holds no email, phone or client name, and client provenance fields are dropped.
    - It is in the M3 queue, office-scoped, and duplicates are refused.
    - The service key cannot decide as the owner. Jarvis cannot decide while the setting is off, cannot approve a pattern-only redaction, cannot run the redaction pass and cannot approve its own request.
    - The owner's approval promotes exactly the fully redacted text, so no client name reaches the group.
    - A request is decided once and never edited, the redaction can never be weakened, and an expired request is not approved.
  - **H7:** the owner report contains group facts plus per-office counts only.
- `scripts/replica/run.sh`: the M6 rollback drill (section 6). The money fingerprint is checked around the M6 migration. M6 is rolled back first wherever M5 is rolled back.
- `test_hq_health_brain.py` (4 tests):
  - the text output;
  - query trimming;
  - an AST check that the two modules import only `hq` (no `hq_llm`) and make exactly one call, a POST to their report RPC;
  - the commands are owner-only and in the menu.
- Mutation tests: 50 mutants (including the nine for the review fixes) (monitoring, alerts, dedupe, config guard, brain read/write/supersede, promotion, decisions, redaction strength, owner report, rollback / re-apply, money fingerprint, the Python modules, and the two folded-in M5 LOWs). All are killed. Mutant 0 is killed by the engine, because a STABLE function cannot write.

## 5. Risks
- **Requests made by an office or the bot are redacted at the strict pattern level** (often `[redacted:uncertain]`) until the full pass runs, up to 10 minutes later. The owner's approval always runs the full pass first. This follows from the protected backup-identity rule, not from M6.
- **The weekly figure comes from `capital_snapshot()`**, the existing money view. The daily AI figure counts model calls that are reserved or done today.
- **Alerts land in `owner_messages`**, so delivery is whatever already sends those to Telegram.

## 6. Rollback
Run `ops/rollback_monitoring_brain.sql`. It is idempotent and is the first of the Phase 1 rollbacks.
- It writes one audit_log export row and unschedules the cron job.
- It restores the M3 `fz_approval_queue` view exactly.
- It archives the six tables into `fz_archive`. The archive has no API privileges, and an older archive moves to `fz_archive_<timestamp>`.
- It drops the M6 functions and restores `backup_classification()` to the exact M5 text.

A re-apply restores the facts (with their supersede links), the promotions, the alerts and their state, and the owner settings.

## 7. Owner actions
- **Turn on health alerts:** `select public.fz_owner_set_health_alerts(true);`
- **Let Jarvis approve office promotions** (never its own): `select public.fz_owner_set_brain_jarvis_approval(true);`
- **Decide a promotion:** `select public.fz_owner_decide_brain_promotion('<id>', true|false);` The id is listed in `/approvals`.
- **Give office identities brain access** (changes the M1 allowlist, protected): `grant execute on function public.fz_brain_read(text, integer), public.fz_brain_add(text, text, text, numeric, jsonb, uuid, text, text), public.fz_brain_propose_promotion(uuid, text) to fz_office_agent;`
- **CI timeout** (separate): `ops/proposals/ci_timeout_110.md`.

## 8. Next milestone (recommended)
- An office template and its instances (in progress by the second builder) can write office knowledge through `fz_brain_add` with `p_office`.
