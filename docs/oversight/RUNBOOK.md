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
1. `git fetch origin <branch> overnight-build`; confirm `git ls-remote origin refs/heads/<branch>` equals the SHA you were given. If not, stop and ask for the new head.
2. Mechanical checks (read-only, about 10 seconds). Run the engine **from a checkout of `overnight-build`**, not from the branch under review (otherwise check ENGINE is UNVERIFIED):
   `python3 ops/oversight/mandatory_checks.py --pr <n> --sha <sha> --author <author id> --out ops/oversight/evidence/PR<n>_<sha7>.json --summary ops/oversight/evidence/PR<n>_<sha7>.md`
   Exit 0 RECOMMEND_APPROVE, 10 REJECT, 20 NEEDS_MORE_WORK; anything else is an engine error (nothing verified).
   There is no base to choose: the engine only compares with `refs/remotes/origin/overnight-build`. `--base` with anything else is refused and reported. A PR that targets another branch gets BASE = UNVERIFIED.
3. Read every FAIL and UNVERIFIED. For each protected-control touch decide: real change to the control, or name match only (say which, with the line).
4. Human/agent review of the change itself (section 4). Run tests only on your own scratch database cluster and port; `scripts/gate.sh --strict` wipes the `public` schema of its target. Never the shared 5432/5433, never production.
5. Write the owner report from `REVIEW_TEMPLATE.md`.
6. Record: `python3 ops/oversight/ledger.py append --entry <entry.json>` (type `review`; every evidence item needs a `ref` and the `sha256` of what you looked at: an APPROVE without evidence does not count). Then `ledger.py verify`.
   If an earlier review of the **same head** is REJECT or NEEDS_MORE_WORK, your APPROVE closes it only when it lists that entry's id in `"supersedes": [...]`. Normally a rejection is answered by a new head, not by a second opinion on the old one.
7. Hand the report to the Owner. The reviewer does not merge.
8. Owner decision: recorded only by the Owner (section 6). Until a key is registered on `overnight-build`, the decision lives in the Owner's message and the ledger says nothing about it.

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
| BASE | - | the PR targets a branch other than `overnight-build`; `--base` named another ref; the local copy of `overnight-build` is missing or not GitHub's current tip; GitHub not consulted |
| ENGINE | - | the running `mandatory_checks.py` / `ledger.py` are not byte-identical to the copies on `overnight-build` (always the case until this function is merged there) |
| CI | `unit`, `migrations` or `secret-scan` (from GitHub Actions) missing, not completed or not success on that SHA; any other check failed | check-runs not readable |
| GATE-EVIDENCE | a required gate step missing, skipped or failed in the CI log; verdict line not "GATE PASSED"; more than one GATE SUMMARY block | log not readable |
| TEST-RESULTS | a unittest run in the CI log ended FAILED | a run has skipped tests (`OK (skipped=N)`), no result line, zero tests; a job's log was not read |
| TEST-CLAIMS | - | the PR text states a test count that matches no count CI printed (N/A when the PR text states no count) |
| PROTECTED | a protected control is touched (owner gate), weakened (reject), or the owner key list changed (owner only). See the classes below | dynamic SQL or SQL that does not tokenise in a migration; commit not in the local repository |
| LINT / BUNDLE | the **trusted-base** copy of the tool fails on the head; a symlink or submodule under `scripts/`, `migrations/`, `dist/`; an `APPLY_ORDER.txt` entry that is not a plain file name | tool absent on the trusted base |
| DEPS | new direct dependency without a licence entry; a requirement line that changes the package source (other index, URL, VCS, path, include); unhashed lock entry; unpinned image / action (workflows and `.github/actions/`); npm range, tag or URL | new transitive package without an entry |
| ACL | CI gate step `manifest` not passing | no manifest on the branch, or no CI evidence |
| INDEPENDENT-REVIEW | reviewer = author (by label, `--author`, PR login or git identity); an open REJECT / NEEDS_MORE_WORK on this head | no review of this exact head; approval without evidence; approval is only an imported report; no author identity available; ledger not verifying or not an extension of the ledger on `overnight-build` |
| PRODUCTION | production/deploy/migration label or title; base is the Railway deploy branch; `webapp/` change into `overnight-build` | PR not readable |
| LEDGER | ledger on the head is not an extension of the ledger at the merge-base (edited, cut, moved, deleted) | - |
| OWNER-DECISION | the Owner's latest signed decision for this head is `reject` | - (N/A when there is no decision; PASS when an `approve` released findings) |

PROTECTED rule ids: PC-SPEND, PC-KILL, PC-EXEC, PC-EXEC-WRITE, PC-DRYRUN, PC-STATE, PC-OUTREACH, PC-PERM, PC-PERM-OPEN, PC-PERM-RELAX, PC-PERM-REMOVED, PC-DYNSQL, PC-OBFUSCATION, PC-UNPARSED, PC-SECRET, PC-SYMLINK, PC-SUBMODULE, PC-GITATTR, PC-GUARD, PC-GATE, PC-LINT, PC-WORKFLOW, PC-DEPENDABOT, PC-GITHUB, PC-GITLEAKS, PC-CODEOWNERS, PC-TESTS, PC-EXTERNAL, PC-DEPLOY, PC-OVERSIGHT, PC-OWNER-KEYS.

Known limits of the engine (do not read a clean result as more than it is). The full list is CHARTER section 10; the ones a reviewer meets every day:
- Rules match names and statement shapes, not meaning: expect owner-gate hits on harmless mentions (false alarms), and misses on a control reached through a new name, through SQL sent from Python, or through a test weakened without deleting lines.
- Dynamic SQL in a migration is never a pass: it is `human_review` and somebody has to read the statement.
- It does not apply migrations, read a database, or look at production.
- It trusts GitHub's check-run results and logs; it does not re-run CI. It sees only the test counts CI prints (the repo unit suite).
- Identities are labels until OD-1 (separate reviewer account) is decided.
- REJECT with reason OWNER_DECISION_REQUIRED means no rule is broken; REJECT with RULE_BROKEN means one is. Same exit code (10).

## 6. Owner signing procedure (plain steps; nothing secret is ever typed into a chat, a PR or this repository)
One-time setup, on your own computer:
1. Make the key: `openssl genpkey -algorithm ed25519 -out owner_ed25519.pem`. This file is the private key. Keep it only on your device (a password manager attachment is fine). Never paste it anywhere, never give it to an agent.
2. Print the public key: `openssl pkey -in owner_ed25519.pem -pubout -outform DER | tail -c 32 | base64`. The 44-character result is public and safe to share.
3. Put it in `ops/oversight/owner_keys.json` on `overnight-build`: `{"keys": [{"key_id": "owner-1", "ed25519_public_b64": "<the 44 characters>"}]}`. **Commit and push this change yourself** from your own GitHub login. An agent must not do it for you: the engine treats any change to this file as owner-only, and a key counts only once it is on `overnight-build`.

For each decision:
1. You get a review report naming a ledger entry id (for example `MC-PR28_ab12cd3-...`) and the full head SHA.
2. Anyone runs: `python3 ops/oversight/ledger.py owner-payload --review-id <id> --sha <40-hex head> --decision approve --releases PROTECTED --key-id owner-1 --text "<your decision in one sentence>"`.
   It prints `entry_without_signature` (read it: it is exactly what you are signing, including the head SHA and what is released) and `payload_to_sign_b64`. `--decision` is `approve`, `reject` or `defer`. `--releases` is `PROTECTED`, `PRODUCTION`, both, or left out. It never releases a broken rule.
3. On your computer: `echo '<payload_to_sign_b64>' | base64 -d > payload.bin` then `openssl pkeyutl -sign -inkey owner_ed25519.pem -rawin -in payload.bin | base64 -w0` (on macOS: `| base64`). The output is the signature. It is not secret.
4. Add `"signature": "<that output>"` to the `entry_without_signature` object, save it as `signed.json`, and run `python3 ops/oversight/ledger.py append-owner --entry signed.json`. It refuses anything that does not verify. Commit the ledger.
This flow was run end to end with a throwaway key on 2026-11-16 (OpenSSL 3.0.13); it has not been run by the Owner.

If a key is lost or exposed: do not delete it. Add `"revoked_after_seq": <number of lines in the ledger now>` to its entry and add a new key with a new `key_id`. Past decisions keep verifying; the old key can sign nothing new. Commit that change yourself.

## 7. When the ledger does not verify (repair without rewriting history)
`ledger.py append` refuses to write to a ledger that fails `verify`. Never edit, reorder or delete a line to "fix" it.
- **The broken lines are not on `overnight-build` yet** (local or PR-only): put the file back to the trusted copy, `git show origin/overnight-build:ops/oversight/ledger/reviews.jsonl > ops/oversight/ledger/reviews.jsonl`, run `verify`, then record the lost valid entries again with `append` (they get new seq numbers; say in each entry's `note` that it is a re-entry). Nothing that was anchored changes.
- **A broken line is already on `overnight-build`**: this is an incident, and the Owner decides. Procedure: (1) copy the file byte for byte to `ops/oversight/ledger/sealed/reviews-<UTC date>.jsonl` and note its `sha256sum`; (2) start a new `reviews.jsonl` whose first entry is `{"type": "continuation", "id": "CONT-<date>", "sealed_file": "<that path>", "sealed_sha256": "<the hash>", "reason": "<what happened, who decided>"}` via `ledger.py append`; (3) the PR that does this fails the LEDGER check and trips PC-OVERSIGHT on purpose: only the Owner can merge it. The sealed file stays in the repository unchanged; history is not rewritten, it is closed and continued.
- A ledger that fails because a key was deleted from `owner_keys.json`: restore the key entry and revoke it instead (section 6).
