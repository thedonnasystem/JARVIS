#!/usr/bin/env bash
# Backup activation preflight. Checks everything verifiable WITHOUT showing any value: only presence, length, format and PASS/WARN/FAIL.
# Run where the three variables are in the environment WITHOUT typing them anywhere, e.g.:   railway run ops/backup_activation_preflight.sh
# (railway run puts the service variables into this one process only; nothing is printed or written.) Add --network to also ask the
# destination (Backblaze) whether the key is accepted and limited correctly: one authorize call, no upload, no data sent.
# --require-pii-exclusion: the PII check (section 7) becomes a FAIL instead of a WARN (also when the DB cannot be checked). The check reads the
# table list of the target DB through psql using PII_CHECK_DB_URL (or REPLICA_URL); it prints table NAMES only, never rows or the URL.
# Never prints BACKUP_KEY / BACKUP_AUTH / BACKUP_PUT_URL. Exit 0 = no FAIL, 1 = at least one FAIL.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/.."
fails=0; warns=0
ok()   { echo "PASS  $1"; }
warn() { echo "WARN  $1"; warns=$((warns+1)); }
bad()  { echo "FAIL  $1"; fails=$((fails+1)); }
net=0; reqpii=0
for a in "$@"; do case "$a" in --network) net=1;; --require-pii-exclusion) reqpii=1;; *) echo "unknown arg $a"; exit 2;; esac; done

key="${BACKUP_KEY:-}"; url="${BACKUP_PUT_URL:-}"; auth="${BACKUP_AUTH:-}"

# 1 presence + length
for v in BACKUP_KEY BACKUP_PUT_URL BACKUP_AUTH; do
  val="${!v:-}"; if [ -n "$val" ]; then ok "$v is set (length ${#val})"; else bad "$v is NOT set"; fi
done
# 2 key format
if [ -n "$key" ]; then
  [ "${#key}" = 44 ] && [ "${key: -1}" = "=" ] && ok "BACKUP_KEY has Fernet shape (44 chars, ends with =)" || bad "BACKUP_KEY must be 44 characters ending in = (re-generate; do not edit by hand)"
  case "$key" in *[[:space:]]*|\"*|\'*) bad "BACKUP_KEY contains whitespace or quote characters (paste the bare key, no quotes)";; esac
  if python3 -c "import cryptography" 2>/dev/null; then
    if BK="$key" python3 -c "import os,sys;from cryptography.fernet import Fernet;f=Fernet(os.environ['BK'].encode());sys.exit(0 if f.decrypt(f.encrypt(b'x'))==b'x' else 1)" 2>/dev/null; then ok "BACKUP_KEY works (encrypt/decrypt round trip)"; else bad "BACKUP_KEY is not a valid Fernet key"; fi
  else warn "python 'cryptography' not installed here; key round trip skipped (pip install cryptography)"; fi
fi
# 3 destination shape (prints the scheme only, never the host/path: a path can hold a token)
kind=""
case "$url" in
  b2://*) kind=b2; ok "BACKUP_PUT_URL scheme: b2 (Backblaze)"
          printf '%s' "$url" | grep -Eq '^b2://[A-Za-z0-9]{8,64}(/[^ ]*)?$' && ok "BACKUP_PUT_URL looks like b2://<bucketId>[/prefix]" || bad "BACKUP_PUT_URL must look like b2://<bucketId>/hq"
          case "$url" in */hq|*/hq/) ok "prefix is hq (what ops/restore_local.sh looks for by default)";; *) warn "prefix is not /hq; restore needs RESTORE_B2_PREFIX to match";; esac
          case "$auth" in *:*) ok "BACKUP_AUTH has the keyId:applicationKey shape";; "") ;; *) bad "BACKUP_AUTH for b2 must be <keyId>:<applicationKey>";; esac ;;
  https://*) kind=put; ok "BACKUP_PUT_URL scheme: https (generic PUT)"
          case "$url" in *"{name}"*) ok "BACKUP_PUT_URL contains {name}";; *) bad "BACKUP_PUT_URL must contain {name} (else the backup and its checksum overwrite each other)";; esac
          case "$auth" in "Basic "*|"Bearer "*) ok "BACKUP_AUTH starts with a valid HTTP auth scheme (Basic/Bearer)";; "") warn "BACKUP_AUTH empty: destination would be unauthenticated";; *) warn "BACKUP_AUTH is sent verbatim as the Authorization header; usually 'Basic <base64>' or 'Bearer <token>'";; esac ;;
  "") ;;
  http://*) bad "BACKUP_PUT_URL is http:// (refused by the bot: https:// or b2:// only)";;
  *) bad "BACKUP_PUT_URL must start with b2:// or https://";;
esac
# 4 variables that must NOT be in the bot's environment
for v in RESTORE_B2_AUTH RESTORE_B2_BUCKET_ID RESTORE_DB_URL; do
  [ -n "${!v:-}" ] && bad "$v is set here; restore variables must never live in Railway" || ok "$v is not set (good)"
done
# 5 repo pieces the flow depends on
for f in hq_backup.py hq_backup_keep.py hq_scrub.py ops/restore_backup.py ops/restore_local.sh migrations/20261113_backup_schema_v1.sql migrations/20261120_backup_redact_leak_paths_v1.sql migrations/20261120_redaction_denylist_v1.sql migrations/20261120_leak_source_prevention_v1.sql; do
  [ -f "$root/$f" ] && ok "found $f" || bad "missing $f"
done
python3 -c "import psycopg2" 2>/dev/null && ok "psycopg2 available (needed by the restore tool on YOUR computer)" || warn "psycopg2-binary not installed here (needed only where you run the restore drill)"
# 6 optional destination check (Backblaze only). Output is PASS/WARN/FAIL lines only.
if [ "$net" = 1 ]; then
  if [ "$kind" != b2 ]; then warn "--network check is implemented for b2:// only"
  elif [ -z "$auth" ]; then bad "--network needs BACKUP_AUTH"
  else
    out="$(cd "$root" && python3 - <<'PY' 2>&1
import hq_backup as B
try:
    for r in B.preflight():
        if "Backblaze" in r["check"] or r["check"].startswith("Key"):
            print(r["status"].upper().ljust(4), r["check"], ("- " + r["detail"]) if r["detail"] else "")
except Exception as e:
    print("FAIL ", "network check could not run:", type(e).__name__)
PY
)"
    echo "$out"; echo "$out" | grep -q '^FAIL' && fails=$((fails+1)); echo "$out" | grep -q '^WARN' && warns=$((warns+1))
  fi
fi
# 7 client-PII exclusion. The DATABASE decides what is exported (public.backup_export_policy(), migration 20261119_backup_exclude_client_pii_v1). This check reads that decision
# (table NAMES only, never rows or the URL) and requires: the function exists; no client table is on the exported list; nothing is unclassified.
# WARN (FAIL with --require-pii-exclusion) otherwise. Then section 8 below requires the client-text leak paths to be closed (redaction installed).
pii_flag() { if [ "$reqpii" = 1 ]; then bad "$1"; else warn "$1"; fi; }
dburl="${PII_CHECK_DB_URL:-${REPLICA_URL:-}}"
if [ -z "$dburl" ]; then pii_flag "client-PII policy check could not run: set PII_CHECK_DB_URL (read-only connection string of the target DB)"
elif ! command -v psql >/dev/null 2>&1; then pii_flag "client-PII policy check could not run: psql not installed"
else
  pol="$(psql "$dburl" -Atqc "select jsonb_array_length(p->'exported') || ' ' || jsonb_array_length(p->'unclassified') || ' ' || coalesce((select string_agg(e, ',') from jsonb_array_elements_text(p->'exported') e where e ~ '^(ws_|ffm_)' or e in ('client_workspaces','leads','outbox','lead_replies','deals','contact_suppressions','setters','setter_events','setter_payouts')), '-') || ' ' || coalesce((select string_agg(e, ',') from jsonb_array_elements_text(p->'unclassified') e), '-') from (select public.backup_export_policy() p) q" 2>/dev/null)"; rc=$?
  if [ $rc != 0 ] || [ -z "$pol" ]; then pii_flag "client-PII policy check could not run: database not reachable or backup_export_policy() is not installed (apply migration 20261119_backup_exclude_client_pii_v1 first)"
  else
    set -- $pol; nexp="$1"; nun="$2"; bad_exp="$3"; uncl="$4"
    if [ "$bad_exp" != "-" ]; then pii_flag "client tables are on the EXPORT list: ${bad_exp} - DO NOT ACTIVATE"
    elif [ "$nun" != "0" ]; then pii_flag "unclassified tables (not exported until classified in a migration): ${uncl} - review before activating"
    else ok "export policy: ${nexp} tables exported, no client table on the list, nothing unclassified"; fi
  fi
fi
# 8 the known client-text leak paths (audit_log.detail.reason, ledger.note of setter payouts, tasks.result, agent_runs.summary; DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2) are CLOSED when both
# layers are installed in the target database: the source fixes (migration 20261120_leak_source_prevention_v1), the export redaction inside backup_snapshot() (20261120_backup_redact_leak_paths_v1) and the deny-list that remembers erased names (20261120_redaction_denylist_v1).
# The check reads public.backup_redaction_status(), which inspects the definitions actually in force (not a flag anyone can set). BACKUP_LEAK_PATHS_ACCEPTED=1 no longer passes this check:
# accepting the leak was option (c); the owner chose (a)+(b), so the only way to pass is to have the redaction installed.
if [ -z "$dburl" ] || ! command -v psql >/dev/null 2>&1; then pii_flag "KNOWN LEAK PATHS: cannot check whether the redaction is installed (set PII_CHECK_DB_URL, psql needed)"
else
  st="$(psql "$dburl" -Atqc "select concat_ws(' ', coalesce(s->>'snapshot_redacts','f'), coalesce(s->>'sources_fixed','f'), coalesce(s->>'redactor_installed','f'), coalesce(s->>'agent_runs_trigger','f'), coalesce(s->>'denylist','f')) from (select public.backup_redaction_status() s) q" 2>/dev/null)"; rc=$?
  if [ $rc != 0 ] || [ -z "$st" ]; then pii_flag "KNOWN LEAK PATHS: backup_redaction_status() is not installed - apply migrations 20261120_backup_redact_leak_paths_v1 and 20261120_leak_source_prevention_v1 (see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2)"
  elif [ "$st" = "true true true true true" ]; then ok "client-text leak paths closed: source fixes + export redaction + deny-list triggers are installed (backup_redaction_status)"
  else pii_flag "KNOWN LEAK PATHS: redaction only partly installed (snapshot_redacts/sources_fixed/redactor_installed/agent_runs_trigger/denylist = $st) - DO NOT ACTIVATE"; fi
  [ "${BACKUP_LEAK_PATHS_ACCEPTED:-0}" = 1 ] && warn "BACKUP_LEAK_PATHS_ACCEPTED=1 is ignored: it no longer substitutes for the redaction (owner decision: close the leak paths, do not accept them)"
fi
# the backup identity (owner directive D): the migration 20261121_postlock_backup_identity_v1 takes the backup functions away from service_role, so the backup must carry its own token
if [ -n "$dburl" ] && command -v psql >/dev/null 2>&1; then
  idn="$(psql "$dburl" -Atqc "select (exists (select 1 from pg_roles where rolname = 'backup_reader'))::text || ' ' || coalesce(has_function_privilege('service_role', to_regprocedure('public.backup_epoch()'), 'execute')::text, 'none') || ' ' || coalesce(has_function_privilege('backup_reader', to_regprocedure('public.backup_epoch()'), 'execute')::text, 'none')" 2>/dev/null)"
  case "$idn" in
    "true false true") ok "backup identity installed: role backup_reader can run the backup functions, service_role cannot";;
    *) pii_flag "BACKUP IDENTITY: not as expected (role exists / service_role may execute / backup_reader may execute = $idn) - apply migration 20261121_postlock_backup_identity_v1 (after the lockdown)";;
  esac
fi
# BACKUP_READER_JWT is the ONLY credential the backup may use (hq_backup refuses to run without it and never falls back to the service key). Decoded here WITHOUT a network call and without printing it:
# the role claim must be exactly backup_reader and exp must be in the future. A missing, malformed, expired or wrong-role token is a FAIL under --require-pii-exclusion (a WARN otherwise): the nightly backup would refuse.
jwt_state="$(BJ="${BACKUP_READER_JWT:-}" python3 - <<'PY' 2>/dev/null || echo "undecodable"
import base64, json, math, os, sys, time
t = os.environ.get("BJ", "").strip()
if not t:
    print("unset"); sys.exit(0)
def strict(pairs):                       # a JSON object with the same key twice is refused: which `role` wins depends on the parser
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)
def no_const(_):                         # NaN / Infinity / -Infinity are not JSON
    raise ValueError("not a number")
try:
    p = t.split(".")
    if len(p) != 3 or not all(p):
        print("malformed"); sys.exit(0)
    pad = lambda x: x + "=" * (-len(x) % 4)
    claims = json.loads(base64.urlsafe_b64decode(pad(p[1])), object_pairs_hook=strict, parse_constant=no_const)
    json.loads(base64.urlsafe_b64decode(pad(p[0])), object_pairs_hook=strict, parse_constant=no_const)
except Exception:
    print("malformed"); sys.exit(0)
role = claims.get("role") if isinstance(claims, dict) else None
exp = claims.get("exp") if isinstance(claims, dict) else None
nbf = claims.get("nbf") if isinstance(claims, dict) else None
if role != "backup_reader":
    print("wrongrole"); sys.exit(0)
if isinstance(exp, bool) or not isinstance(exp, (int, float)) or not math.isfinite(exp):      # 1e400 parses to infinity: not an expiry
    print("noexp"); sys.exit(0)
if exp <= time.time():
    print("expired"); sys.exit(0)
if nbf is not None and (isinstance(nbf, bool) or not isinstance(nbf, (int, float)) or not math.isfinite(nbf)):
    print("malformed"); sys.exit(0)
print("notyet" if nbf is not None and nbf > time.time() + 60 else "ok")
PY
)"
case "$jwt_state" in
  ok) ok "BACKUP_READER_JWT decodes, role = backup_reader, exp is in the future, nbf (if any) has passed (signature is checked by the database when the backup runs; the backup uses no other credential)";;
  unset) pii_flag "BACKUP_READER_JWT is not set: the backup refuses to run without it (it never falls back to the service key). Owner decision: see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md rule 12";;
  wrongrole) pii_flag "BACKUP_READER_JWT does not carry role = backup_reader (a token for any other role, service_role included, must not be used for the backup)";;
  expired) pii_flag "BACKUP_READER_JWT has expired (exp is in the past): mint a new one";;
  notyet) pii_flag "BACKUP_READER_JWT is not valid yet (nbf is in the future): the database would refuse it tonight";;
  noexp) pii_flag "BACKUP_READER_JWT has no usable exp claim (missing, not a number, or not finite): a never-expiring backup token is refused, mint one with an expiry";;
  *) pii_flag "BACKUP_READER_JWT is not a decodable JWT (expected three base64url parts with a JSON payload, no duplicate claims, no NaN / Infinity)";;
esac
# BACKUP_GATEWAY_APIKEY (round 8, S6): the `apikey` header of the backup's calls. A Supabase gateway checks apikey against the PROJECT's API keys, so the reader JWT there is expected to be refused; the value
# to set is the project's anon / publishable key (public by design). Never the service / secret key. Only shape and role are checked, the value is never printed.
gw_state="$(GK="${BACKUP_GATEWAY_APIKEY:-}" SK="${HQ_SUPABASE_SERVICE_KEY:-}" python3 - <<'PY' 2>/dev/null || echo "unset"
import base64, json, os
k, svc = os.environ.get("GK", "").strip(), os.environ.get("SK", "").strip()
if not k:
    print("unset"); raise SystemExit
role = None
try:
    p = k.split(".")
    if len(p) == 3 and all(p):
        role = json.loads(base64.urlsafe_b64decode(p[1] + "=" * (-len(p[1]) % 4))).get("role")
except Exception:
    role = None
print("secret" if (svc and k == svc) or k.startswith("sb_secret_") or role not in (None, "anon") else "ok")
PY
)"
case "$gw_state" in
  ok) ok "BACKUP_GATEWAY_APIKEY is set and is not a service / secret key (sent as the apikey header; the reader token stays in Authorization). UNVERIFIED against the real gateway until the first /backup check";;
  secret) bad "BACKUP_GATEWAY_APIKEY is a service / secret key or a non-anon token: the backup refuses it. Use the project's anon / publishable key";;
  *) warn "BACKUP_GATEWAY_APIKEY is not set: the reader token is sent as the apikey header too. A Supabase-hosted project is expected to refuse that (HTTP 401): set it to the project's anon / publishable key";;
esac
# the event trigger that keeps the backup / redaction objects owner-only after later DDL (round 8, S4). The migration only WARNS when the platform does not let it create one; this is where that becomes
# visible: a missing or disabled trigger is a BLOCKING OWNER ACTION before the backup is activated.
if [ -n "$dburl" ] && command -v psql >/dev/null 2>&1; then
  ev="$(psql "$dburl" -Atqc "select coalesce((select (evtenabled in ('O','A'))::text || ' ' || (evtfoid = to_regprocedure('public.backup_acl_event()'))::text from pg_event_trigger where evtname = 'ffm_backup_acl_sweep'), 'absent')" 2>/dev/null)"
  case "$ev" in
    "true true") ok "event trigger ffm_backup_acl_sweep is present and enabled (new backup_* / redaction_* objects and later grants are swept back to owner-only)";;
    absent) pii_flag "BLOCKING OWNER ACTION: event trigger ffm_backup_acl_sweep is MISSING (the migration could not create it, or it was dropped). Ask the platform admin to run the create event trigger statement at the end of migrations/20261122_postlock_backup_identity_v2.sql - DO NOT ACTIVATE until this passes";;
    "") pii_flag "event trigger check could not run (database not reachable)";;
    *) pii_flag "BLOCKING OWNER ACTION: event trigger ffm_backup_acl_sweep is DISABLED or does not call backup_acl_event() (enabled / calls the sweep = $ev) - DO NOT ACTIVATE until this passes";;
  esac
else pii_flag "event trigger ffm_backup_acl_sweep: cannot check (set PII_CHECK_DB_URL, psql needed)"; fi
echo; echo "Result: $fails FAIL, $warns WARN."; echo "Not checked here (check by eye): bucket is Private; lifecycle rule set; BACKUP_KEY stored in 2 places; migration 20261113_backup_schema_v1.sql applied (the Telegram /backup check shows it)."
[ "$fails" = 0 ]
