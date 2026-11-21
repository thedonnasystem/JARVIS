"""Unit tests for Phase 1 M5: the shared services registry (/services) and the flag-gated scoped reads (hq_services)."""

import asyncio
import os
import unittest
from unittest import mock

import hq
import hq_commands
import hq_missions
import hq_services as svc

REPORT = {"scoped_reads_on": 1, "services": [
    {"service": "crm", "title": "Leads, replies and deals", "owner_office": "group", "writes": ["leads", "lead_replies", "deals"], "reads": ["ventures"],
     "data_classes": ["client_restricted", "internal"], "attribution": "column", "scoped_identity": "jarvis", "scoped_reads": True, "status": "active",
     "scoped_read_tables": ["ventures"], "rows": {"stamped": 3, "historical": 2}, "unstamped_since_start": 0, "offices": {"group": 4, "the-trap": 1}},
    {"service": "scheduler", "title": "Missions, tasks and the job queue", "owner_office": "group", "writes": ["jarvis_jobs"], "reads": ["missions", "tasks"],
     "data_classes": ["internal"], "attribution": "column", "scoped_identity": "jarvis", "scoped_reads": False, "status": "active",
     "scoped_read_tables": ["missions", "tasks"], "rows": None, "unstamped_since_start": 2, "offices": None},
    {"service": "payments", "title": "Payment instructions", "owner_office": "group", "writes": ["payment_instructions"], "reads": [], "data_classes": ["confidential"],
     "attribution": "derived", "scoped_identity": None, "scoped_reads": False, "status": "active", "scoped_read_tables": [], "rows": {"derived": 1}},
]}


class _Ident:
    calls = []

    def __init__(self, identity, require=False):
        _Ident.calls.append((identity, require))

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class ServicesTests(unittest.TestCase):
    def setUp(self):
        svc.reset_cache()
        _Ident.calls = []

    def test_flag_off_is_identical_to_the_service_key_read(self):
        with mock.patch.dict(os.environ, {svc.FLAG: ""}), mock.patch.object(hq, "_request", return_value=[{"id": 1}]) as rq, \
                mock.patch.object(hq, "as_identity", _Ident):
            self.assertEqual(svc.get("crm", "ventures?select=id"), [{"id": 1}])
        rq.assert_called_once_with("GET", "/rest/v1/ventures?select=id")       # not even the registry is read
        self.assertEqual(_Ident.calls, [])

    def test_flag_on_service_on_table_scoped_uses_the_identity_fail_closed(self):
        def fake(method, path, *a, **k):
            return REPORT if path.endswith("fz_services_report") else [{"id": 2}]
        with mock.patch.dict(os.environ, {svc.FLAG: "1"}), mock.patch.object(hq, "_request", side_effect=fake), mock.patch.object(hq, "as_identity", _Ident):
            self.assertEqual(svc.get("crm", "ventures?select=id"), [{"id": 2}])
        self.assertEqual(_Ident.calls, [("jarvis", True)])

    def test_flag_on_but_table_service_or_switch_not_eligible_keeps_the_service_key(self):
        def fake(method, path, *a, **k):
            return REPORT if path.endswith("fz_services_report") else []
        with mock.patch.dict(os.environ, {svc.FLAG: "1"}), mock.patch.object(hq, "_request", side_effect=fake), mock.patch.object(hq, "as_identity", _Ident):
            svc.get("crm", "leads?select=id")                 # crm on, but leads is not scoped-readable in M1
            svc.get("scheduler", "missions?select=id")        # scheduler: owner switch off
            svc.get("payments", "ventures?select=id")         # no scoped identity
            svc.get("unknown", "ventures?select=id")
        self.assertEqual(_Ident.calls, [])

    def test_report_unavailable_keeps_the_service_key(self):
        def fake(method, path, *a, **k):
            if path.endswith("fz_services_report"):
                raise RuntimeError("404")
            return []
        with mock.patch.dict(os.environ, {svc.FLAG: "1"}), mock.patch.object(hq, "_request", side_effect=fake), mock.patch.object(hq, "as_identity", _Ident):
            svc.get("crm", "ventures?select=id")
        self.assertEqual(_Ident.calls, [])

    def test_missing_token_raises_never_falls_back(self):
        def fake(method, path, *a, **k):
            return REPORT if path.endswith("fz_services_report") else [{"leak": True}]
        with mock.patch.dict(os.environ, {svc.FLAG: "1", hq.SCOPED_TOKENS_ENV: "{}"}), mock.patch.object(hq, "_request", side_effect=fake) as rq:
            with self.assertRaises(hq.ScopedTokenError):
                svc.get("crm", "ventures?select=id")
        self.assertEqual([c for c in rq.call_args_list if not c[0][1].endswith("fz_services_report")], [])

    def test_scheduler_reads_go_through_the_service(self):
        with mock.patch.dict(os.environ, {svc.FLAG: ""}), mock.patch.object(hq, "_request", return_value=None) as rq:
            self.assertEqual(hq_missions._get("missions?select=id"), [])
        rq.assert_called_once_with("GET", "/rest/v1/missions?select=id")
        with mock.patch.object(hq_missions.hq_services, "get", return_value=[{"id": 9}]) as g:
            self.assertEqual(hq_missions._get("tasks?select=id"), [{"id": 9}])
        g.assert_called_once_with("scheduler", "tasks?select=id")

    def test_text(self):
        with mock.patch.object(hq, "_request", return_value=REPORT) as rq:
            t = svc.services_text()
        self.assertEqual(rq.call_args[0][:2], ("POST", "/rest/v1/rpc/fz_services_report"))
        self.assertIn("Shared services: 3 (scoped reads on: 1;", t)
        self.assertIn("crm [active] owner group: Leads, replies and deals", t)
        self.assertIn("rows historical 2, stamped 3", t)
        self.assertIn("by office group 4, the-trap 1", t)
        self.assertIn("scoped reads ON via jarvis for ventures", t)
        self.assertIn("UNSTAMPED since start 2", t)
        self.assertIn("(no table M1 lets a scoped role read)", t)
        with mock.patch.object(hq, "_request", side_effect=RuntimeError("x")):
            self.assertIn("not installed", svc.services_text())

    def test_command_owner_only(self):
        upd = mock.MagicMock()
        with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock()) as rep:
            asyncio.run(hq_commands.hq_services_cmd(upd, mock.MagicMock()))
        rep.assert_not_called()
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock()) as rep, \
                mock.patch.object(hq, "_request", return_value=REPORT):
            asyncio.run(hq_commands.hq_services_cmd(upd, mock.MagicMock()))
        self.assertIn("Shared services", rep.call_args[0][1])
        self.assertIn("services", [m[0] for m in hq_commands.MENU])


if __name__ == "__main__":
    unittest.main()
