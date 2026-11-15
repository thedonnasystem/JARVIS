Evidence for the PR #15 independent-review fixes (scratch databases only, nothing applied to production).
- 01_OLD_code_sql_regressions.log: sqltests/consent_review_fixes_check.sql run against a database built from the OLD head 6b1dcb2 (F1b forged capture succeeds, F2b claim succeeds with the gate closed, F3a service_role can insert into app_owners, F4a trunk variants differ, F6 key policy missing).
- 02_OLD_code_python_regressions.log: the new Python tests run against the OLD hq_mail / hq_venture_ops / hq_consent / restore_backup (23 of 79 fail or error).
- 03/04: the same tests against the fixed code (all pass).
