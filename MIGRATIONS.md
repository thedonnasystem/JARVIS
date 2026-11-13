# Migration convention (parallel workstreams)

Enforced by `scripts/lint_migrations.py` (part of `scripts/gate.sh` and CI). Rule ids below are the lint's.

## Rules
1. **One new file per stream/topic.** Name: `YYYYMMDD_<stream>_<topic>_vN.sql`, lowercase, e.g. `20261114_infra_alerts_v1.sql` (R2). The 28 files that predate this are grandfathered by an explicit list in the lint; never add to it.
2. **Never edit an applied (or merged) migration.** Anything that exists on `origin/overnight-build` is frozen: fix forward with a new file `..._v2.sql` (R6). Deleting or renaming is also an error. An exception needs an entry with a reason in `MODIFIED_ALLOWLIST` in the lint, and the owner's sign-off.
3. **Idempotent.** Safe to apply twice (`create or replace`, `if not exists`, guarded `do` blocks). The replica run applies everything twice.
4. **Every function you create gets an explicit REVOKE in the same file, after it** (R4):
   ```sql
   create or replace function public.my_fn(p_x text) returns int language sql security definer as $$ select 1 $$;
   revoke all on function public.my_fn(text) from public, anon, authenticated;
   grant execute on function public.my_fn(text) to service_role;
   ```
   Why: the lockdown migration only revokes functions that exist when it runs. A migration applied to production after it (production applies each new file once, not the bundle) leaves new functions executable by `anon`/`authenticated`; with a caller-supplied `p_by` that is a privilege hole. Overloads need one revoke each (arity is checked). Functions deliberately open to the app are the list inside `20261112_lockdown_v1.sql`; only those may be granted to `authenticated` (R5).
5. **Order.** List your file in `migrations/APPLY_ORDER.txt` **before** `20261112_lockdown_v1.sql`, which must stay last (R3). Every file must be listed exactly once, and every listed file must exist (R1). The two "already live" files (`missions_v1`, `brief_missions`) are the only documented exceptions.

## Parallel streams: who touches what
- A stream branch adds **its own migration file and one line in `APPLY_ORDER.txt`**. It does **not** run `scripts/build_bundle.sh` and does **not** commit `dist/APPLY_ALL.sql`.
- The **integration branch** (`overnight-build`) is the only place `dist/APPLY_ALL.sql` is rebuilt: after merging streams, run `scripts/build_bundle.sh` and commit the result. CI (`scripts/build_bundle.sh --check` inside the gate) fails if it is stale. Because it is generated, a conflict in it is never hand-resolved: take either side, then rebuild.
- `ops/EXPECTED_NEW_FUNCTIONS.txt` is also generated (see DEV_GATE.md): regenerate on the integration branch after merging, never merge it by hand.

## Resolving conflicts
- **`APPLY_ORDER.txt`**: keep both sides' new lines, in date order (ties: alphabetical), lockdown last. Then `python3 scripts/lint_migrations.py`.
- **Two streams touch the same function**: the later migration in the order wins at apply time. Do not edit the earlier file; the second stream rebases onto the first and its file re-creates the function from the first's body plus its change.
- **`dist/APPLY_ALL.sql`**: `git checkout --theirs dist/APPLY_ALL.sql` (or ours), then `scripts/build_bundle.sh`.
- **`ops/EXPECTED_NEW_FUNCTIONS.txt`**: run the replica, then `scripts/function_manifest.py --write`.
- **Lint says R6 on a file you did not touch**: your branch is behind; merge/rebase `origin/overnight-build` first.

## Checks before you push
`scripts/gate.sh` (see DEV_GATE.md). Quick loop while writing: `python3 scripts/lint_migrations.py`.
