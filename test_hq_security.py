"""Unit tests for Phase 1 M4: the read-only /security report (hq_security)."""

import asyncio
import inspect
import unittest
from unittest import mock

import hq_commands
import hq_security as sec

REPORT = {
    "standing": ["table:public.audit_log:service_role:UPDATE"] + [f"table:public.t{i}:anon:INSERT" for i in range(9)],
    "unexpected": [{"item": "table:public.memory:fz_jarvis:DELETE", "status": "alerted"}], "expected_count": 117,
    "definer_changed": [{"function": "public.fz_money_report()", "changed_at": "2026-11-21T09:00:00Z"}],
    "definer_without_search_path": ["bad_fn()"], "rls_off": ["legacy_table"],
    "identities": [{"identity": "jarvis", "status": "active"}, {"identity": "office:donna:manager", "status": "dormant"}, {"identity": "x", "status": "revoked"}],
    "tokens_expiring": [{"identity": "jarvis", "expires_at": "2026-11-25T00:00:00Z", "expired": False}],
    "chain": {"ok": False, "checked": 1200, "break_count": 1, "gaps": 2, "reinitialised_at": "2026-11-21T08:00:00Z"},
    "alerts": [{"kind": "chain_break", "item": "changed:42", "at": "2026-11-21T10:00:00Z"}],
}


class SecurityTests(unittest.TestCase):
    def test_text(self):
        with mock.patch.object(sec.hq, "_request", return_value=REPORT) as rq:
            t = sec.security_text()
        self.assertEqual(rq.call_args[0][:2], ("POST", "/rest/v1/rpc/fz_security_report"))
        self.assertIn("Audit chain: BROKEN (1200 links checked, 1 finding(s), 2 gap(s))", t)
        self.assertIn("Chain re-initialised 2026-11-21T08:00", t)
        self.assertIn("STANDING findings: 10", t)
        self.assertIn("- table:public.audit_log:service_role:UPDATE", t)
        self.assertIn("- ... and 2 more", t)
        self.assertIn("Grants not on the reviewed list: 1 (list has 117)", t)
        self.assertIn("- table:public.memory:fz_jarvis:DELETE [alerted]", t)
        self.assertIn("Definer function changed: public.fz_money_report()", t)
        self.assertIn("without a pinned search_path: 1: bad_fn()", t)
        self.assertIn("Tables with RLS off: 1: legacy_table", t)
        self.assertIn("Identities: 1 active, 1 dormant, 1 revoked", t)
        self.assertIn("- token for jarvis expires 2026-11-25", t)
        self.assertIn("Alert 2026-11-21T10:00: chain_break changed:42", t)

    def test_clean_chain_and_not_installed(self):
        with mock.patch.object(sec.hq, "_request", return_value=dict(REPORT, chain={"ok": True, "checked": 5})):
            self.assertIn("Audit chain: OK (5 links checked)", sec.security_text())
        with mock.patch.object(sec.hq, "_request", side_effect=RuntimeError("404")):
            self.assertIn("not installed", sec.security_text())
        with mock.patch.object(sec.hq, "_request", return_value={}):
            self.assertIn("not installed", sec.security_text())

    def test_read_only(self):
        src = inspect.getsource(sec).split('"""', 2)[2]
        for forbidden in ("PATCH", "DELETE", "fz_owner_", "GRANT", "REVOKE", "fz_security_watch", "fz_revoke_identity", "fz_audit_chain_extend"):
            self.assertNotIn(forbidden, src)

    def test_command_registered_and_owner_only(self):
        self.assertIn("security", [m[0] for m in hq_commands.MENU])
        upd = mock.MagicMock()
        with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(sec, "security_text") as st:
            asyncio.run(hq_commands.hq_security_cmd(upd, mock.MagicMock()))
        st.assert_not_called()
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(sec, "security_text", return_value="S"), \
                mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock()) as rep:
            asyncio.run(hq_commands.hq_security_cmd(upd, mock.MagicMock()))
        self.assertEqual(rep.await_args[0][1], "S")


if __name__ == "__main__":
    unittest.main()
