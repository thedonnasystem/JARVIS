# Proposal: let Jarvis mention /heavy in chat (not built)

**What.** One sentence added to Jarvis's chat instructions so that, when the Chairman asks for something too big for a chat reply (a site, a large fix, a deep review, long research), Jarvis offers the ready-made command for him to send:

> When a request is a large build, fix, review or research job, you may offer the Chairman the command `/heavy <kind> | <what to do>` (kinds: site-build, office-fix, qc-review, research, other) for him to send himself. You cannot queue it. Never put client data, contacts or keys in it.

`hq_heavy.suggestion(kind, text)` already formats that command. Showing it adds nothing to the queue: only the owner-only `/heavy` command does.

**Why it is a proposal and not in this change.** The sentence belongs in the chat system prompt in `bot.py`, which is on the never-edit list and is being changed by the linked-memory branch at the same time. It also adds about 60 tokens to every chat call. Both are the Chairman's call.

**If approved.** Append the sentence where `SYSTEM_PROMPT` is finished in `bot.py`, add one test that the prompt contains `/heavy` and that no tool or handler other than the owner command calls `hq_heavy.enqueue` (already pinned in `test_hq_heavy.py`).

**Rollback.** Remove the sentence.
