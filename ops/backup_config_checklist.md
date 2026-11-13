# Backup configuration checklist (NON-SECRET: tick boxes, never write a key here)

Fill in nothing secret. If you want to note something, write only names, dates and yes/no.
Companion docs: `BACKUP_SETUP_OWNER.md` (click-by-click), `BACKUP_PROOF_PROCEDURE.md` (the restore proof), `BACKUP_RECOVERY.md` (design).
Rule: BACKUP_KEY and every Backblaze key go only into your password manager, Railway variables, and local hidden prompts. Never into chat, Telegram, email, GitHub, or any AI.

## 1. Backblaze
- [ ] B2 account created with email only, no card, no plan upgrade (stop rule honored)
- [ ] Bucket created, name starts `fendezy-hq-backups-`
- [ ] Bucket Files = **Private** (re-open the bucket page and confirm the word Private)
- [ ] Object Lock off
- [ ] Lifecycle rule: days from uploading to hiding **90**, days from hiding to deleting **1**, saved with Update Bucket
- [ ] Bucket ID copied (not a secret) and noted in the password manager
- [ ] Bot key `fendezy-bot-write`: type **Write Only**, restricted to the backup bucket only, no prefix
- [ ] Restore key `fendezy-restore-read`: type **Read Only**, restricted to the backup bucket only, no prefix
- [ ] Master application key was NOT used or copied anywhere
- [ ] Both key pairs (keyID + applicationKey) saved in the password manager as two separate entries

## 2. Encryption key
- [ ] BACKUP_KEY generated offline with `ops/generate_backup_key.html` (44 characters, ends with `=`)
- [ ] Copy 1 stored in the password manager ("Fendezy BACKUP_KEY")
- [ ] Copy 2 stored in a different place (for example printed, stored physically elsewhere)
- [ ] Nobody (including any AI) has seen the key

## 3. Railway (Jarvis bot service, Variables tab): names only
- [ ] `BACKUP_KEY` present
- [ ] `BACKUP_PUT_URL` present, shape `b2://<bucket id>/hq`
- [ ] `BACKUP_AUTH` present, holds the WRITE key A (not key B)
- [ ] No `RESTORE_*` variable exists in Railway
- [ ] Bot redeployed after saving and shows deployed

## 4. Variable table
| Variable | Where it is set | Secret? | If it is wrong or missing |
|---|---|---|---|
| `BACKUP_KEY` | Railway (bot); password manager x2; typed at the local hidden prompt of `ops/restore_local.sh` | YES | Missing: backups never run (dormant). Not a valid key: `/backup check` FAIL, nothing is written. WRONG but valid-looking key (not the one the backups were made with): backups upload fine but restore fails with "cannot decrypt". Lost: all backups unreadable forever. |
| `BACKUP_PUT_URL` | Railway (bot) | No (contains the bucket ID, which is not a secret; treat as private anyway) | Missing: backups dormant. Bad format (not `b2://<id>[/prefix]`): `/backup check` FAIL. Wrong bucket ID: Backblaze refuses ("key is limited to a different bucket" or upload 401/403/404). Different prefix than the restore uses: restore says "no backups found". |
| `BACKUP_AUTH` | Railway (bot); password manager | YES | Missing: check FAIL, run fails. No colon / wrong pair: "Backblaze accepts the application key" FAIL (HTTP 401). Key A missing writeFiles: "Key can write files" FAIL. Wrong key type (Read and Write / Read Only): WARN or FAIL. |
| `JARVIS_OWNER_ID` | Railway (already set) | No | Wrong: `/backup` commands are ignored for you. |
| `HQ_SUPABASE_URL`, `HQ_SUPABASE_SERVICE_KEY` | Railway (already set) | service key YES | The bot cannot read the database: check shows "Database reachable" FAIL, backups fail. |
| `RESTORE_B2_AUTH` | NOT Railway. Local hidden prompt of `ops/restore_local.sh` only (value is `keyID:applicationKey` of the READ-ONLY key B) | YES | 401: "B2 authorize failed (HTTP 401)" (exit 2). Write-only key used by mistake: "B2 list failed" / "download failed" (exit 2). |
| `RESTORE_B2_BUCKET_ID` | Local visible prompt of `ops/restore_local.sh` | No | Wrong: list fails or "no backups found". |
| `RESTORE_B2_PREFIX` | Local, optional; the script defaults to `hq/` | No | Not matching the `/hq` part of BACKUP_PUT_URL: "no backups found in that bucket/prefix". |
| `RESTORE_DB_URL` | Set automatically by `ops/restore_local.sh` for its throwaway container | Throwaway password only | You never set it by hand for the proof. |

## 5. `/backup check` in Telegram: expected lines (all must be OK; a FAIL blocks `/backup now`)
- [ ] OK  BACKUP_KEY is set
- [ ] OK  BACKUP_PUT_URL is set
- [ ] OK  BACKUP_AUTH is set
- [ ] OK  BACKUP_KEY is a valid encryption key (encrypt/decrypt round trip)
- [ ] OK  BACKUP_PUT_URL format (b2://<bucketId>/hq)
- [ ] OK  Backblaze accepts the application key
- [ ] OK  Key can write files
- [ ] OK  Key is limited to the backup bucket (WARN here = key reaches all buckets: recreate it)
- [ ] OK  Key has no delete/read/admin powers (bot key should be write-only) (WARN here = key has extra powers: recreate as Write Only)
- [ ] OK  Backblaze issues an upload address for the bucket
- [ ] OK  Database schema snapshot function (backup_schema) installed (WARN = migration not applied: backups would be data-only and unrestorable)
- [ ] Last line says "Ready for /backup now."
- [ ] No line "Key file-name prefix matches ..." (it appears only when it FAILS; fix the key's prefix)
Not tested by `/backup check` (tick by looking yourself): bucket Private, lifecycle rule saved, restore key works, BACKUP_KEY stored twice.

## 6. After `/backup now` (only after you authorized backup activation)
- [ ] `/backup` shows Last good, a file name `hq-YYYYMMDDTHHMMSSZ.tar.gz.enc`, rows around 1,100+, tables 53, complete: True
- [ ] Backblaze console shows `hq/<that name>` and `hq/<that name>.sha256`
- [ ] The restore proof in `BACKUP_PROOF_PROCEDURE.md` passed
- [ ] Calendar reminder set: restore drill monthly (see the procedure), and `/backup` age check weekly

Where each secret lives (and nowhere else): BACKUP_KEY = password manager + second offline copy + Railway. Key A = password manager + Railway. Key B = password manager only (typed locally during drills).
