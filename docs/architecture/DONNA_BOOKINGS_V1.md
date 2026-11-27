# Donna Bookings v1: website calendar bookings enter the pipeline

**Problem:** the site's main button books the free Revenue Leak Audit on Cal.com. Before this change, nothing in Jarvis knew about those bookings:
- no lead was created;
- no reply asking the three prep questions went out;
- no audit brief was written;
- the lead never showed in `/donna stuck`.

Only Donna phone or web calls marked a lead as booked.

**Change:**
- `hq_donna_revenue.calcom_items` reads upcoming bookings from the Cal.com bookings API. It is read-only, uses the owner's `CALCOM_API_KEY`, and runs in the same 5-minute inbound sync as the website form and the calls.
- Each audit booking goes through `donna_ingest_inbound` as source `booking` and becomes a **booked** lead. The usual loop then runs: prep-questions reply (owner taps Approve), audit brief, proposal, won, intake, agent.

**Only audits come in.** A booking counts only if its event type is the audit:
- `DONNA_CALCOM_EVENT_TYPE_IDS` lists the event type ids, or
- the event slug matches the end of `DONNA_BOOKING_URL` (for example `https://cal.com/donna-ai/revenue-leak-audit` → `revenue-leak-audit`).

With neither set, nothing is pulled, so the owner's other bookings never enter the CRM. Cancelled bookings are skipped.

**Consent:** a booking is an inquiry, so consent is implied (6 months). The database refuses express consent from any source but the website form's own box, and that rule is unchanged. Suppression, do-not-contact and dedupe (per source + ref, `cal-<uid>`) are unchanged.

## Database (`migrations/20261214_donna_bookings_v1.sql`)
- The `fz_donna_rl.inbound.source` check is widened to include `booking`, and a nullable `appointment_at` column keeps the audit's time.
- `donna_ingest_inbound` is re-created with the same body as Revenue Loop v1, with three changes:
  - `booking` is an allowed source;
  - its CRM note says "booked on the website calendar";
  - an optional last argument `p_appointment_at` (default null, so existing callers are unchanged) is stored. An absurd time is dropped.
- `donna_stuck_deals` counts "audit booked, no proposal yet" from the audit's own time when it is known. A booking made today for next week is not stuck until a day after the audit.
- Ordered before the lockdown. Safe to re-run. Nothing sends, pays or deploys.

**Rollback:** `ops/rollback_donna_bookings.sql`.
- It restores the old function (13 arguments) and the Nudges v1 stuck list. The `appointment_at` column is kept (nullable; nothing reads it after the rollback).
- `ops/rollback_donna_revenue_loop.sql` now drops both signatures.
- Booking rows are **kept** (never deleted). While any exist, the widened check stays so they remain valid.
- It writes one audit row; a second run does nothing.

## Owner setup
`/donna setup` shows the row "Website calendar bookings come in (Cal.com)". To turn it on:
- create a key in Cal.com (Settings → Developer → API keys) and add it in Railway as `CALCOM_API_KEY`;
- set `DONNA_BOOKING_URL` to the audit's cal.com link.

## Evidence
- `sqltests/donna_bookings_check.sql` B1–B8:
  - booked lead with implied consent and the right note;
  - duplicates;
  - express consent refused for a booking;
  - an existing lead moves to booked;
  - unknown sources refused;
  - rollback keeps the rows and is idempotent;
  - the original check is restored when no booking rows exist;
  - re-apply;
  - B9: the audit's time is kept, a future audit is not stuck, a past one is, an absurd time is dropped.
- `test_hq_donna_revenue.InboundSources.test_calcom_only_the_audit_event_type`.
- e2e leg 9: a calendar booking becomes a booked lead, and the owner's personal booking never comes in.
