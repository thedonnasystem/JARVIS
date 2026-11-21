# FENDEZY GROUP Phase 1, M7: Office operating system (template + 8 offices)

Branch `build/p1-m7-offices`, stacked on `build/p1-m5-shared-services` (M5, unmerged). Migration `migrations/20261203_office_os_v1.sql`, rollback `ops/rollback_office_os.sql`,
proof `sqltests/office_os_check.sql`, `test_hq_office_os.py`, `scripts/test_check_integrations.py`; owner statements `ops/OWNER_OFFICE_OS.sql`; connections `ops/CONNECT_SESSION_CHECKLIST.md`.
Nothing is live until the owner applies M1..M5 and M7. Every office stays DORMANT until the owner activates it.

## 1. What was built

| Piece | What it is |
|---|---|
| Profiles | `fz_office_os.fz_office_profiles`: one row per office (8, seeded dormant, no manager): mission, allowed agent roles, allowed integrations (keys of `scripts/check_integrations.py`), autonomy defaults (green / yellow / red / prohibited action lists), data class, status `dormant / prepared / active`, manager (NULL until the owner appoints one), activation approval, advisory activation rank (Donna 1, Wolf Squad 2, FF Marketing 3). |
| Owner controls | `office_os_set_manager`, `office_os_activate`, `office_os_deactivate`: signed-in owner only (`is_app_owner()`). |
| Activation | Two calls around ONE approval: the first (manager required) inserts an `approval_requests` item (`office_activate`, `office:<slug>`, 3-day expiry) plus the Telegram approval message, so it shows in the M3 queue and `/approvals`; the office is `prepared` (M1 still dormant, M2 still refuses spend). The owner taps Approve. The second call (manager still required) checks THAT request is approved, unexpired and matching, then sets M1 active through the unchanged `fz_owner_set_office_status`. Rejected / expired: back to dormant. |
| One at a time | The function refuses while another office is prepared, and a unique partial index on the table allows at most one prepared row. A check constraint forbids a prepared or active office without a manager. |
| Status | `office_os_status(office | null)` (service path): profile + M1 status + drift flag + approval state + M2 available balance. Telegram `/office <name>` (owner only; plain `/office` is unchanged). |
| Agents | `offices/TEMPLATE.json` (rules, prompt header) + `offices/<slug>.json` (3-4 core agents per office, one per allowed role, small model tier). `hq_office_os.system_prompt()` joins them with the profile. |
| Shared brain | `hq_office_os.brain_facts()`: group facts + own office only, behind `FZ_BRAIN_FACTS=1` (default off: no request at all). Coded against M6's `fz_brain_facts` with an `office_id` column; the filter is in the request AND re-checked per row. |
| Integrations | `scripts/check_integrations.py`: 27 integrations, presence of env var names only, never a value. |

## 2. Why this architecture

- **Profiles in their own schema, not `public`.** A public table must be in the M1 registry and in `backup_classification()` (a protected backup object). In `fz_office_os` with no privilege for any API role it needs neither, and nothing can read it except the four functions. Cost: not in the off-site export; a restore re-seeds the template dormant (fail closed), and a rollback + re-apply restores manager appointments from `fz_archive`.
- **Function names `office_os_*`, not `fz_*`.** The M1 rollback drill (scripts/replica/run.sh) asserts no public `fz_*` function survives it; M7 has no structural dependency on M1..M5 (late-bound plpgsql, no views, no grants to the fz roles), so it survives every other layer's rollback without editing their protected drills.
- **M1 stays the authority for status.** Activation calls M1's own owner function; the M2 gate keeps refusing anything not active in M1. M7 adds the manager and approval steps in front; `office_os_status` flags drift if someone changes M1 directly.
- **No grants to scoped roles.** The M1/M2 tests pin each scoped role's function allowlist. `office_os_status` still refuses a scoped caller for any office but its own if a grant is ever added by mistake (tested).
- **No budgets.** The profile has no money field. Offices draw on need through M2 (`fz_owner_allocate`, office gate).

### Where I changed the brief

1. `fz_office_activate` is `office_os_activate` (naming: see above).
2. "Creates an M3 approval item": M3 has no table (it is a view), so the item is an `approval_requests` row + the Telegram message, exactly how the existing approval flow works. It is never consumed or edited by M7.
3. Autonomy tiers are declarative defaults (shown in `/office` and in every agent prompt). Enforcement stays the unchanged `authorize_action` + M1 office policy; wiring the prohibited lists into `fz_set_office_policy` at activation is a next step.
4. `/office <name>` extends the existing `/office` (which already existed) instead of a new command.

## 3. Test evidence

`sqltests/office_os_check.sql` (run by the replica step; one rolled-back transaction):
- **O1** money fingerprint identical with M7, after its rollback (twice) and after re-apply; nothing left; all 8 profiles archived intact; one export record; no API role reaches the archive; the manager survives rollback + re-apply.
- **O2** 8 profiles = the 8 M1 offices (same ids), all dormant, no manager, M1 all dormant, integration keys valid, no action in two tiers, activation order Donna / Wolf Squad / FF Marketing.
- **O3** no API role has usage on the schema or any table privilege; only service_role executes the functions; the bot cannot read or write the table.
- **O4** set-manager / activate / deactivate refused for the bot, a session without the owner uid and a scoped token; nothing changed.
- **O5** activation without a manager refused, no approval created; the table refuses an active office without a manager; bad labels / unknown office refused.
- **O6** all 8 dormant offices refused by the M2 gate (two of them funded).
- **O7** prepared: approval item + Telegram message + M3 queue row; prepared office still cannot spend; pending does not activate; a second office is refused (function AND index); a forged approved request does not count; the bot cannot finish; the owner finishes: M1 active, audited, idempotent, the gate no longer refuses as dormant; the manager cannot be removed from an active office.
- **O8** rejected and expired approvals return the office to dormant; it still cannot spend.
- **O9** office A cannot read office B: no privilege at all; with a mistaken grant the function serves Donna's token Donna only (non-vacuous), refuses B, all, a dormant identity and anon.
- **O10** status for one / all offices, unknown office, drift. **O11** deactivate. **O12** nothing unregistered or unclassified.
- Mutation-checked: 41 mutants (30 SQL incl. rollback, 11 Python), all killed. Two first survived (a scoped grant placed before the revoke loop: equivalent, moved to the end of the file; a prompt role check masked by a missing agent file: test strengthened), one Python survivor was a stale-bytecode artefact (rerun with `PYTHONDONTWRITEBYTECODE=1`).

## 4. Risks

- The owner can still set an office active directly with M1's `fz_owner_set_office_status`, skipping the manager step; `/office` shows it as DRIFT.
- Profiles are not in the off-site export (see 2).
- Jarvis hands call FF Marketing's division `ffm`; the M1 office slug is `ff-marketing` (`/connect ... ffm`).
- The M6 brain interface is assumed (`fz_brain_facts.office_id`). With another shape the read returns nothing (fail closed) until aligned.

## 5. Rollback

`psql -v ON_ERROR_STOP=1 -f ops/rollback_office_os.sql` (one transaction, idempotent; FIRST of the Phase 1 rollbacks, though order does not matter). It writes one audit_log export row, moves the profile table (rows intact) into `fz_archive` (an older archive moves to `fz_archive_<timestamp>`), drops the four functions and the empty schema. It does not change any M1 office status.

## 6. Next step

Owner: run the connect session, then appoint Donna's manager and activate Donna. Build: apply each office's prohibited list through `fz_set_office_policy` at activation, and wire office agents to the scoped office token once M6 lands.
