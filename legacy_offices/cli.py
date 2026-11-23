"""Local runner, same output as the Telegram commands:
  python3 -m legacy_offices.cli doctor <office>|all [plan]
  python3 -m legacy_offices.cli qc <office>|all
  python3 -m legacy_offices.cli dryrun <office>      the legacy repo's own dry-run / demo job in a local clone (runner.py)
  python3 -m legacy_offices.cli n8n <args>           same as /n8n (needs N8N_BASE_URL + N8N_API_KEY for list / new / activate)
Env: LEGACY_SRC_DIR (folder holding the clones), LEGACY_GITHUB_TOKEN (read-only), LEGACY_QC_STATE (aggregate history file),
FREELANCE_DB_PATH / DIALER_EVENTS_CSV / PAPER_DB_PATH (copies of the services' own data, read for counts only).
"""
from __future__ import annotations

import sys

from legacy_offices import commands, registry


def dryrun(name: str) -> str:
    slug = registry.resolve(name)
    if not slug:
        return "unknown office"
    o = registry.office(slug)
    dr = (o.get("legacy") or {}).get("dry_run")
    root = registry.checkout(slug)
    if not dr or not root:
        return f"{slug}: no dry run declared or no local clone (LEGACY_SRC_DIR)"
    from legacy_offices import runner
    r = runner.run(dr["cmd"], root, dr.get("cwd", "."), dr.get("env") or {}, 900)
    return f"{slug} dry run ({dr.get('note', '')}): {'PASS' if r['ok'] else 'FAIL'} rc={r['rc']}\n{r['out']}"


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "doctor":
        print(commands.doctor_text(rest))
    elif cmd == "qc":
        print(commands.qc_text(rest))
    elif cmd == "n8n":
        from legacy_offices import n8n
        print(n8n.command(rest))
    elif cmd == "dryrun" and rest:
        print(dryrun(rest[0]))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
