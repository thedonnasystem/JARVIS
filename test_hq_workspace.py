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


if __name__ == "__main__":
    unittest.main()
