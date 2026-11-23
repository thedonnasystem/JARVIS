# Proposal: protect the Donna Ops CASL and prohibited-action controls

Status: PROPOSAL. `ops/PROTECTED_PATHS.json` protects itself, so this PR does not edit it. The owner applies this change in a separate PR that he approves.

`hq_donna.py` is already locked by the `*.py` rule, and the migration is locked by `migrations/`.

Proposed additions:

## `legal_privacy` category

**`paths`:**
- `offices/donna_runners.json`: its `casl` block is the fixed footer, and its `research` block is the robots / allowlist policy.

**`sql`:**
- `text_problems`
- `donna_save_draft`
- `donna_add_prospect`
- `donna_owner_edit_draft`

## `jarvis_permissions` category

**`sql`:**
- `mission_actions`
- `donna_run_begin`
- `donna_check_action`
- `prohibited`

## `judges` category

**`paths`:**
- `sqltests/donna_ops_check.sql` and `test_hq_donna.py` are already covered by `sqltests/` and `test_*.py`, so no entry is needed.

## Why

These objects are the floor that stops Donna's agents from:
- contacting anyone without a consent basis;
- writing a message without the CASL elements;
- running a non-green or prohibited action.

A later self-edit must not be able to weaken them silently.
