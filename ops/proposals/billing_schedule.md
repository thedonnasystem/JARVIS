# Proposal: run Donna's billing once a day from the engine tick (owner decision)

`hq_engine.py` is protected (category money), so the build does not change it. Until you approve this, billing runs only when you send `/invoices bill donna` and `/invoices check donna`.

**The change: one line** in `tick_sync()`, right after the `hq_systems.run_due_checks()` block (`hq_engine.py`, line 1319 on this branch):

```diff
+    __import__("hq_invoices").run_due()   # owner proposal billing_schedule: once a day 09:00-10:00 Toronto; returns at once unless FZ_STRIPE_INVOICING=1; never raises
```

**What `hq_invoices.run_due()` does:**
- With invoicing off (`FZ_STRIPE_INVOICING` not `1`): returns immediately. There is no Stripe call and no database call.
- Otherwise, once a day in the 09:00 Toronto hour, for every office with an approved billing plan:
  1. `check_plans` runs first. A plan whose last invoice is uncollectible, or unpaid 7 days (`FZ_BILLING_GRACE_DAYS`) after its due date, is stopped as `past_due`, and you are told once.
  2. `bill_plans` then bills this period's invoice of each plan that is still approved:
     - only for the exact approved amount and interval;
     - once per period, enforced by the database;
     - with a Stripe Idempotency-Key per (plan, period) on create, item, finalize and send;
     - after re-checking Stripe for an existing invoice for that period.
- It catches every error, so a Stripe or database problem never stops the tick.

**Why one line, and `__import__`:** the engine stays free of a new top-level import, and a missing or broken `hq_invoices` cannot stop the engine at import time. `run_due` handles its own errors.

**Risk:** a once-a-day Stripe read per approved plan, and sends only of invoices you already approved through a plan. No refund, payout or transfer code exists.

**To apply:** approve. The line goes in its own PR with your owner marker (it touches a protected file). **To undo:** remove the line.
