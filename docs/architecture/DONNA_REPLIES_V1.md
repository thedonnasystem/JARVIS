# Donna Replies v1

A lead who answers an email stops getting follow-ups, and an unsubscribe reply is honoured on its own.

## How it works

1. Replies go to Donna's receiving address. `MAIL_REPLY_TO` is set to the `<id>.resend.app` address from the email provider's Receiving tab, or a receiving domain; `hq_mail` already sets Reply-To from it.
2. Every 10 minutes (`DONNA_REPLIES=1`), `hq_mail.received()` lists what arrived. It uses the same key that sends, and the provider calls stay in `hq_mail`, the one email-provider module.
3. `donna_unseen_messages` keeps only the new messages. Only those bodies are fetched (`received_text`).
4. Only their own words count: the text above the quoted original, so our quoted footer can never look like their unsubscribe.
5. `donna_record_email_reply` matches the sender to a Donna lead:
   - **A reply:** the lead moves to `replied`, follow-ups stop, and the owner gets "📩 replied: <their first lines>".
   - **An unsubscribe:** the existing `mark_do_not_contact` runs (suppression list, drafts rejected), and the owner gets "🛑 asked to unsubscribe".
   - **Not a Donna lead:** recorded once, nothing else.
6. It works while Donna is dormant. Stopping follow-ups and honouring an unsubscribe is a safety step.
7. No message text is stored: only the id, the lead and the kind.

## Files

| File | Content |
|---|---|
| `migrations/20261212_donna_replies_v1.sql` | Schema `fz_donna_rp` (seen), `donna_record_email_reply`, `donna_unseen_messages` |
| `ops/rollback_donna_replies.sql` | The rollback |
| `sqltests/donna_replies_check.sql` | P1 to P7 |
| `hq_donna_replies.py`, `test_hq_donna_replies.py` | The reply check and its tests |
| `hq_mail.py` (`received`, `received_text`; one `_open` call site), `test_hq_mail.Received` | The provider reads |
| `bot.py` | The 10-minute job |
| `hq_donna_setup.py` | The `/donna setup` line |

**Why not Gmail:** Google's device sign-in flow does not allow Gmail scopes (only email, profile, Drive app files and YouTube). Reading replies at the email provider needs no new key and no sign-in.
