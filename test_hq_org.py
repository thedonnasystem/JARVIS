import unittest
from unittest import mock
import hq, hq_engine as E, hq_commands as C

FULL = ("Add a Calgary wholesale researcher | kind: agent | gain: 3 qualified deals/mo, ~$6000 | cost: $4/week AI | "
        "time: 3 weeks | risk: noisy leads | alt: reuse the Ontario researcher | disagree: Ontario-only focus leaves Alberta deals untouched")


class T(unittest.TestCase):
    def test_parse_full_and_legacy(self):
        f = E.parse_proposal(FULL)
        self.assertEqual((f["kind"], f["time_to_results"], f["alternatives"]), ("agent", "3 weeks", "reuse the Ontario researcher"))
        self.assertIn("Alberta", f["disagrees_with_owner"])
        old = E.parse_proposal("Move auditors to the cheap model | gain: save $5/week | cost: none | risk: weaker audits")
        self.assertEqual((old["kind"], old["gain"], old["risk"]), ("improvement", "save $5/week", "weaker audits"))
        odd = E.parse_proposal("Do a thing now | kind: banana | extra words here | gain: g")
        self.assertEqual(odd["kind"], "improvement")
        self.assertIn("extra words here", odd["change"])

    def test_proposal_links_owner_message_to_org_change(self):
        calls = []

        def req(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if path.endswith("/org_changes"):
                return [{"id": "oc-1"}]
        t = {"id": "w", "assigned_agent": "jarvis", "title": "Weekly company self-review"}
        with mock.patch.object(hq, "_request", req):
            self.assertEqual(E._send_proposals(t, "PROPOSAL: " + FULL), 1)
        msg = [b for m, p, b in calls if p.endswith("/owner_messages")][0]
        self.assertEqual((msg["ref_table"], msg["ref_id"], msg["needs_decision"]), ("org_changes", "oc-1", True))
        self.assertIn("I disagree", msg["body"]); self.assertIn("Time to results: 3 weeks", msg["body"])

    def test_missing_table_still_sends_message(self):
        calls = []

        def req(method, path, body=None, timeout=30, prefer=None):
            calls.append(path)
            if path.endswith("/org_changes"):
                raise RuntimeError("404")
        t = {"id": "w", "assigned_agent": "jarvis", "title": "Weekly company self-review"}
        with mock.patch.object(hq, "_request", req):
            self.assertEqual(E._send_proposals(t, "PROPOSAL: " + FULL), 1)
        self.assertTrue(any(p.endswith("/owner_messages") for p in calls))

    def test_approval_opens_a_mission_and_rejection_does_not(self):
        for approved in (True, False):
            calls = []

            def req(method, path, body=None, timeout=30, prefer=None):
                calls.append((method, path, body))
                if "owner_messages" in path and method == "PATCH":
                    return [{"id": "m1", "ref_table": "org_changes", "ref_id": "oc-1", "body": "x"}]
                if path.startswith("/rest/v1/org_changes") and method == "GET":
                    return [{"kind": "agent", "change": "Add a Calgary researcher", "gain": "$6000", "cost": "$4/week"}]
            with mock.patch.object(hq, "_request", req), mock.patch.object(C.hq_missions, "create_mission", return_value={"id": "mi-1"}) as cm:
                C.apply_decision("m1", approved)
            patch = [b for m, p, b in calls if m == "PATCH" and "org_changes" in p][0]
            self.assertEqual(patch["status"], "approved" if approved else "rejected")
            self.assertEqual(cm.called, approved)
            if approved:
                self.assertIn("Calgary", cm.call_args[0][0])


if __name__ == "__main__":
    unittest.main()
