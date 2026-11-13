# Owner setup: free encrypted off-site backup (about 20 minutes, one time)

Cost: $0. Backblaze B2 gives 10 GB free without a credit card ([Backblaze](https://www.backblaze.com/blog/free-isnt-always-free-a-guide-to-free-cloud-tiers/)). Your live database is 16 MB (about 1,100 rows), so 90 days of daily backups is far under 1 GB.
**STOP RULE:** if any step asks for a credit card, payment method or plan upgrade, stop and tell Claude. Do not enter one.
**SECRET RULE:** the encryption key (`BACKUP_KEY`) and the Backblaze keys go ONLY into (a) your password manager, (b) Railway variables, and (c) the hidden prompts of the restore script on your own computer. Never into chat, Telegram, email, GitHub, or any AI (Claude, Jarvis, ChatGPT, anything). Claude never needs them.
Console wording below comes from Backblaze's documentation; if a label differs slightly on screen, pick the closest option and tell Claude (the label, not a key).
A tick-box version of this page with no secrets: `ops/backup_config_checklist.md`. The proof that a backup really restores: `BACKUP_PROOF_PROCEDURE.md`.

## A. Backblaze account and bucket
1. Go to backblaze.com, choose B2 Cloud Storage, sign up with your email and verify it. (No card.) If B2 asks you to "enable" B2 Cloud Storage on the account, do that.
2. Left menu, B2 Cloud Storage, **Buckets**, **Create a Bucket**.
   - Name: `fendezy-hq-backups-` plus 6 random letters (names are global)
   - Files in Bucket are: **Private** (never Public: the files are encrypted, but private is the rule)
   - Default Encryption: leave on (our files are already encrypted by us as well)
   - Object Lock: off
3. Open the bucket. Copy its **Bucket ID** (a short code of letters and numbers; it is not a secret). You need it in step D and F.
4. On the bucket, click **Lifecycle Settings**, choose **Use custom lifecycle rules**, leave the file path/prefix empty (or `hq/`), set:
   - Days from uploading to hiding: **90**
   - Days from hiding to deleting: **1**
   Click **Update Bucket**. ([Backblaze docs](https://www.backblaze.com/docs/cloud-storage-configure-and-manage-lifecycle-rules))
   Heads-up: this deletes EVERY file older than about 91 days. If the bot silently stops backing up, your newest backup disappears after about 3 months. So glance at `/backup` in Telegram now and then: "Last good" should be under 2 days old.

## B. Two application keys (App Keys page, Add a New Application Key)
Do NOT use the account "master application key" for anything. Make exactly these two. Both: **Allow access to Bucket(s)** = your backup bucket only. No file-name prefix. No expiry.
| Key | Name | Type of access | Used by |
|---|---|---|---|
| A (bot) | `fendezy-bot-write` | **Write Only** | The Railway bot. Can add backups, cannot read, list or delete them. |
| B (restore) | `fendezy-restore-read` | **Read Only** | YOU, on your own computer, in restore drills only. Cannot change or delete anything. |
Backblaze shows each **applicationKey** only once, so copy the keyID and applicationKey of each straight into your password manager (separate entries named "B2 bot write key" and "B2 restore read key"). Not chat, not email.
**Key B is never put in Railway and never given to Claude, Jarvis or any AI.** If the console offers custom capabilities instead, key A needs only `writeFiles`; key B needs `listFiles` + `readFiles`. (If key A has more than that, `/backup check` shows a WARN line.)

## C. Encryption key (BACKUP_KEY)
Open `ops/generate_backup_key.html` from the repo on your own computer (double-click it; if the Copy button does nothing, select the text by hand and copy it), press Generate. The result is exactly 44 characters ending in `=`. Save it in your password manager under "Fendezy BACKUP_KEY". It is made inside your browser and never sent anywhere. (Alternative: `python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"`.)
**If this key is lost, every backup is permanently unreadable.** Keep a second copy in a DIFFERENT place from the password manager (for example a printed sheet in a safe place). Do not generate a new key later without keeping the old one: old backups need the key they were made with.

## D. Railway variables (Jarvis bot service, Variables tab)
Exactly three, names spelled exactly like this (capitals, underscores):
| Variable | Exact format |
|---|---|
| `BACKUP_KEY` | the 44-character key from C (ends with `=`) |
| `BACKUP_PUT_URL` | `b2://<Bucket ID>/hq` (keep the `/hq`; the restore script looks in `hq/` by default). Example shape only: `b2://abcd1234efgh5678/hq` |
| `BACKUP_AUTH` | `<keyID of key A>:<applicationKey of key A>` (one colon, no spaces, no quotes) |
Nothing else changes (`JARVIS_OWNER_ID` is already set; `/backup` answers only that person). Saving variables makes Railway redeploy the bot; wait until it shows deployed. Do not put these anywhere except Railway and your password manager. Do NOT add any `RESTORE_*` variable to Railway.

## E. Tell Claude "backup setup done"
Do not paste any of the values. Claude will tell you what to type in the Jarvis Telegram chat:
1. `/backup check`: read-only, nothing is uploaded. It prints one line per test (OK / WARN / FAIL). All of these must be OK: BACKUP_KEY, BACKUP_PUT_URL and BACKUP_AUTH are set; BACKUP_KEY is a valid encryption key; BACKUP_PUT_URL format; Backblaze accepts the application key; Key can write files; Key is limited to the backup bucket; Key has no delete/read/admin powers; Backblaze issues an upload address for the bucket; Database schema snapshot function (backup_schema) installed. It ends with "Ready for /backup now." when there is no FAIL. Any FAIL: fix it in Railway/Backblaze and run it again. Any WARN: fix it too (a WARN on the last line means the database migration below is not applied yet, so backups would be data-only and cannot be restored).
   What `/backup check` does NOT test: that the bucket is Private, that the lifecycle rule is set, that key B works, or that you stored BACKUP_KEY twice. Those are on the checklist and are proven by the restore drill.
2. After you separately approve the production deploy and the read-only migration `20261113_backup_schema_v1.sql`: `/backup now`. Then `/backup` shows the file name, size, rows and a sha256 (this hash is not a secret; you use it in step F). Backups then run by themselves every night between 02:00 and 05:00 Toronto time (at most once per 20 hours; after a failure it retries after 90 minutes, up to 3 times, and tells you once per day).
Note: `/backup check` and `/backup now` only exist after PR #2 is merged and deployed (your separate approval). Until then the check cannot run in production.

## F. The real restore proof (you run one command; nothing secret goes to chat)
Full steps with expected results: `BACKUP_PROOF_PROCEDURE.md`. Short version, on your own computer with Docker running, Python 3 (`pip install cryptography psycopg2-binary`) and a bash shell (Mac/Linux; on Windows use WSL), from the repo folder: `ops/restore_local.sh --b2-latest --expect-sha256 <the hash /backup showed>`. It asks, in this order: `BACKUP_KEY` (hidden), the READ-ONLY B2 key as `keyID:applicationKey` (hidden), then the Bucket ID (visible, not secret). It restores into a throwaway database that exists only inside a Docker container, verifies everything, and deletes the container. It writes two files in the folder you ran it from (`restore_report_*.json` and `restore_fingerprint_*.txt`; they contain no secrets). You may show Claude those two files plus the output of `ops/table_fingerprint.sql` run on production, and Claude compares them independently. Do not send keys to Claude, Telegram or any chat.
