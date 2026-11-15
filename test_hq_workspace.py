import io, json, unittest, urllib.error
from unittest import mock
import hq_workspace as W


def http_err(msg):
    return urllib.error.HTTPError("u", 400, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))


class Screen(unittest.TestCase):
    def test_hit_raises_before_any_model_call(self):
        with mock.patch.object(W, "_rpc", return_value=["banking"]):
            with self.assertRaises(W.SensitiveDataRefused):
                W.screen("see bank statement")

    def test_clean_text_passes_and_empty_is_skipped(self):
        with mock.patch.object(W, "_rpc", return_value=[]) as m:
            W.screen("call about renewal", None, "")
        self.assertEqual(m.call_count, 1)

    def test_database_refusal_becomes_clear_exception(self):
        with mock.patch.object(W, "_rpc", side_effect=http_err("Sensitive data refused in ws_leads.note (credit)")):
            with self.assertRaises(W.SensitiveDataRefused):
                W.add_lead("w", None, "n", note="credit score 700")

    def test_other_errors_are_not_swallowed(self):
        with mock.patch.object(W, "_rpc", side_effect=http_err("workspace not found or not open")):
            with self.assertRaises(urllib.error.HTTPError):
                W.add_lead("w", None, "n")


class Classify(unittest.TestCase):
    def test_allowed_and_blocked_shapes(self):
        with mock.patch.object(W, "_rpc", return_value={"allowed": True, "reasons": ["approved_product_term"]}) as m:
            self.assertEqual(W.classify_text("health insurance", "ws-1"), {"allowed": True, "reasons": ["approved_product_term"]})
        self.assertEqual(m.call_args[0], ("ws_classify_text", {"p_text": "health insurance", "p_ws": "ws-1"}))
        with mock.patch.object(W, "_rpc", return_value={"allowed": False, "reasons": ["health", "health:residual"]}):
            self.assertEqual(W.classify_text("x")["allowed"], False)

    def test_fails_closed_on_odd_replies(self):
        for bad in (None, [], "true", {"reasons": []}, {"allowed": "true"}, {"allowed": 1}):
            with mock.patch.object(W, "_rpc", return_value=bad):
                self.assertFalse(W.classify_text("x", "w")["allowed"], bad)


if __name__ == "__main__":
    unittest.main()
