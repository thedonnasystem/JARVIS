# Organization contract (`ops/org/divisions.json`)

The single machine-readable description of the company organization. Proposal: every division is dormant.
Design: `docs/org/ORG_ARCHITECTURE.md`. Readers: the HQ UI (WS2, demo data), the validator, the migration seed.

Stable shape (contract version 1.x; additive changes only, a breaking change bumps the major version):

| Path | Meaning |
|---|---|
| `contract_version` | semver of this file |
| `global.ai_daily_cap_cents` | company AI cap the envelopes must fit inside (330) |
| `global.lifecycle` | `dormant`, `staged`, `active` |
| `global.capability_catalog[]` | `id`, `tier`, `description`: the only capabilities a division can be given |
| `global.never_delegable_prefixes[]` | capabilities no division may ever hold |
| `jarvis` | role, `may`, `may_not` |
| `corporate_offices[]` | `id`, `name` of the nine existing office functions |
| `divisions[]` | one object per division, below |

Division object: `id`, `name`, `status`, `inferred` (true = not defined by the repo, owner decision), `note`, `evidence[]`,
`existing_refs` (venture / department slug or null), `charter` (`text`, `authored_by`, `owner_approved`), `objectives[]`,
`manager` (role profile, no agent exists), `team[]` (role skeleton, `agent_status: not_created`), `responsibilities[]`,
`delegated_permissions` (`default: deny`, `allow[]` of `capability`, `scope`, `status`), `budget` (all zero),
`kpis[]` (`id`, `name`, `unit`, `direction`, `source`, `target`), `mission_templates[]`, `isolation`.

For the UI: treat everything as display data. Show `status` as is (all `dormant`), show `inferred` and
`charter.owner_approved: false` honestly, and never offer an activate control: there is nothing to call.

Rules (enforced by `scripts/org_contract.py`, tested in `scripts/test_org_contract.py`, run by the gate step `scripts-tests`):
all divisions dormant, all budgets zero, proposals within the cap, allow-lists from the catalog only, nothing never-delegable,
templates within their division's allow-list, only Jarvis contacts the owner, no email or phone shapes anywhere in the file.

```
python3 scripts/org_contract.py                    # validate
python3 scripts/org_contract.py --check-migration  # also compare with the seed in migrations/20261123_org_divisions_v1.sql
```

Changing the division list after the migration is released needs a new migration (applied migrations are never edited).
