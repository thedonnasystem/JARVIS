# Mandatory checks: PR #16 @ 9bc6bfcfff6cd180ed3468bde4928e84631ea90f
Verdict: **REJECT**  (3 pass, 3 fail, 3 unverified, 3 n/a; 2 rule violation(s), 10 protected-control touch(es))
Base origin/overnight-build @ 11c1e2980632, merge-base e5575a972993. Engine 1.0 sha256 def9082dfa33643e. Generated 2026-11-16T02:12:55Z.

- **PASS** HEAD: Reviewed SHA is the PR's current head
  - evidence: PR #16 head.sha = 9bc6bfcfff6cd180ed3468bde4928e84631ea90f
  - evidence: PR state: open, draft: False
- **FAIL** (reject) CI: CI green on the exact head SHA
  - [reject] required check 'migrations' is in_progress, not completed
  - evidence: unit: success, check-run 133045398960 https://github.com/thedonnasystem/JARVIS/actions/runs/43789799936/job/133045398960
  - evidence: secret-scan: success, check-run 133045399205 https://github.com/thedonnasystem/JARVIS/actions/runs/43789799936/job/133045399205
- **UNVERIFIED** GATE-EVIDENCE: Full gate (scripts/gate.sh --strict) ran and passed in CI on this SHA
  - [info] the log of the CI job 'migrations' could not be read
- **FAIL** (owner_gate) PROTECTED: No protected control is touched or weakened
  - [owner_gate] PC-EXEC hq_backup_keep.py:61: executor registry / executor registration: 3 added line(s)
  - [owner_gate] PC-EXEC migrations/20261120_backup_redact_leak_paths_v1.sql:785: executor registry / executor registration: 4 added line(s)
  - [owner_gate] PC-PERM migrations/20261120_backup_redact_leak_paths_v1.sql:196: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 30 added line(s)
  - [owner_gate] PC-PERM migrations/20261120_leak_source_prevention_v1.sql:15: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 13 added line(s)
  - [owner_gate] PC-PERM migrations/20261120_redaction_denylist_v1.sql:137: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 9 added line(s)
  - [owner_gate] PC-PERM migrations/20261121_postlock_backup_identity_v1.sql:19: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 4 added line(s)
  - [owner_gate] PC-PERM migrations/20261122_postlock_backup_identity_v2.sql:28: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 3 added line(s)
  - [owner_gate] PC-GUARD scripts/acl_manifest.py: a lint / gate / guard tool is added
  - [owner_gate] PC-GUARD scripts/gate.sh: a lint / gate / guard tool is modified
  - [owner_gate] PC-GUARD scripts/lint_migrations.py: a lint / gate / guard tool is modified
  - evidence: diff e5575a972993..9bc6bfcfff6c: 49 file(s), 8411 added line(s), 278 removed line(s)
- **FAIL** (reject) LINT: Migrations follow the migration lint
  - [reject] scripts/lint_migrations.py failed on the head (exit 1)
  - [note] the head modifies this tool; the result above is from the BASE version (the head's own version was not executed)
  - evidence: exit 1 (base-ref copy of the tool, sha256 c785feacdd7a50ec)
  - evidence: ERROR: R3 20261112_lockdown_v1.sql must be the last entry in APPLY_ORDER.txt (last is 20261122_postlock_backup_identity_v2.sql); insert new migrations BEFORE it
  - evidence: lint_migrations: 1 error(s)
- **PASS** BUNDLE: dist/APPLY_ALL.sql was regenerated
  - evidence: exit 0 (base-ref copy of the tool, sha256 5ddd5c69e868b7da)
  - evidence: bundle current
- **NOT_APPLICABLE** DEPS: New dependencies have a licence / provenance entry and are pinned
  - [info] no dependency, lock, image or workflow file changed
- **UNVERIFIED** ACL: ACL manifest matches the database ACLs (no drift)
  - [info] a manifest exists but no CI evidence that it was compared with a database on this SHA (the engine itself never connects to a database)
  - evidence: manifest file(s) on head: ops/ACL_MANIFEST_public.tsv
- **NOT_APPLICABLE** LEDGER: Oversight ledger is append-only relative to the base
  - [info] no oversight ledger on the base or the head
- **PASS** PRODUCTION: Not a production deploy / production migration (owner-reserved)
  - evidence: labels: none
  - evidence: base: overnight-build
  - evidence: title: Close the client data leaks: source fixes + export redaction (Priority 1)
- **NOT_APPLICABLE** TEST-CLAIMS: Claimed test counts match what CI ran
  - [info] no parseable 'N tests' claim in the PR title/body
- **UNVERIFIED** INDEPENDENT-REVIEW: Independent review recorded for this exact head (reviewer is not the author)
  - [info] no review of 9bc6bfcfff6c is recorded in the ledger. Reviews exist for other heads by this author: 09008cc6e9a5, 387c7f230722. A new head needs a fresh independent review.

Owner decisions required (11):
- 6 migration file(s) change: applying them to production is a separate owner release authorization (merging does not apply them)
- PROTECTED: hq_backup_keep.py: executor registry / executor registration: 3 added line(s)
- PROTECTED: migrations/20261120_backup_redact_leak_paths_v1.sql: executor registry / executor registration: 4 added line(s)
- PROTECTED: migrations/20261120_backup_redact_leak_paths_v1.sql: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 30 added line(s)
- PROTECTED: migrations/20261120_leak_source_prevention_v1.sql: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 13 added line(s)
- PROTECTED: migrations/20261120_redaction_denylist_v1.sql: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 9 added line(s)
- PROTECTED: migrations/20261121_postlock_backup_identity_v1.sql: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 4 added line(s)
- PROTECTED: migrations/20261122_postlock_backup_identity_v2.sql: permissions model (grant, SECURITY DEFINER, policy, role, default privileges): 3 added line(s)
- PROTECTED: scripts/acl_manifest.py: a lint / gate / guard tool is added
- PROTECTED: scripts/gate.sh: a lint / gate / guard tool is modified
- PROTECTED: scripts/lint_migrations.py: a lint / gate / guard tool is modified

Not inspected by this engine:
- the head is not rebased on the base tip: diff taken from merge-base e5575a972993, base tip is 11c1e2980632; interaction with the commits in between was not inspected
- code behaviour, logic, design and test quality (this engine is mechanical; a human or agent reviewer must read the change)
- the database: no migration was applied and no ACL was read by this engine
- production (Supabase, Railway, Render): never contacted
- licence texts of dependencies (only the presence of a register entry is checked)

23 read-only command(s) recorded in the JSON (argv, exit code, sha256 of output).
This result can stop a change (REJECT). It cannot approve one: RECOMMEND_APPROVE is advice to the Owner and to an independent reviewer.
