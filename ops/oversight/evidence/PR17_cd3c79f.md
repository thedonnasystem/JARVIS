# Mandatory checks: PR #17 @ cd3c79fb5d013fca8def8089e373d0a05ee8b256
Verdict: **REJECT**  (6 pass, 1 fail, 2 unverified, 3 n/a; 0 rule violation(s), 5 protected-control touch(es))
Base origin/overnight-build @ 11c1e2980632, merge-base 11c1e2980632. Engine 1.0 sha256 def9082dfa33643e. Generated 2026-11-16T02:12:58Z.

- **PASS** HEAD: Reviewed SHA is the PR's current head
  - evidence: PR #17 head.sha = cd3c79fb5d013fca8def8089e373d0a05ee8b256
  - evidence: PR state: open, draft: False
- **PASS** CI: CI green on the exact head SHA
  - evidence: unit: success, check-run 133040484843 https://github.com/thedonnasystem/JARVIS/actions/runs/43788206381/job/133040484843
  - evidence: migrations: success, check-run 133040485170 https://github.com/thedonnasystem/JARVIS/actions/runs/43788206381/job/133040485170
  - evidence: secret-scan: success, check-run 133040485180 https://github.com/thedonnasystem/JARVIS/actions/runs/43788206381/job/133040485180
- **PASS** GATE-EVIDENCE: Full gate (scripts/gate.sh --strict) ran and passed in CI on this SHA
  - evidence: appcheck: PASS
  - evidence: backup: PASS
  - evidence: bundle: PASS
  - evidence: lint: PASS
  - evidence: manifest: PASS
  - evidence: replica: PASS
- **FAIL** (owner_gate) PROTECTED: No protected control is touched or weakened
  - [owner_gate] PC-SPEND migrations/20261122_insurance_classifier_v1.sql:957: spend cap / spend gateway / financial limit ($3.30 per day cap, budgets): 2 added line(s)
  - [owner_gate] PC-SPEND ops/rollback_insurance_classifier.sql:16: spend cap / spend gateway / financial limit ($3.30 per day cap, budgets): 2 added line(s)
  - [owner_gate] PC-PERM migrations/20261122_insurance_classifier_v1.sql:49: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 44 added line(s)
  - [owner_gate] PC-PERM ops/rollback_insurance_classifier.sql:89: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 2 added line(s)
  - [owner_gate] PC-GUARD scripts/gate.sh: a lint / gate / guard tool is modified
  - evidence: diff 11c1e2980632..cd3c79fb5d01: 17 file(s), 4116 added line(s), 9 removed line(s)
- **PASS** LINT: Migrations follow the migration lint
  - evidence: exit 0 (base-ref copy of the tool, sha256 c785feacdd7a50ec)
  - evidence: lint_migrations: 0 error(s)
- **PASS** BUNDLE: dist/APPLY_ALL.sql was regenerated
  - evidence: exit 0 (base-ref copy of the tool, sha256 5ddd5c69e868b7da)
  - evidence: bundle current
- **NOT_APPLICABLE** DEPS: New dependencies have a licence / provenance entry and are pinned
  - [info] no dependency, lock, image or workflow file changed
- **UNVERIFIED** ACL: ACL manifest matches the database ACLs (no drift)
  - [info] migrations change but this head has no ops/ACL_MANIFEST*.tsv, so ACL drift cannot be checked mechanically
- **NOT_APPLICABLE** LEDGER: Oversight ledger is append-only relative to the base
  - [info] no oversight ledger on the base or the head
- **PASS** PRODUCTION: Not a production deploy / production migration (owner-reserved)
  - evidence: labels: none
  - evidence: base: overnight-build
  - evidence: title: Insurance content classification: approved product terms vs personal health information (priority 3)
- **NOT_APPLICABLE** TEST-CLAIMS: Claimed test counts match what CI ran
  - [info] no parseable 'N tests' claim in the PR title/body
- **UNVERIFIED** INDEPENDENT-REVIEW: Independent review recorded for this exact head (reviewer is not the author)
  - [info] no review of cd3c79fb5d01 is recorded in the ledger. A new head needs a fresh independent review.

Owner decisions required (6):
- 2 migration file(s) change: applying them to production is a separate owner release authorization (merging does not apply them)
- PROTECTED: migrations/20261122_insurance_classifier_v1.sql: spend cap / spend gateway / financial limit ($3.30 per day cap, budgets): 2 added line(s)
- PROTECTED: migrations/20261122_insurance_classifier_v1.sql: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 44 added line(s)
- PROTECTED: ops/rollback_insurance_classifier.sql: spend cap / spend gateway / financial limit ($3.30 per day cap, budgets): 2 added line(s)
- PROTECTED: ops/rollback_insurance_classifier.sql: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 2 added line(s)
- PROTECTED: scripts/gate.sh: a lint / gate / guard tool is modified

Not inspected by this engine:
- code behaviour, logic, design and test quality (this engine is mechanical; a human or agent reviewer must read the change)
- the database: no migration was applied and no ACL was read by this engine
- production (Supabase, Railway, Render): never contacted
- licence texts of dependencies (only the presence of a register entry is checked)

22 read-only command(s) recorded in the JSON (argv, exit code, sha256 of output).
This result can stop a change (REJECT). It cannot approve one: RECOMMEND_APPROVE is advice to the Owner and to an independent reviewer.
