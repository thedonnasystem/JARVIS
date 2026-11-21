# Proposal: raise the CI `migrations` job timeout from 75 to 110 minutes (needs your authorization)

**What:** one line in `.github/workflows/tests.yml`. That path is on the never-edit list (category: judges), so this change is not applied anywhere.

```diff
diff --git a/.github/workflows/tests.yml b/.github/workflows/tests.yml
index 7b62a4c..6b1f2a4 100644
--- a/.github/workflows/tests.yml
+++ b/.github/workflows/tests.yml
@@ -66,7 +66,7 @@ jobs:
     # the full gate: everything in `unit` plus the replica run (migrations, e2e, integration, rollback drill), the generated
     # function manifest, and the backup drill when the branch has one. --strict: a skipped required step is a failure.
     runs-on: ubuntu-latest
-    timeout-minutes: 75   # the integrated gate (replica + backup drill with paged export) takes ~45-50 min on hosted runners now (was cancelled at 50 on 6cba407)
+    timeout-minutes: 110   # the integrated gate (replica + backup drill with paged export): ~60 min at M4, over 75 with the M5 drills (cancelled at 75 on 4ad594f); was cancelled at 50 on 6cba407
     services:
       postgres:
         image: postgres:16
```

**Why:**
- The `migrations` job runs the full strict gate: unit tests, replica, every migration's rollback drill, the manifests and the backup drill.
- Each Phase 1 milestone adds its own rollback drill and sqltests:
  - On M4 (b87fd5d) the job took 59 minutes and passed 9/9.
  - On M5 (4ad594f) it was still running at 75 minutes and was cancelled by the timeout. Nothing failed.
- So CI cannot report a result for M5 or anything stacked on it.
- The same commit passes the full local fresh-cluster `scripts/gate.sh --strict` 9/9 on PG16 (replica, manifest and backup included).

**Risk:** none to what is checked. No step is skipped or weakened; a hung job would only take longer to be cancelled.

**Alternative, if you prefer not to raise it:** split the job into two jobs, replica and backup drill, each under 75 minutes. That also edits `.github/workflows` and needs the same approval.

**To apply:** approve, and the one-line change goes in its own PR with your owner marker.
