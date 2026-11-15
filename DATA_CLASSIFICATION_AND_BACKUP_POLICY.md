# Data classification, off-site backup and consent — policy as built

Status: ENGINEERING POLICY IMPLEMENTED IN CODE (dev branch, migrations NOT applied to production). Not legal advice. Items marked OWNER/COUNSEL are decisions this document does not make.
Owner decisions this implements (Nov 2026): A consent log, B health terms in the sensitive-data detector, C no client lead PII in off-site backups, D backups only after exclusions are verified.

## 1. What leaves the database, and what never does

| Class | Meaning | Off-site backup |
|---|---|---|
| `public` | non-personal reference data (e.g. published model prices) | exported |
| `internal` | the owner's and the ventures' operating data | exported |
| `client_pii` | third-party personal data: leads, prospects, replies, setters, suppression list, every `ws_*` and `ffm_*` table, `client_workspaces` | **never exported** |
| `secret` | push keys and endpoints | **never exported** |
| unclassified | a table nobody has classified yet | **not exported** (fail closed) until classified in a migration |

Decided by `public.backup_export_policy()` (table NAMES only, never data). Rules, in order of strength:
1. **Deny always wins.** `ws_*`, `ffm_*`, `client_workspaces` are denied by name pattern whatever any list says.
2. **Foreign-key closure.** A table with a foreign key to a non-exported table is not exported (a restore would otherwise load rows that point at missing data).
3. **Column drift.** A table on the allow side that gains a column that looks like personal contact data (email, phone, name, address, payee, birth…) and is not on the reviewed exception list (`backup_pii_column_exceptions()`) is excluded until reviewed.
4. **Second lock in code.** `hq_backup.py` re-checks every table against its own pattern (`ALWAYS_EXCLUDE`) and refuses to write a file if one gets through. It also refuses to run at all if the database function is missing or returns an unexpected result; there is no built-in "export everything" fallback.

The schema (structure, no rows) of every table, excluded ones included, is in the backup so a restore rebuilds the empty tables. The manifest lists what was excluded and why.

## 2. What this does NOT protect (read this before relying on it)
- **The live database and the database provider's own backups still contain client data.** This policy governs only the encrypted off-site file. Provider backups follow the provider's retention.
- **Free-text in exported tables.** If a person types a lead's details into `memory`, `tasks`, `owner_messages`, `missions` or notes, that text is exported. The detector screens text written through the `ws_*` / `ffm_*` paths only.
- **Restore gap.** After a restore from an off-site file, every client table is EMPTY, including `contact_suppressions`. Before any outreach is ever enabled, the opt-out list must be restored from the provider backup. Never contact anyone from a restored database until that is done.
- **`BACKUP_KEY` / bucket policy** (rotation, who may read, retention) are OWNER decisions not made here. Backblaze is not activated and no key exists.
- Classification is a reviewed list. A mistake there (a client table labelled `internal` and with no suspicious column names) would be exported. The code lock in rule 4 covers the known client table names only. This is why a human review is required when a table is added.

## 3. Consent log (decision A)
- `ffm_consent_log` is append-only and immutable (trigger; `service_role` has no write grants). A withdrawal is a new row, never an update.
- `ffm_can_contact(lead, channel)` is default-deny. True only with a current express consent, or an implied consent inside an owner-set window (`ffm_set_implied_window`, owner-only; unset = implied consent not accepted). A withdrawal (channel or `all`), a suppression hit, a closed workspace, an unknown lead or channel give false. Withdrawal is final in v1.
- **It authorizes nothing.** A true answer is necessary, never sufficient, for outreach. FF Marketing stays dry-run (CHECK-constrained); `ffm_route_preview` now refuses a lead with no current consent.
- `evidence_ref` is a short pointer (form id, message id), screened like all `ffm_*` text. Not a place for conversations.
- **What counts as implied consent, and for how long: OWNER/COUNSEL.** No number is chosen in code. Whether the lead sources used actually give lawful consent (CASL in Canada, and any other jurisdiction) is a legal question this log records but cannot answer.

## 4. Erasure
`ffm_erase_lead` (owner-only): records a withdrawal for all channels, redacts name/email/phone/source/note on the lead, blanks consent `evidence_ref`, and keeps the metadata rows (basis, channel, times, lead uuid) so withdrawals survive without personal data. Because client PII is not in the off-site file, erasure has no external copy to chase for client data. Copies in provider backups expire under the provider's retention.

## 5. Sensitive-data detector, health terms (decision B)
`ws_sensitive_hits` gains a `health` category: a fail-closed screen with a long-stem substring list plus a short-word list with separator tolerance. **Limits (stated plainly):** regular-expression list, not a classifier. Misses misspellings, other languages, leetspeak, euphemisms and anything not listed. Refuses innocent text (listed false positives in `sqltests/ffm_consent_check.sql` section H; e.g. a substring can straddle a word boundary). It reduces accidental capture; it does not make health data lawful to hold, and no health data should be collected for FF Marketing at all.

## 6. Evidence this was verified (dev, scratch databases only)
- `scripts/backup_drill.sh`: real PostgREST-shaped calls against a scratch Postgres with the full migration set: encrypt, upload to a fake B2, restore with the read-only key, row-for-row compare. Check P1: no client table file in the archive and none of the seeded lead names, emails or phone numbers appear in any data file. Check P2: the manifest lists `leads` as excluded and the schema still rebuilds it. Restore reports client tables as "absent from backup, as required"; a client table present in a backup is reported as a policy violation.
- `sqltests/backup_exclude_check.sql`, `sqltests/ffm_consent_check.sql`, `test_hq_backup.py`, `test_restore_backup.py`.
- These are synthetic tests. They are not production proof; production proof requires applying the migrations under a separate release authorization and running the post-release checks.

## 7. Before any off-site backup is activated (all required)
1. Migrations `20261119_ffm_consent_v1` and `20261119_backup_exclude_client_pii_v1` applied to production under release authorization; `select public.backup_export_policy()` reviewed by the owner (every `exported` table is expected to hold no client data; `unclassified` should be empty).
2. Owner sets retention and who may hold `BACKUP_KEY`; key generated by the owner (`ops/generate_backup_key.html`), never by Claude.
3. Backblaze account, bucket and a write-only key (and a separate read-only restore key) created by the owner.
4. `ops/backup_activation_preflight.sh` passes (it includes a PII check), then one manual backup and one restore drill into a scratch database.

Rollback: `ops/rollback_ffm_consent_backup.sql` (drops the consent log — irreversible loss of consent history — and restores the previous functions; the old `backup_snapshot` exports client data, so no off-site backups while it is in effect).
