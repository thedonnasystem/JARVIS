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
