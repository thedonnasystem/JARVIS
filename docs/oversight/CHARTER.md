# Independent Technical Oversight: charter

Status: PROPOSAL (draft PR, not merged, not active). Owner: Moe Alafandi (Chairman). Written 2026-11-16.
Nothing in this folder changes production, CI, branch protection, permissions or spend. Activation is an owner decision (section 9).

## 1. Purpose
A permanent function that does the technical review, risk, verification and approval-preparation work the Owner currently sends outside. It answers one question per change: **is this safe to move forward, and what exactly must the Owner decide?**

## 2. What it does
1. Inspects proposed code, architecture and integrations.
2. Reviews security, privacy, financial controls and permission boundaries.
3. Challenges coding agents' findings and claims.
4. Verifies test results against actual execution evidence (CI run on the exact commit, not a statement).
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

A REJECT is binding inside the workflow until the cause is fixed and re-reviewed, or the Owner overrules it in a signed decision. A recommendation to approve binds nobody.

## 4. Independence rules (enforceable form)
| # | Rule | How it is enforced today | Gap |
|---|---|---|---|
| I1 | Author is never the reviewer of the same change | `ledger.py` refuses an entry where reviewer id = author id; `mandatory_checks.py` INDEPENDENT-REVIEW fails on it and is UNVERIFIED when no review of the exact head exists | Ids are self-declared (section 8) |
| I2 | A new head needs a fresh review; a review of an older SHA does not carry over | Reviews are keyed by full 40-hex SHA; HEAD check fails on a stale SHA | none |
| I3 | A fresh, different reviewer each round | Runbook rule; reviewer id recorded per entry | Not mechanical yet |
| I4 | The oversight function is not the only reviewer of its own code | Any change under `ops/oversight/` (except ledger/evidence appends) or to this charter trips PC-OVERSIGHT (owner gate) | Needs CODEOWNERS entry (owner action OA-2) |
| I5 | It cannot approve its own permission changes | Same PC-OVERSIGHT gate; `owner_keys.json` is owner-only | Same |
| I6 | It cannot merge what it reviewed | The engine has no merge/push code path and refuses git write commands; process rule for agents | No separate credential (section 8) |
| I7 | It cannot bypass a security gate | Gate/CI/lint/CODEOWNERS/secret-scan weakening is a hard REJECT (PC-GATE, PC-LINT, PC-CODEOWNERS, PC-GITLEAKS) | Applies only once the check is required (OA-1) |
| I8 | It never fabricates evidence or claims to have read what it did not | Every check carries recorded commands (argv, exit code, output hash); a check that could not run is UNVERIFIED, never PASS; each report lists "not inspected" | Human-written parts rely on the reviewer's honesty |
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
- `ops/oversight/ledger/reviews.jsonl`: append-only, hash-chained. `ops/oversight/ledger.py verify` detects edits, deletions and reordering.
- An owner decision is recorded only as an `owner_decision` entry carrying an Ed25519 signature from a key in `ops/oversight/owner_keys.json`. That file is empty today, so **no owner decision can be recorded yet** and none has been. The oversight agent holds no key and cannot write "owner approved"; a hand-written line fails verification.
- Honest limits: a cut at the end of the file, or a full rewrite with recomputed hashes, is not visible from the file alone. Anchors: git history (the ledger on the base must be a prefix of the ledger on the head: LEDGER check), an expected head hash the Owner keeps, and the optional database mirror (`proposals/`).
- Imported entries (reviews done before this function existed) are marked `imported: true, re_verified: false` with the sha256 of the reviewer's report.

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
- There is **no branch protection** on any branch (DEPLOY_RUNBOOK.md, re-checked 2026-11-12), so nothing technically stops a merge that the oversight function rejected. Today the REJECT is a process rule.
- CODEOWNERS exists but is not enforced without "Require review from Code Owners", and a one-account repository cannot satisfy a second-person review anyway.
- The engine runs where it is started. Run by the author's own session it is still mechanical, but it is not independent.
- What IS real today: evidence is tied to exact commits; the engine never runs code from the change under review; UNVERIFIED cannot be turned into PASS; the ledger detects tampering; owner approval cannot be forged without the Owner's private key.

## 9. Owner decisions needed to make this real
| # | Decision | Options | Cost | Risk if not done |
|---|---|---|---|---|
| OD-1 | Separate reviewer identity | (a) second GitHub account (machine user) with read-only + "review" rights, used only by the oversight agent; (b) a GitHub App with checks:write only; (c) stay on one account | (a) free on a personal/free org, 10 min; (b) free, ~1 h setup; (c) none | (c): independence stays a convention; any agent can approve or merge as "you" |
| OD-2 | How you sign decisions | (a) Ed25519 key generated on your device, public key committed by you; (b) key held by the Telegram bot on Railway, decision by `/approve` command; (c) GitHub PR review from your personal account counts as the decision | (a) free, 5 min, you sign with one command; (b) small build, key sits on a server agents can redeploy; (c) free, needs OD-1 | Without one: no owner decision can be recorded; approvals stay in chat only |
| OD-3 | Branch protection on `overnight-build` and the Railway deploy branch | (a) require PR + passing `unit`, `migrations`, `secret-scan`, `oversight-check`, no force push; (b) deploy branch only; (c) none | free; a broken check can block a hotfix (you can override as admin) | (c): a rejected change can still be merged or deployed |
| OD-4 | Make `oversight-check` a CI job | (a) adopt `proposals/oversight-check.workflow.yml.txt`; (b) run it by hand per review | (a) free minutes on current plan, a workflow change (protected); (b) none | (b): depends on someone remembering |
| OD-5 | Database mirror of the ledger | (a) adopt the proposal migration in a later release; (b) file only | (a) one small table, a production migration | (b): the file's only anchor is git history |
| OD-6 | Read-only production access for oversight | (a) a read-only Postgres role and read-only Railway/Render tokens; (b) none: it reviews repository and CI only | (a) 30 min of your time | (b): live drift (functions, ACLs, deploys) is checked only when you run the verify SQL |
| OD-7 | Activate this charter | (a) approve after an independent review of PR "WS5"; (b) change; (c) reject | none | Until then this is a document |

Owner actions (only you can do them): OA-1 mark `oversight-check` as a required status; OA-2 add `/docs/oversight/` to CODEOWNERS (`/ops/` is already covered); OA-3 register your public key in `ops/oversight/owner_keys.json`.
