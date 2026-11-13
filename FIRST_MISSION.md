# First controlled mission (PREPARED, NOT LAUNCHED)
Status: dry-run. Not created. No prospect contact, no spend, no sends.
Preconditions (owner): release A1-A3 done and verified; `system_state.mode=dry_run`, kill switch off; AI credits/pause (`pause_reason=api_credits`) resolved by YOU; focus mode off.
Command to create (Telegram, after you authorize): 
`/mission new @holding Research three viable Ottawa-area digital service businesses startable for under $300 CAD, with recurring-revenue potential, operable mostly by automation. For each: concrete service and named target customer; evidence of actual local demand; 3+ named local competitors with prices; startup cost line items; weeks to first revenue; how to win the first 5 customers WITHOUT contacting anyone now (channels, scripts only as drafts); a week-by-week execution plan; risks and kill metric. Cite a source URL for every number. Do not contact anyone and do not spend money.`
Then: `/mission budget <id> 300` (3 dollars, owner-set; engine hard max is $10). Optional: `/mission due <id> +2d`.
Guards in force: mission budget via spend gateway; kill switch; dry-run blocks sends; evidence check (and, once merged, snapshot verification); max steps/plan limits; `/mission pause|abandon <id>` anytime.
Acceptance (expected): 3 candidates each with the 8 fields above, every figure with a source URL, final status `verified` or honest `blocked`; zero outbox rows, zero leads contacted, ledger unchanged. Verify with `ops` SQL: outbox count unchanged, `action_log` has no `send_email allow`.
Limits: market claims are web-derived and only as good as the sources (R1); treat the output as research to review, not truth.
