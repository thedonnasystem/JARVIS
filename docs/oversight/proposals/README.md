# Proposals (not applied, not active)
Files here are text for the Owner to decide on. None is in `.github/workflows/` or `migrations/`, so nothing runs, is linted as a migration, or is bundled into `dist/APPLY_ALL.sql`.
- `oversight-check.workflow.yml.txt`: a CI job that runs the mandatory checks on every PR (owner decision OD-4, owner action OA-1).
- `20261124_oversight_review_ledger_v1.sql.txt`: optional database mirror of the review ledger (owner decision OD-5). The `20261123_` prefix is reserved by the WS3 org-architecture branch; this file was coordinated by name only and has not been checked against that branch's schema.
