import unittest
from unittest import mock
import hq_succession as S


def fake(path, *a, **k):
    # hq._request("GET", url) -> rows by table
    if "ventures" in a[0] if a else False:
        pass
    return None


class T(unittest.TestCase):
    def test_build_no_secrets_and_gaps(self):
        data = {"ventures": [{"slug": "donna", "name": "Donna", "kind": "revenue", "status": "active", "primary_metric": "clients"}],
                "accounts_registry": [{"service": "Twilio", "purpose": "numbers", "login_email": "a@b.c", "vault_ref": None, "status": "active"},
                                      {"service": "Retell", "purpose": "password is hunter2", "login_email": "a@b.c", "vault_ref": "bw:retell", "status": "active"}],
                "tool_registry": [{"slug": "retell", "kind": "voice", "purpose": "calls", "monthly_cost_cents": 2500, "status": "active"}],
                "venture_assets": [], "venture_procedures": None}

        def req(method, path, *a, **k):
            for t, rows in data.items():
                if f"/rest/v1/{t}?" in path:
                    if rows is None:
                        raise RuntimeError("404")
                    return rows
            return []
        with mock.patch("hq._request", side_effect=req):
            t = S.build()
        self.assertIn("Donna", t); self.assertIn("NOT IN VAULT", t); self.assertIn("GAPS: accounts with no vault entry: Twilio", t)
        self.assertNotIn("hunter2", t); self.assertIn("withheld", t)
        self.assertIn("$25.00/month", t); self.assertIn("not available", t); self.assertIn("none recorded", t)


if __name__ == "__main__":
    unittest.main()
