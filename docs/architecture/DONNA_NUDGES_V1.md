# Donna Nudges v1

**Job:** no deal goes cold because the owner's next step slipped. Read-only.

`public.donna_stuck_deals(p_limit)` (migration 20261213, service path, works while Donna is dormant) lists every Donna lead waiting on the owner, oldest first:

| kind | when | the one command that moves it |
|---|---|---|
| audit_no_proposal | booked more than a day ago, no proposal staged and none queued | `/donna proposal <#> <package> <monthly $> \| finding; finding` |
| won_no_intake | won, no onboarding intake saved | `/donna intake <#> \| hours: ...; services: ...; faq: q = a; urgent: ...` |
| intake_no_agent | intake saved, the client's phone agent not created | `/donna agent <client>` |

Rows carry the kind, the lead's short id, the business name, since when, and the client label. No email or phone.

Where it shows:
- the 6 pm digest adds "Waiting on you (money on the table)", even on an otherwise quiet day;
- `/donna stuck` on demand.

Before the migration is applied, the digest simply leaves the list out. Rollback: `ops/rollback_donna_nudges.sql` (drops the one function). Evidence: `sqltests/donna_nudges_check.sql` (N1-N7), `test_hq_donna_revenue.py::Stuck`, e2e leg 8.
