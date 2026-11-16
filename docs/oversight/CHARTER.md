# Independent Technical Oversight: charter

Status: PROPOSAL (draft PR, not merged, not active). Owner: Moe Alafandi (Chairman). Written 2026-11-16, revised the same day after the independent review RV28 (3 blockers, 10 should-fix, 10 notes; section 10 lists what was changed and what is still open).
Nothing in this folder changes production, CI, branch protection, permissions or spend. Activation is an owner decision (section 9).

## 1. Purpose
A permanent function that does the technical review, risk, verification and approval-preparation work the Owner currently sends outside. It answers one question per change: **is this safe to move forward, and what exactly must the Owner decide?**

## 2. What it does
1. Inspects proposed code, architecture and integrations.
2. Reviews security, privacy, financial controls and permission boundaries.
3. Challenges coding agents' findings and claims.
4. Checks test evidence on the exact commit: CI job conclusions, the gate summary, and the unittest result lines CI printed (ran / failed / skipped). It compares counts claimed in the PR text with the counts CI printed. It does not re-run tests and it cannot see the result of a suite whose count CI does not print (section 10, G7).
5. Looks for regressions, vulnerabilities, compatibility and architecture weaknesses.
6. Evaluates open-source projects, dependencies, licences and supply chain.
7. Reviews new business systems and workflows before activation.
8. Writes plain-English decision reports for the Owner (`REVIEW_TEMPLATE.md`).
9. Recommends APPROVE / REJECT / NEEDS MORE WORK.
10. Keeps the audit trail of reviews, findings, evidence and owner decisions (`ops/oversight/ledger/`).

## 3. Authority
| It MAY | It MAY NOT |
|---|---|
| Stop a change from progressing internally when a mandatory check fails (REJECT) | Authorise a production deploy or production migration |
| Recommend approval to the Owner | Commit money, change spend caps, credits or limits |
| Ask for more evidence, a re-run, a narrower change | Grant a security exception or accept a risk on the Owner's behalf |
| Read the repository, CI results and (read-only, when authorised) production information | Merge, push to a protected branch, or deploy anything |
| Record its reviews in the ledger | Record, imply or paraphrase an owner approval |

A REJECT is binding inside the workflow (as a process rule: section 8) until the cause is fixed and re-reviewed on a new head. What the Owner can release with a signed decision, and what he cannot:
| Finding class | Meaning | Released by a signed owner decision for that exact head? |
|---|---|---|
| `owner_gate` | a protected control is touched | Yes, in the checks the decision names (`PROTECTED`, `PRODUCTION`) |
| `human_review` | the engine cannot see what the change does (dynamic SQL, SQL that does not tokenise) | Yes, same way: the Owner accepts it on a reviewer's reading |
| `reject` | a mandatory rule is broken (CI red, RLS disabled, secret, test deleted, ...) | No. Fix it. |
| `owner_only` | the owner key list changed | No. Only the Owner can make that change, by committing it himself |
A recommendation to approve binds nobody.

## 4. Independence rules (enforceable form)
"Enforced" below means: the engine or the ledger code refuses or reports it, and a test in `scripts/test_oversight_*.py` proves that. It does not mean GitHub stops a merge (section 8).
| # | Rule | How it is enforced today | Gap |
|---|---|---|---|
| I1 | Author is never the reviewer of the same change | `ledger.py` refuses an entry where reviewer id = author id (case and spacing ignored). INDEPENDENT-REVIEW also compares the reviewer id with `--author`, the PR's GitHub login and the git author/committer names and e-mails of the PR's commits; it is UNVERIFIED when no author identity is available | Ids are self-declared labels; all agents share one GitHub login and often one git identity (section 8) |
| I2 | A new head needs a fresh review; a review of an older SHA does not carry over | Reviews are keyed by full 40-hex SHA; HEAD fails on a stale SHA. An APPROVE counts only with evidence (ref + sha256 per item). A REJECT / NEEDS_MORE_WORK on a head stays open: a later APPROVE closes it only if it is for the same head, has evidence, is not by the author and names the rejection in `supersedes` | The evidence items are hashes the reviewer supplies; the engine does not open them. The local copy of the trusted base is compared with GitHub's only when GitHub is consulted (check BASE) |
| I3 | A fresh, different reviewer each round | Runbook rule; reviewer id recorded per entry | Not mechanical |
| I4 | The oversight function is not the only reviewer of its own code | Any change under `ops/oversight/` (except appends to `ledger/reviews.jsonl` and `evidence/*.json|md`), to this charter or to `scripts/test_oversight_*.py` trips PC-OVERSIGHT (owner gate). The engine reports ENGINE = UNVERIFIED unless it is byte-identical to the copy on the trusted branch | Needs CODEOWNERS entry for `/docs/oversight/` and `/scripts/` (owner action OA-2). The operator can still run a modified engine and ignore the ENGINE line |
| I5 | It cannot approve its own permission changes | Same PC-OVERSIGHT gate. `owner_keys.json` is class `owner_only`: no ledger entry releases it, and keys count only when read from the trusted branch | The trusted branch is itself writable by every agent (no branch protection: section 8) |
| I6 | It cannot merge what it reviewed | The engine has no merge/push code path. Its git wrapper for the reviewed repository allows seven read sub-commands (`rev-parse`, `merge-base`, `diff`, `show`, `log`, `ls-tree`, `grep`) and refuses everything else (tested). It does run `git init`, `config`, `update-ref` and `checkout`, but only inside its own temp directory, never in the reviewed repository (tested: refs, status, config and object store unchanged) | No separate credential (section 8); the wrapper is the engine's own code, not an OS sandbox |
| I7 | It cannot bypass a security gate | Removing, renaming, moving or gutting a gate script, CI workflow, guard tool, control test, `.gitleaks.toml`, `dependabot.yml`; removing a gate step, CI job, lint rule; adding a lint exception or a broad secret-scan suppression; removing or reordering CODEOWNERS entries: class reject. Any other change to those files: owner gate | Applies only once the check is required (OA-1). Line and statement rules have known blind spots (section 10) |
| I8 | It never fabricates evidence or claims to have read what it did not | Each run records every command (argv, exit code, sha256 of output) in one list for the run. A check that could not run is UNVERIFIED, never PASS; each report lists "not inspected" | Outputs are hashed, not stored, and CI logs expire, so an old result cannot be re-verified later. Commands are not attributed per check. Human-written parts rely on the reviewer's honesty |
| I9 | Read-only production unless specifically authorised | The engine contacts GitHub (GET only) and local git; no database, Railway, Render or Supabase call exists in it | Credential scope (section 8) |
| I10 | Not subordinate to the agent it reviews | Reviews are commissioned by the Owner or the coordinator, never by the author; the author cannot close a finding (only a re-review can) | Organisational, not technical |

## 5. Owner-reserved decisions (the function prepares, the Owner decides)
- Production deploys (Railway deploy branch; any commit that publishes `webapp/` through Render) and production migrations.
- Spend, caps and credits: the $3.30/day company cap, agent caps, mission budgets, model credits, any new paid service.
- Kill switch, dry-run / live mode, sending real email, text or calls; outreach of any kind.
- The permissions model: roles, grants, RLS, SECURITY DEFINER surface, the ACL manifest, API keys and tokens.
- Executor registration (the registry stays empty until the Owner adds a row).
- Security exceptions: secret-scan suppressions, lint exceptions, skipped gate steps, CODEOWNERS or branch-protection changes.
- Backblaze B2 and any other paid or off-site infrastructure; anything that moves client data off-site.
- Anything touching client PII, consent, suppression lists or data retention.
- Legal and licence questions (for example the Bitwarden SDK licence).
- Activation of a new division, business system or workflow.
- This charter, the mandatory-check rules and the owner key list.

## 6. Audit trail
- `ops/oversight/ledger/reviews.jsonl`: append-only, hash-chained, one ASCII JSON line per entry. `ops/oversight/ledger.py verify` detects edits, deletions in the middle, reordering, inserted entries, duplicate ids and malformed content. Appending takes a file lock and re-verifies the file after writing.
- An owner decision is recorded only as an `owner_decision` entry with an Ed25519 signature. The signature covers every field of the entry; unknown fields are refused; the decision names one recorded review or mechanical check by id **and by its hash**, and must be for the same head SHA. It cannot be replayed onto another review, another head or a rewritten ledger.
- Which keys count: `ops/oversight/owner_keys.json` **as it is on the trusted branch** (`overnight-build`). A key added on a PR head or in a working tree does not count. That file is empty today, so **no owner decision can be recorded yet** and none has been.
- Key revocation: a key is never deleted. It gets `"revoked_after_seq": N`; decisions it signed up to ledger line N still verify, it can sign nothing after N. Deleting a key that signed an entry makes the ledger fail verification (by design: fail closed).
- The engine reads owner decisions (check OWNER-DECISION) and releases findings only as section 3 says.
- Honest limits:
  - A cut at the end of the file, or a full rewrite with recomputed hashes, is not visible from the file alone. Anchors: the ledger on the trusted branch must be a byte prefix of the ledger the engine is given and of the ledger on the PR head (LEDGER check, `verify --base-file`); an expected head hash the Owner keeps (`verify --expect-head`); the optional database mirror (`proposals/`).
  - The trusted branch is not protected today, so whoever can push there can rewrite the anchor too. Only the Owner's own copy of the head hash is outside the agents' reach.
  - The private key's safety is entirely the Owner's. Whoever holds it is the Owner as far as the ledger can tell.
  - `ts` is the writer's clock, checked for format only; it can be back-dated. Order is given by `seq`, not by `ts`.
  - A hand-edited line makes the ledger refuse all further appends. Repair without rewriting history: RUNBOOK section 7.
- Imported entries (reviews done before this function existed) are marked `imported: true, re_verified: false` with the sha256 of the reviewer's report. An imported APPROVE never satisfies INDEPENDENT-REVIEW.

## 7. Escalation
| Situation | Path |
|---|---|
| Mandatory check FAIL, class reject | Back to the author with the finding; re-review on the new head by a different reviewer |
| Protected control touched (owner gate) | Owner decision report; nothing moves until the Owner decides |
| Author disputes a finding | Second independent reviewer; if still disputed, both positions go to the Owner in one report |
| Evidence missing (UNVERIFIED) | NEEDS MORE WORK; the report says exactly what is missing |
| Suspected secret, data leak or control bypass already merged or live | Immediate owner alert (Telegram), recommendation to pause (`/kill` is the Owner's call), incident entry in the ledger |
| The oversight function itself is wrong (false alarm, missed defect) | Recorded as a finding against the function; rule change goes through PC-OVERSIGHT like any other protected change |

## 8. What this environment can and cannot enforce (plain statement)
- All agents in this engagement run in one session with the **same GitHub account (`thedonnasystem`) and the same token**. GitHub therefore cannot tell author from reviewer, and "who merged" cannot be attributed to the Owner. Reviewer and author ids in the ledger are self-declared labels.
- There is **no branch protection** on any branch (DEPLOY_RUNBOOK.md, re-checked 2026-11-12), so nothing technically stops a merge that the oversight function rejected, and nothing stops a push to the branch the engine trusts. Today the REJECT is a process rule.
- CODEOWNERS exists but is not enforced without "Require review from Code Owners", and a one-account repository cannot satisfy a second-person review anyway.
- The engine runs where it is started. Run by the author's own session it is still mechanical, but it is not independent, and the operator can run an edited copy (the ENGINE check says so in the result; it cannot stop it).
- What IS real today, each with a test:
  - evidence is tied to exact commits;
  - the engine never executes a file from the change under review, and never a file from a base the PR or the caller chose: tools come only from `refs/remotes/origin/overnight-build`, a name fixed in the engine;
  - the engine never writes inside the reviewed repository and never through a symlink; a symlink or a path-escaping `APPLY_ORDER.txt` entry in the tool inputs stops the tools before they start;
  - UNVERIFIED cannot be turned into PASS;
  - the ledger detects the tampering listed in section 6;
  - an owner decision cannot be forged, extended or replayed without the Owner's private key, **provided** the key list on the trusted branch is the Owner's (see the two bullets on branch protection above).

## 9. Owner decisions needed to make this real
| # | Decision | Options | Cost | Risk if not done |
|---|---|---|---|---|
| OD-1 | Separate reviewer identity | (a) second GitHub account (machine user) with read-only + "review" rights, used only by the oversight agent; (b) a GitHub App with checks:write only; (c) stay on one account | (a) free on a personal/free org, 10 min; (b) free, ~1 h setup; (c) none | (c): independence stays a convention; any agent can approve or merge as "you" |
| OD-2 | How you sign decisions | (a) Ed25519 key generated on your device, public key committed by you; (b) key held by the Telegram bot on Railway, decision by `/approve` command; (c) GitHub PR review from your personal account counts as the decision | (a) free, 5 min, you sign with one command; (b) small build, key sits on a server agents can redeploy; (c) free, needs OD-1 | Without one: no owner decision can be recorded; approvals stay in chat only |
| OD-3 | Branch protection on `overnight-build` and the Railway deploy branch | (a) require PR + passing `unit`, `migrations`, `secret-scan`, `oversight-check`, no force push; (b) deploy branch only; (c) none | free; a broken check can block a hotfix (you can override as admin) | (c): a rejected change can still be merged or deployed |
| OD-4 | Make `oversight-check` a CI job | (a) adopt `proposals/oversight-check.workflow.yml.txt`; (b) run it by hand per review | (a) free minutes on current plan, a workflow change (protected); (b) none | (b): depends on someone remembering |
| OD-5 | Database mirror of the ledger | (a) adopt the proposal migration in a later release; (b) file only | (a) one small table, a production migration | (b): the file's only anchor is git history |
| OD-6 | Read-only production access for oversight | (a) a read-only Postgres role and read-only Railway/Render tokens; (b) none: it reviews repository and CI only | (a) 30 min of your time | (b): live drift (functions, ACLs, deploys) is checked only when you run the verify SQL |
| OD-7 | Activate this charter | (a) approve after an independent re-review of PR "WS5" at its new head; (b) change; (c) reject | none | Until then this is a document |
| OD-8 | Where the ledger of record lives | (a) on `overnight-build`, each review entry pushed there by its own commit; (b) a dedicated branch (for example `oversight-ledger`) that only the reviewer identity may push to; (c) file in the PR only | (a) every entry is a commit on the branch Render watches; (b) a small engine change (protected) and OD-1; (c) none | (c): the CI job can never see a review of the head it is judging, so it stays red |

Owner actions (only you can do them): OA-1 mark `oversight-check` as a required status; OA-2 add `/docs/oversight/` and `/scripts/` to CODEOWNERS (`/ops/` is already covered); OA-3 register your public key in `ops/oversight/owner_keys.json` and commit that change yourself (RUNBOOK section 6).

## 10. What is enforced and what is not (after review RV28)
Closed in this revision (each has tests named after the finding in `scripts/test_oversight_checks.py` / `scripts/test_oversight_ledger.py`):
| Finding | Now |
|---|---|
| B1 author-chosen base | One fixed trusted ref. `--base` and the PR base are never used to pick tools or the diff; another base is reported (BASE = UNVERIFIED). A tag or branch named `origin/overnight-build` cannot shadow it |
| B2 symlink write-through | The engine writes only new files inside its own temp directory (exclusive create, no symlink followed); the head is materialised with symlinks disabled; tools are refused when a link is in their inputs |
| B3 rename bypass | The diff is taken without rename folding: a moved protected file is a deletion at the old path (reject) and every line is scanned at the new path |
| S1 line-rule evasions | See the table below |
| S2 owner decisions | Section 6 |
| S3 ledger robustness | ASCII canonical form, strict types, file lock, verify-after-write, documented repair |
| S4 review override | I2 |
| S5 / S6 test evidence, own evidence files | TEST-RESULTS (new) and TEST-CLAIMS; `ops/oversight/evidence/*.json|md` and `ledger/reviews.jsonl` are data (secrets still scanned) |
| S7 bundle check | Runs in the engine's temp directory with `TMPDIR` inside it; APPLY_ORDER entries must be plain file names |
| S8 / S9 proposals | Rewritten; both still never run (workflow) / never applied (SQL) |

Still open. A clean result must not be read as covering any of these:
| # | Gap | Why it is open | What covers it meanwhile |
|---|---|---|---|
| G1 | Control reached under a name the rules do not know (a new cap column, a renamed function, a new mode value read from a variable) | Rules match names and statement shapes, not meaning | Human review; the ACL manifest and SQL control tests in the gate |
| G2 | SQL built at run time. In migrations any `execute <text>`, `quote_ident`, `dblink`, `prepare` is flagged `human_review` (PROTECTED = UNVERIFIED), so it is never a silent pass, but the engine cannot say what it does. `U&` escapes are rejected outright | Would need to execute the code | A person reads the statement; owner release |
| G3 | SQL sent from Python (string building, f-strings, ORM calls), `importlib` / `exec`, shell commands in scripts | No static rule sees through it | Human review; `test_no_bypass.py`, `test_spend_paths.py` |
| G4 | A test weakened without deleting lines: an assertion changed to something always true, a fixture loosened, an early `return` | Not detectable by line rules. Detected: deletion, move, gutting (10+ net lines and 30% of the file), skip / xfail / `.only` markers, any removed line in a control test | Human review of test diffs |
| G5 | A test-named file used by runtime code is detected only when a non-test `.py` file imports it (`import`, `from`, `import_module`, `__import__` with a literal name) or the Procfile names it. Started through a shell command or a computed name, it is not seen. Files under `/tests/`, `/fixtures/`, `docs/`, `*.md`, `*.txt` are not scanned by the name rules | Dynamic imports and data files read at run time cannot be traced | Human review |
| G6 | CODEOWNERS: a NEW broader pattern placed last overrides earlier ones. Reported as an owner gate with that warning, not judged | Needs path-pattern evaluation | Owner reads the entry |
| G7 | Test evidence: only `Ran N tests` blocks that CI prints are read (today: the repo unit suite, 671 on the base). Counts of `scripts/test_*.py`, `sqltests/`, `webtests/` are not printed by the gate, so a claim about them is UNVERIFIED, and their pass/fail is known only through the gate step result | The gate prints step results, not counts | GATE-EVIDENCE (step PASS/FAIL) and the CI job conclusion |
| G8 | CI trust: check-runs are accepted when GitHub Actions produced them for this SHA under the required job name. Which workflow file produced them is not checked, and a PR can edit the workflow it runs under | GitHub API limits; `pull_request` semantics | PC-WORKFLOW / PC-GATE findings on any workflow change; branch protection (OD-3) |
| G9 | A forged `GATE SUMMARY` printed by code under test: two blocks are rejected; one forged block that replaces the real one would need the real one suppressed, which fails the job | Log text is the only evidence | CI job conclusion |
| G10 | Dependencies: licence texts are not read; transitive packages are UNVERIFIED, not judged; install-time code is not analysed; a CDN script with an integrity hash is an owner gate, not verified | Out of mechanical reach | Supply-chain checklist in the runbook |
| G11 | The verdict word REJECT covers both a broken rule and a missing owner decision. `verdict_reason` and the summary line now say which, but the exit code (10) is the same | Exit codes 0/10/20 are a fixed interface | Read the summary line |
| G12 | Identity (I1), branch protection, enforcement of the REJECT, protection of the trusted branch and of the key list | Owner decisions OD-1, OD-3, OA-1..3 | Process rule |
| G13 | Git internals not exercised: filter drivers and LFS are disabled by environment for the engine's checkout, not tested against a hostile `.gitattributes`; `.gitattributes` changes are an owner gate | No safe way to test here | Owner gate |
| G14 | The workflow proposal has never run; the SQL proposal has never been applied. In the SQL mirror the writer role can still poison the table with a fabricated but well-formed first entry | No Actions run and no database were available | Stated in both files |
