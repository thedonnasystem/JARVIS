# Owner setup: free encrypted off-site backup (about 20 minutes, one time)

Cost: $0. Backblaze B2 gives 10 GB free without a credit card ([Backblaze](https://www.backblaze.com/blog/free-isnt-always-free-a-guide-to-free-cloud-tiers/)). Your live database is 16 MB (about 1,100 rows), so 90 days of daily backups is far under 1 GB.
**STOP RULE:** if any step asks for a credit card, payment method or plan upgrade, stop and tell Claude. Do not enter one.
Console wording below comes from Backblaze's documentation; if a label differs slightly on screen, pick the closest option and tell Claude.

## A. Backblaze account and bucket
1. Go to backblaze.com, choose B2 Cloud Storage, sign up with your email and verify it. (No card.)
2. Left menu, B2 Cloud Storage, **Buckets**, **Create a Bucket**.
   - Name: `fendezy-hq-backups-` plus 6 random letters (names are global)
   - Files in Bucket are: **Private**
   - Default Encryption: leave on (our files are already encrypted by us)
   - Object Lock: off
3. Open the bucket. Copy its **Bucket ID** (24 characters). You need it in step D.
4. On the bucket, click **Lifecycle Settings**, choose **Use custom lifecycle rules**, leave the file path/prefix empty (or `hq/`), set:
   - Days from uploading to hiding: **90**
   - Days from hiding to deleting: **1**
   Click **Update Bucket**. ([Backblaze docs](https://www.backblaze.com/docs/cloud-storage-configure-and-manage-lifecycle-rules))

## B. Two application keys (App Keys page, Add a New Application Key)
Both keys: **Allow access to Bucket(s)** = your backup bucket only. No file-name prefix. No expiry.
| Key | Name | Type of access | Used by |
|---|---|---|---|
| A (bot) | `fendezy-bot-write` | **Write Only** | Railway bot. Can add backups, cannot read or delete them. |
| B (restore) | `fendezy-restore-read` | **Read Only** | Claude / recovery drills. Cannot change or delete anything. |
Backblaze shows each **applicationKey** only once, so copy the keyID and applicationKey of each straight into your password manager (not chat, not email).
If the console offers custom capabilities instead, key A needs only `writeFiles`; key B needs `listFiles` + `readFiles`.

## C. Encryption key (BACKUP_KEY)
Open `ops/generate_backup_key.html` from the repo on your own computer (double-click it), press Generate, save the 44-character result in your password manager under "Fendezy BACKUP_KEY". It is made inside your browser and never sent anywhere. (Alternative: `python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"`.)
**If this key is lost, every backup is permanently unreadable. Keep a second offline copy.**

## D. Railway variables (Jarvis bot service, Variables tab)
| Variable | Exact format |
|---|---|
| `BACKUP_KEY` | the 44-character key from C (ends with `=`) |
| `BACKUP_PUT_URL` | `b2://<24-char Bucket ID>/hq`  e.g. `b2://4a48fe8875c6214145260818/hq` |
| `BACKUP_AUTH` | `<keyID of key A>:<applicationKey of key A>` (one colon, no spaces) |
Nothing else changes. Do not put these anywhere except Railway and your password manager.

## E. Tell Claude "backup setup done"
Do not paste any of the values. Claude will tell you what to type in the Jarvis Telegram chat:
1. `/backup check` read-only: confirms Railway has all three values, the key is valid, Backblaze accepts key A, it is limited to the right bucket, and it cannot read or delete. Nothing is uploaded.
2. After you separately approve the production deploy and the read-only migration: `/backup now`.
Note: `/backup check` and `/backup now` only exist after PR #2 is merged and deployed (your separate approval). Until then the check cannot run in production.

## F. The real restore proof (you run one command; nothing secret goes to chat)
On your computer with Docker installed (and `pip install cryptography psycopg2-binary`): `ops/restore_local.sh --b2-latest --expect-sha256 <the hash /backup showed>`. It asks for BACKUP_KEY and the READ-ONLY B2 key at hidden prompts, restores into a throwaway database, verifies everything, and deletes it. Send Claude only the two output files it writes (restore_report_*.json and restore_fingerprint_*.txt; they contain no secrets) plus the output of `ops/table_fingerprint.sql` run on production, and Claude compares them independently. Do not send keys to Claude, Telegram or any chat.
