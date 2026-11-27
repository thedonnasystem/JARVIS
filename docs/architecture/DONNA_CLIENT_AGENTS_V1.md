# Donna Client Agents v1

Delivery and retention for paying clients. It follows the Revenue Loop (#61 / #62).

## Flow

```
/deal won → /donna onboard <lead #> <package> → client answers → delivery-onboarding intake
/donna agent <client>                  → preview + 6-character confirm code (the spec's SHA-256)
/donna agent <client> create <code>    → Retell LLM + agent created on the owner's account, ids recorded
owner: Test call in Retell → buys or ports the client's number in Retell (costs money: his step) → attaches the agent
1st to 3rd of each month: last month's numbers from Retell → report email to the client → owner taps Approve
```

## Rules

- **The spec is plain code from the intake.** Hours, services (a price only where one was given), FAQs, urgent transfer (only to a valid E.164 number),
  booking, an AI disclosure at the start, no card details, and no promises. Voice: Kate. Calls are kept 30 days. It has the same fields as the live
  demo-line agent.
- **The confirm code is the hash of the exact spec.** If the intake changes, the code changes, so the owner always confirms exactly what gets created.
- **One agent per intake and per Retell id.** A rejected intake is refused. Donna must be active.
- **No phone number is bought.** Creating an agent on Retell is free.
- **Reports:**
  - one per agent and month;
  - the numbers come only from the client's own call log: calls, outside business hours, booking requests, urgent, messages;
  - each report is staged for the owner's tap like every Donna email (CASL footer, address from `/setaddress`).

## Files

| File | Content |
|---|---|
| `migrations/20261211_donna_client_agents_v1.sql` | Schema `fz_donna_ca` (agents, reports) and 4 service-only functions |
| `ops/rollback_donna_client_agents.sql` | Archives to `fz_archive.donna_ca_*`. Run before the revenue-loop and Donna Ops rollbacks. Retell agents stay on Retell |
| `sqltests/donna_client_agents_check.sql` | C1 to C4: dormant refusals, find/refuse, once per intake and per month, ACLs, rollback + re-apply |
| `hq_donna_agents.py`, `test_hq_donna_agents.py` | Spec, preview, create, monthly report (11 tests) |
| `hq_donna_revenue.py`, `hq_commands.py` | `client_report` mode, the monthly tick, `/donna agent`, `/donna clientreport` |

## Owner

`RETELL_API_KEY` in Railway, the same key the site uses. Optionally, `DONNA_CLIENT_WEBHOOK_URL` sends each client call to a webhook.

## Intake in one line (Donna Intake v1, hq_donna_intake.py)

The welcome email asks the client six questions. When the answers come back (the reply alert says so for a won client), the owner types them once:

    /donna intake <lead #> | hours: mon-fri 9-5, sat 10-2; services: Oil change $89 30min, Brake check $120 1h; faq: Walk-ins? = Yes, before 3 pm;
                             urgent: 613 555 0100; booking: https://cal.com/...; city: Kanata

- Plain-code parser: no model ever sees client data. It refuses what it cannot read (an unknown day, a time it cannot place, a phone that is not a number,
  a non-https booking link) instead of guessing. Days not named are closed; a service with no price stays 0 and becomes an open item, so the receptionist never
  quotes a wrong price.
- The result runs through the existing delivery-onboarding mission (reception_config validates it, donna_save_intake stores it with its open items), so it is
  refused while Donna is dormant, like every Donna action.
- Then `/donna agent <client>` previews the client's own phone agent from that intake. Nothing here sends, pays or deploys.
- Evidence: test_hq_donna_intake.py; scripts/replica/donna_revenue_e2e.py legs "/donna intake ..." and "/donna agent previews from the saved intake".
