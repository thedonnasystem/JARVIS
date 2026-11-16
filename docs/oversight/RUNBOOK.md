# Oversight review runbook
Status: PROPOSAL (see `CHARTER.md`). Tools: `ops/oversight/mandatory_checks.py`, `ops/oversight/ledger.py`. Tests: `scripts/test_oversight_*.py` (run by the existing `scripts-tests` gate step).

## 1. Commissioning a review (inputs; a review without them is not started)
- PR number and the **full 40-hex head SHA** (a branch name can move).
- Author id (agent or person) and what the author claims: scope, tests run, counts, known limits.
- What is being asked: merge to a dev branch / release package / activation of a system.
- Who commissions: the Owner or the coordinator. Never the author.

## 2. Reviewer rotation
- Reviewer id ≠ author id. Nobody reviews code they wrote or fixed.
- A fresh reviewer for every round: the reviewer of round N does not review round N+1 of the same PR (they may hand over notes).
- Workstreams WS2 and WS3 are reviewed by the QA agent; the oversight function checks that the review exists for the exact head and records it.
- The oversight function's own code (this PR and later changes) is reviewed by a different agent and is never merged by the function.
- A reviewer who needs a fix made asks the author; a reviewer who fixes it becomes an author and loses the review.

## 3. Steps
1. `git fetch origin <branch>`; confirm `git ls-remote origin refs/heads/<branch>` equals the SHA you were given. If not, stop and ask for the new head.
2. Mechanical checks (read-only, about 5 seconds):
   `python3 ops/oversight/mandatory_checks.py --pr <n> --sha <sha> --author <author id> --out ops/oversight/evidence/PR<n>_<sha7>.json --summary ops/oversight/evidence/PR<n>_<sha7>.md`
   Exit 0 RECOMMEND_APPROVE, 10 REJECT, 20 NEEDS_MORE_WORK; anything else is an engine error (nothing verified).
3. Read every FAIL and UNVERIFIED. For each protected-control touch decide: real change to the control, or name match only (say which, with the line).
4. Human/agent review of the change itself (section 4). Run tests only on your own scratch database cluster and port; `scripts/gate.sh --strict` wipes the `public` schema of its target. Never the shared 5432/5433, never production.
5. Write the owner report from `REVIEW_TEMPLATE.md`.
6. Record: `python3 ops/oversight/ledger.py append --entry <entry.json>` (type `review`; evidence items with sha256). Then `ledger.py verify`.
7. Hand the report to the Owner. The reviewer does not merge.
8. Owner decision: recorded only by the Owner (`ledger.py owner-payload` prints what to sign; `append-owner` stores the signed entry). Until a key is registered, the decision lives in the Owner's message and the ledger says nothing about it.

## 4. Standing checklist
### Security
- [ ] No secret, token, key or real credential in the diff or history (`secret-scan` green on the SHA; PC-SECRET clean).
- [ ] `.gitleaksignore` / `.gitleaks.toml`: only exact audited fingerprints, no commit-wide, path-wide or rule-wide allowance.
- [ ] Gate steps, CI jobs, lint rules, CODEOWNERS: none removed or loosened. A PR that changes a rule its own change would break is called out by name.
- [ ] New SQL functions: `search_path` pinned, revoked from `public, anon, authenticated` (lint R4/R5), SECURITY DEFINER justified.
- [ ] Inputs from the web, email, leads and LLM output are treated as untrusted (no SQL built from them, no shell, no path).
### Privacy
- [ ] Client PII never leaves the system: not in logs, audit detail, error text, backups to off-site storage, PR text or test fixtures.
- [ ] Free text fails closed: a free-text column is blanked or strictly redacted on export unless proven safe; an unknown column is refused.
- [ ] Consent and suppression: an opt-out can only be added, never silently removed; restore paths close outreach.
- [ ] Erasure reaches copies (audit, ledger notes, backups policy).
### Financial controls
- [ ] The $3.30/day company cap (`system_state.daily_spend_cap_cents` = 330) is untouched; no new default raises it.
- [ ] Every model or paid call goes through the spend gateway (`reserve_llm_budget` → settle); `test_spend_paths.py` and `test_no_bypass.py` unchanged or stricter.
- [ ] Kill switch and dry-run are checked before any side effect; `mode = 'live'` stays impossible without an owner decision.
- [ ] No new paid service, plan or credit; executor registry stays empty.
### Permissions
- [ ] Default deny: new tables have RLS on and no policy unless one is needed; nothing granted to `anon` / `authenticated` outside the lockdown's keep-open list.
- [ ] Least privilege for `service_role`: read where read is enough; owner-only actions check the owner inside the function.
- [ ] ACL manifest regenerated and equal to the replica's catalogue (gate step `manifest`); new objects are in it.
- [ ] No role, default-privilege or ownership change without an owner decision.
### Supply chain
- [ ] Python: only `requirements/*.lock` with `--require-hashes`; every new package has a licence/provenance entry (`ops/oversight/dependency_provenance.json`).
- [ ] Actions pinned by full commit SHA; container images pinned by digest; npm exact versions with a lockfile.
- [ ] Licence read from the published artifact, not from a README. Copyleft and proprietary items listed.
- [ ] Open question carried on every review until closed: **Bitwarden SDK** is under a proprietary licence (internal use only). Counsel/owner decision outstanding.
- [ ] Install-time code execution (sdist builds, postinstall scripts) named.
### Business-system activation (a division, venture, workflow or integration going live)
- [ ] An oversight review of the exact version exists and is not REJECT.
- [ ] What it can spend, send, sign or publish, and what stops it (cap, kill switch, approval step).
- [ ] What data it touches and where that data goes.
- [ ] Dry-run evidence from this system, stated as synthetic; what was never exercised.
- [ ] Rollback or off switch, tested.
- [ ] Owner gate: no division or system activates without the review **and** a recorded owner decision.

## 5. What the engine checks (ids as they appear in results)
| Check | FAIL when | UNVERIFIED when |
|---|---|---|
| HEAD | reviewed SHA is not the PR's current head | PR not readable |
| CI | `unit`, `migrations` or `secret-scan` missing, not completed or not success on that SHA; any other check failed | check-runs not readable |
| GATE-EVIDENCE | a required gate step missing, skipped or failed in the CI log; verdict line not "GATE PASSED" | log not readable |
| PROTECTED | spend, kill switch, executor registry, dry-run, permissions, secrets, gitleaks, lint, gate, workflow, CODEOWNERS, deploy surface, control tests or the oversight function itself touched (owner gate) or weakened (reject) | commit not in the local repository |
| LINT / BUNDLE | the **base** copy of the tool fails on a clean clone of the head | tool absent on the base |
| DEPS | new direct dependency without a licence entry; unhashed lock entry; unpinned image/action; npm range | new transitive package without an entry |
| ACL | CI gate step `manifest` not passing | no manifest on the branch, or no CI evidence |
| TEST-CLAIMS | the PR text states test counts and none equals what CI ran | no log |
| INDEPENDENT-REVIEW | reviewer = author; or the latest independent review of this head is REJECT / NEEDS_MORE_WORK | no review of this exact head; approval is only an imported report |
| PRODUCTION | production/deploy/migration label or title; base is the Railway deploy branch; `webapp/` change into `overnight-build` | PR not readable |
| LEDGER | ledger on the head is not an extension of the ledger on the base | - |

Known limits of the engine (do not read a clean result as more than it is):
- Line patterns match names, not meaning: expect owner-gate hits on harmless mentions (false alarms) and misses on a control reached through a new name or a multi-line statement.
- It does not apply migrations, read a database, or look at production.
- It trusts GitHub's check-run results and logs; it does not re-run CI.
- TEST-CLAIMS reads only "N tests" phrases in the PR title/body.
- Identities are labels until OD-1 (separate reviewer account) is decided.
