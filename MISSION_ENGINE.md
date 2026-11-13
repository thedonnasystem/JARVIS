# Mission engine: handoff, recovery and learning

Scope: `hq_missions.py` and the mission parts of `hq_engine.py`. No migration is needed. No new model calls: every
requeued task still runs through the existing metered path (kill switch, caps, focus mode, mission budget).

## 1. Step-to-step handoff
- Steps now run strictly in order: step N is launched only when every earlier step is `done` (or `cancelled`).
  `MAX_OPEN_PER_MISSION` is kept as a ceiling, but with ordering at most one step is open at a time. Strict steps and
  the database step limit are unchanged (a requeue reuses the same task row, so it never adds a step).
- The task detail of step N includes the earlier steps' results as DATA: at most `HANDOFF_PER_STEP` = 1200 chars each
  and `HANDOFF_TOTAL` = 3000 chars in all; the newest steps win when the total is hit. Only `done` steps with a result
  are included (blocked or empty ones are skipped).
- Worst-case added prompt: 3000 chars of results plus about 700 chars of labels = about 3,700 chars, roughly 1,050 tokens
  at 3.5 chars/token (about 1,250 at a pessimistic 3 chars/token) per launched step. An 8-step mission launches 7 steps
  that can see earlier output, so at most about 8,700 extra input tokens per mission (about 1,250 more per retry, since
  a retry resends the same prompt). Step 2 sees only 1,200 chars, step 3 at most 2,400, so the real figure is lower.
- `_attached_research` is now scoped: a task with a `mission_id` sees only research from that mission; a task without
  one sees only non-mission research (`mission_id is null`). Mission verify tasks still get the paired researcher's
  latest in-mission output (up to 6000 chars) in addition to the step results already in their detail. This was
  already the case and is left alone; it is a possible future saving.

## 2. Blocked-task recovery
`classify_block` reads a blocked task's result: `owner` (waiting on owner), `credit`, `gateway` (kill switch/focus),
`budget` (`Stopped: Mission budget ...`), `escalate`, `error`, `cancelled`, `other`.

| kind | step | evaluation / re-plan | verification |
|---|---|---|---|
| error | requeued once (retry marker, so a second failure blocks at once), then owner told | same | same, never counted as a failed attempt |
| budget | waits; restarts by itself only when the owner raises the budget above the headroom seen at the block | same, owner told once | same, owner told once (kind `money`) |
| escalate / other | mission blocked, owner told once | mission status unchanged, owner told once | status stays `verifying`, owner told once |
| owner question | waits (Task Brief already sent) | waits | waits |
| credit / kill / focus | waits silently (the engine's own pause already told the owner) | same | same |

- A blocked verifier no longer counts an attempt and no longer triggers a re-plan (a re-plan spends more). Only a real
  verdict (`VERIFIED: NO`, or YES without evidence) counts.
- A budget-blocked evaluation used to stay in `captured` with no message; it now sets `next_action` and tells the owner once.
- An escalated re-plan used to strand the mission in `blocked` with an empty plan; it now stays `planned` so the re-plan
  handler keeps running.
- Requeue is fail-closed: it needs a readable spend figure below the budget. `advance()` is not called when the kill
  switch is on or credit is paused (tick returns first). Markers (`task_retries`, `budget_marks`, `block_told`) live in
  the mission checkpoint; `/mission resume` preserves the first two so a resume cannot loop a failing step.
- `told_blocked` is cleared when a blocked mission recovers, so a later block tells the owner again.
- A verifier that errors twice now leaves the mission in `verifying` with an owner message instead of silently re-planning.
  The owner can unblock the task or abandon the mission; the 48h stale alert still applies.

## 3. Learning
- On completed, failed, rejected and abandoned, one `memory` row is written (`kind=lesson`, `agent=mission-manager`,
  `confidence=medium`, venture from the mission): verdict, cost in cents versus budget, attempts and up to four gaps,
  capped at 600 chars. Pausing writes nothing. A failed write is logged and never blocks the mission.
- The verification prompt now asks for a `FACTS:` section (`- fact | URL | confidence`). `_store_facts` also accepts
  mission verify tasks whose verifier is not an `*-auditor` (the `compliance-qa` fallback), and only when `VERIFIED: YES`.
- `SOURCING_RE` is defined once in `hq_missions` and `hq_engine` uses the same object.
- Not done (outside the three packages): `predictions` rows are still resolved at creation time, so they are not
  calibration. Fixing that needs outcome data and probably a migration.

## Known limits
- Sequential steps lengthen a mission's wall-clock time (one engine tick per step plus the task's own latency).
- Budget restart relies on the owner raising `/mission budget`; there is no automatic top-up.
- Handoff truncation is by characters, not by meaning: a long step result is cut at 1200 chars.

## Review follow-ups (independent review, Nov 13)
- `classify_block` now checks `ESCALATE` and the owner-question marker first, and treats credit / kill-switch / focus-mode only inside the engine's own `error:` / `Stopped:` wrappers, so agent prose that mentions those phrases can no longer park a mission silently.
- `/mission retry <id>`: for a blocked mission whose step already used its one automatic retry. It only clears the retry markers; the next tick still runs the task through the spend gateway and the mission budget, and fails closed if spend is unreadable. `/mission resume` is unchanged.
- Abandoning an already finished mission no longer writes a second lesson.
- Mission fact storage reuses `parse_verification`, so a quoted `VERIFIED: YES` cannot store facts when the verdict is NO.

## Evidence check, format resilience, due dates and recurrence (stream/mission2)
No migration: everything below lives in code and in the existing `missions.checkpoint` JSON. No new model call is made by `hq_missions`;
the one extra model run (a format repair) is an ordinary board task that goes through the spend gateway and the mission budget.

### A4. Evidence-checked verification
- `check_evidence` (deterministic string work, no network) checks each `EVIDENCE: claim | source` against the results of the mission's
  finished tasks other than verification tasks (steps, evaluation, re-plan, attached research). The verifier's own output is never a source.
- Source rules (revised after review): EVERY URL in a source must appear in a result (compared without scheme, `www.`, fragment,
  trailing slash/punctuation; exact match, no domain-only match) AND the claim must be supported within 600 chars of that occurrence
  (at least 60% of its words of 4+ letters, and every number in it). EVERY quote must appear verbatim on word boundaries; a quote needs
  12+ chars or 3+ words, only double quotes count (apostrophes are not quote marks). A source with no URL or quote (`task record`,
  `step 2`, a step title) needs at least 75% of the claim's words plus every number and capitalised name in the result; `step N` or a
  step title narrows the search to that step.
- Untrusted input: step results may contain text fetched from the web, which an attacker can write (a real URL next to a false claim).
  This check therefore only narrows what a verifier can invent; it cannot stand alone as proof, and the independent verifier plus the
  owner remain the real control.
- Decision: ONE untraceable item downgrades `VERIFIED: YES` to not verified. The gaps list names it ("evidence not traceable to the step
  results: ..."), it counts as a normal failed attempt (re-plan with the gaps, three strikes), and an audit row `mission_evidence_downgraded`
  is written. Strict on purpose: a verifier that invents one source is not trusted on the rest.
- Limits: it proves the cited source appears in the mission's own output, not that the page says what the step claims. A verifier that
  legitimately re-checks a NEW URL and cites it will be downgraded (the prompt tells it to cite sources from the results). Stored step results
  are capped at 8000 chars by the engine, so a URL past that cut cannot be matched.

### A5. Output-format resilience
- `canonicalize` rewrites tolerant variants into the canonical `LABEL: value` lines before the unchanged strict regexes run: case, markdown
  bold/italic/code around the label, heading marks, bullets, numbering (`1.`, `2)`, `STEP 3:`), `=` or a dash for `:`, `MISSION VERDICT`,
  trailing punctuation, and a JSON object carrying the same fields. JSON is read ONLY when the whole reply is the object (or exactly one
  fenced block and nothing else), never from inside prose, and never when the reply has labelled lines. Labels in the middle of a
  sentence still do not count.
- Verdict-flip defence: for `VERIFIED` and `MISSION_VERDICT`, decorated forms (bullet, numbering, heading, dash separator) are accepted
  only when that line is the label's only occurrence; any `VERIFIED: NO` anywhere beats a YES, otherwise the last line decides; for the
  evaluation the most restrictive of REJECT / DEFER anywhere wins, otherwise the last line.
- Repair: when an evaluation / re-plan has no `MISSION_VERDICT`, or a verification has no `VERIFIED` line, ONE repair task is queued for the
  same agent (title `... (format repair) ...`, same mission role, so the existing handlers pick it up as the latest task). It carries the
  previous answer (max 3000 chars) as data and asks to restate it in the labelled lines without new research. Marker in
  `checkpoint.format_repairs` (written first), a repair is never itself repaired, so no loops. A repair is not a counted attempt; if it is
  also unreadable the old path applies (second evaluation / counted failed verification).
- If the database refuses the repair task (12 evaluation/verification tasks per mission), the repair is skipped and the old path runs.
- Limits: a repair costs one more model call at the normal task output size; the engine has no per-task output cap I may change here. The
  agent may still use its search tool during the repair despite the instruction.

### A6. Due dates and recurring missions
- `checkpoint.due_at` (set with `/mission due <id> YYYY-MM-DD|+3d|off`, or `create_mission(due_at=...)`). A date alone means 23:59:59 UTC of
  that day (evening of the previous day in Toronto). When a live mission passes it the owner is told ONCE (`told_overdue`); resetting the date re-arms it. Notification only.
- `checkpoint.recurrence` (set with `/mission repeat <id> weekly|daily|<days 1-90>|off [runs]`), default absent = off, and only the literal
  `enabled: true` counts. It is the owner's explicit authorization for that mission. Rules for the next run:
  - the previous run is `completed` (verified). Failed, rejected, abandoned, paused or still-live missions never recur;
  - the interval has passed (the clock starts the first tick after completion);
  - read-only gateway check: no kill switch, no system pause (`pause_reason`), no focus mode; state unreadable = closed. `advance()` is
    already not called on kill switch, credit pause or coast;
  - runs remain (default 4, max 12 more runs; the chain announces its end once);
  - it goes through `create_mission`: same venture, objective and priority; budget capped at `MAX_BUDGET_CENTS`; the parent's `max_steps`
    (strict) carries over; the live-mission cap applies; it starts at `captured` and is evaluated, planned and verified like any mission;
  - one successor per run, claimed atomically: a conditional PATCH on the parent (`checkpoint->recurrence->>spawned=is.null`, returning the row) must return a row before the child is created; the loser of an overlapping tick creates nothing. A failed child creation releases the claim. A crash between claim and child leaves `spawned="claiming"` and the chain waits for the owner (fail-closed). A lookup for a child naming the parent (`recurrence.parent`) is a second guard. The candidate query is filtered on the server (`->>enabled=eq.true`).
  The successor gets `due_at` = spawn time + interval, and `runs_left - 1`. The owner is told on each start.
- Limits: interval granularity is the engine tick; every run has its own budget, so a chain of N runs can spend N budgets (bounded by runs
  and by the global caps in the spend gateway, which this change does not touch); a failed run ends the chain silently apart from the
  failure message of that mission. `/mission resume` keeps `due_at`, `recurrence` and `format_repairs`.

- `set_due` / `set_recurrence` re-read the checkpoint right before writing. `/mission <id>` prefix lookup still scans the 200 newest missions (a uuid prefix cannot be filtered server-side).
