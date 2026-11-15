# Engineering hardening (Priority 5), Nov 15 2026

Nothing here touches application code, migrations, `dist/`, `webapp/`, `requirements.txt` or `Procfile`.
**Merging this PR into `overnight-build` does not change production**: Railway deploys only `claude/telegram-claude-bot-59nusk` and still builds from the unchanged root `requirements.txt`; the Render PWA publishes `webapp/` only, which is byte-identical. (Merging into `overnight-build` still triggers the Render no-content-change redeploy described in the merge policy.)

## 1. Hash-locked Python dependencies
| file | purpose |
|---|---|
| `requirements/runtime.in` | what `bot.py` / `hq_*.py` actually import (audited from `import` statements): anthropic, python-telegram-bot[job-queue], python-dotenv, claude-agent-sdk, psycopg2-binary, bitwarden-sdk, pywebpush, **cryptography** (imported by `hq_backup.py`, never declared before) |
| `requirements/runtime.lock` | fully pinned, `--generate-hashes`, universal (all platforms), Python >= 3.12 |
| `requirements/dev.in` / `dev.lock` | runtime + PyYAML (swarm hardening tests) + pip-audit; constrained to the runtime lock versions |

Regenerate (reviewed PR, show the lock diff): `uv pip compile requirements/runtime.in --universal --python-version 3.12 --generate-hashes --no-header -o requirements/runtime.lock` then the same for `dev.in` -> `dev.lock`. Install: `pip install --require-hashes -r requirements/runtime.lock`.

Verified on a clean Python 3.12.3 venv: `pip install --require-hashes -r requirements/dev.lock`, `pip check` clean, 671 unit tests OK, `build_bundle.sh --check` current, `pip-audit` on both locks: no known vulnerabilities.

**CI** (`unit`, `migrations`) now installs `requirements/dev.lock` with `--require-hashes`. Note this means CI tests the locked set, not what Railway resolves from the unpinned `requirements.txt` today.

### Switching Railway to the lock (NOT done; owner/release decision)
Railway builds the root `requirements.txt` (Procfile `worker: python3 bot.py`, no pyproject/Dockerfile). To switch, in a release PR on the deploy branch replace the root `requirements.txt` content with the hashed runtime lock (copy `requirements/runtime.lock` to `requirements.txt`; pip honours `--require-hashes` implicitly when any hash is present) and set `runtime.txt`/`.python-version` to 3.12 so the platform python matches the lock. Prove first: deploy to a staging service and run `/status`; the lock was generated for 3.12 and resolves the same versions the 2026-11-14 review saw (anthropic 2.8.0, claude-agent-sdk 0.2.182, python-telegram-bot 22.8, cryptography 50.0.2). Roll back by restoring the old `requirements.txt`.

### Flags
- **`bitwarden-sdk` is proprietary** (Bitwarden SDK License, internal use only; counsel open item). Kept, locked, not removed.
- `claude-agent-sdk` wheel bundles a proprietary ~365 MB `claude` binary (Anthropic terms).
- `http-ece` is sdist-only: the hash covers the source tarball, but pip still runs its `setup.py` and fetches build tools (setuptools) unhashed in an isolated build env. Residual risk until a wheel is prebuilt.
- `pywin32` appears in the universal lock under a `sys_platform == 'win32'` marker; never installed on Linux.

## 2. GitHub Actions
`actions/checkout` v4.4.0, `actions/setup-python` v5.6.0 pinned by full commit SHA with version comments (SHAs taken from `git ls-remote` tags, all lightweight tags so tag SHA = commit; each fetched and confirmed as a commit object). Workflow-level `permissions: contents: read`, `persist-credentials: false` on every checkout, `timeout-minutes`, per-ref `concurrency` with cancel-in-progress. `scripts/check_workflow_pins.py` (+ `scripts/test_check_workflow_pins.py`, run in the `unit` job and the gate) fails on a tag/branch/short-SHA action, a missing version comment, a missing top-level `permissions:`, or a checkout that keeps credentials.

## 3. Secret scanning
Job `secret-scan` (gitleaks 8.30.1 binary, sha256-verified in the workflow, no third-party action): full history of all fetched refs, plus the PR commit range. Config `.gitleaks.toml` = default rules + 7 allowlists, each an exact file path AND a line regex. Baseline full-history scan (207 commits, all branches): 16 raw findings, all `generic-api-key`, all classified synthetic/public (swarm hardening test constants and a throwaway probe log, two credential-shaped refusal tests, the documented-public Supabase publishable key in two webapp files, a minified vendored library). No real secret. With the config: 0 findings; a planted secret in a non-allowlisted file is still detected (negative control).

### 3a. Synthetic fixtures in closed-PR history: exact fingerprints, not a commit exception (2026-11-15)
`secret-scan` scans every fetched ref, including the head of closed PR #14 (`5828a5e4`, branch `build/consent-integrity`) and the history of open PR #15. Reproduced locally with gitleaks 8.30.1 (the CI pin): 9 findings, the same count as the CI log (231 commits), all `generic-api-key`, all synthetic test literals:
- 8 in commit `5828a5e4`: `'fixture-key-0123456789abcdefghijklmnop'` inserted into a scratch `ffm_secrets` table by `sqltests/{audit_paths,venture_generic,ffm_consent,venture_deals_replies,ffm_onboarding,inbox_needs_you,pending_signoff}_check.sql` and `scripts/replica/e2e.sql`.
- 1 in commit `15a69bc8` (PR #15 history): `sqltests/consent_review_fixes_check.sql:321`, a guessable phrase passed to `ffm_set_key` in test F6e to prove it is refused.

Fix: root `.gitleaksignore` with exactly those 9 fingerprints (`commit:file:rule:line`), each documented in `scripts/gitleaks_ignore_audit.json` (why synthetic, origin, review date). No `commits =` exception (PR #18's approach was rejected by the owner), no path/rule/directory allowlist added, `.gitleaks.toml` unchanged, the scan stays on for every other line of every commit.
Guard `scripts/check_gitleaks_ignore.py` (run in `unit` and at the start of `secret-scan`; tests in `scripts/test_check_gitleaks_ignore.py`) fails if: the fingerprint count or sha256 differs from the audit file, an entry has no documented audit record, a fingerprint is malformed or has a wildcard, `.gitleaks.toml` has `commits =`, `disabledRules`, `stopwords`, `targetRules`, `useDefault` is not true, or any allowlist is not `AND` of an anchored exact file path plus a line regex. To add a legitimate synthetic fixture: add the fingerprint, add its audit entry (why/origin/reviewed), update `count` and `sha256` (hash = sha256 of the sorted fingerprint lines joined by `\n` plus a trailing `\n`; the script prints the expected value on mismatch). The three files are CODEOWNERS-protected.
Evidence (scratch clone with all refs): without the file 9 findings, exit 1; with it 0 findings, exit 0, debug log shows 9 ignored fingerprints = 9 audited fixtures; removing one fingerprint brings back exactly that finding; a new real-looking key added to `sqltests/audit_paths_check.sql` in a new commit is detected; the exact fixture string added in a new commit (same file other line, and a new file) is detected; `origin/overnight-build..pr14` (the CI PR-range scan) is clean.
Limit: a fingerprint is bound to the commit hash. If PR #15 is rebased or amended, `15a69bc8` gets a new hash and the finding returns under a new fingerprint (review it, then replace the entry through the same audited process; merging instead of rebasing keeps the hash). Fingerprints do not match if the same literal is moved to a different line, which is intended.

## 4. Other
- `.github/dependabot.yml`: pip (root and `requirements/`) and github-actions, weekly, grouped. Dependabot cannot rewrite hashed locks; a bump PR is the cue to re-lock.
- `.github/CODEOWNERS`: migrations, dist bundle, ops, .github, requirements, Procfile, gitleaks config -> repo owner. Takes effect for blocking only if "Require review from Code Owners" is enabled (owner setting).
- Workflow `dependency-audit` (job `dependency-audit`, weekly + on lock changes): `pip-audit --strict` on both locks, blocking because currently clean.
- Required checks unchanged: `unit`, `migrations`. New, non-required: `secret-scan`, `dependency-audit`. Owner may add them to branch protection.
- Not done / needs owner: pre-commit gitleaks hook (local install), branch-protection settings, switching Railway to the lock, bitwarden counsel decision.
