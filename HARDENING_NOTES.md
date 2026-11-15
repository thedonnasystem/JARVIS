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

## 4. Other
- `.github/dependabot.yml`: pip (root and `requirements/`) and github-actions, weekly, grouped. Dependabot cannot rewrite hashed locks; a bump PR is the cue to re-lock.
- `.github/CODEOWNERS`: migrations, dist bundle, ops, .github, requirements, Procfile, gitleaks config -> repo owner. Takes effect for blocking only if "Require review from Code Owners" is enabled (owner setting).
- Workflow `dependency-audit` (job `dependency-audit`, weekly + on lock changes): `pip-audit --strict` on both locks, blocking because currently clean.
- Required checks unchanged: `unit`, `migrations`. New, non-required: `secret-scan`, `dependency-audit`. Owner may add them to branch protection.
- Not done / needs owner: pre-commit gitleaks hook (local install), branch-protection settings, switching Railway to the lock, bitwarden counsel decision.
