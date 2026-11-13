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
