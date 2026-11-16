# Owner review: <short name of the change>
Review id: `<id as recorded in the ledger>` · Date: `<UTC>` · Reviewer: `<id>` · Author: `<id>` (reviewer is not the author)
Subject: PR `#<n>` · branch `<name>` · head `<full 40-hex SHA>` · base `<ref>` @ `<SHA>`

## 1. What is being proposed
Plain English, 3 lines at most. What changes for the business, not which files.

## 2. Why it matters
What it protects, enables or risks if left undone.

## 3. Risk: LOW / MEDIUM / HIGH
- Reasoning: what can go wrong, how likely, how bad, can it be undone.
- Protected controls touched: spend / kill switch / dry-run / permissions / executor registry / secrets / gates / client PII (list, or "none").

## 4. Verification
| Tested (by whom, on which SHA, evidence) | Result |
|---|---|
| `<what was actually run>` | `<pass/fail + reference in the appendix>` |

**Not tested / not inspected:** list every item. "Nothing" is not an acceptable entry unless it is true.
Synthetic tests are not production proof: say which results are synthetic.

## 5. Recommendation: APPROVE / REJECT / REQUEST CHANGES
- One sentence why.
- Open findings: `<id, severity, one line each>`.
- Mandatory checks verdict: `<REJECT / NEEDS_MORE_WORK / RECOMMEND_APPROVE>` (`ops/oversight/evidence/<file>.json`).

## 6. Owner decision required: YES / NO
- The specific decision: `<e.g. "Merge PR #n at <SHA> into overnight-build. This does not deploy or migrate production.">`
- Options and consequences: `<a / b / c, one line each>`.
- What happens if you do nothing.

---
## Evidence appendix (machine-checkable; no claim above may lack a line here)
| Item | Value |
|---|---|
| Head SHA reviewed | `<40 hex>` (confirmed with `git ls-remote origin refs/heads/<branch>` at `<UTC>`) |
| Base SHA / merge-base | `<40 hex>` / `<40 hex>` |
| CI run ids on that SHA | `unit <id>`, `migrations <id>`, `secret-scan <id>` (conclusions) |
| Mandatory-checks result | file `<path>`, sha256 `<hash>`, engine sha256 `<hash>` |
| Commands run by the reviewer | `<command>` → exit `<n>`, output sha256 `<hash>` (one line each) |
| Files actually opened | `<paths, or "diff only", or "none: mechanical run only">` |
| Environment | `<scratch cluster/port, never production>` |
| NOT inspected | `<list>` |
| Ledger entry | seq `<n>`, entry hash `<hash>` |

Rules for the writer: no test result without a command and an exit code; no "verified" for something read but not run; never write that the Owner approved anything (only a signed `owner_decision` ledger entry says that).
