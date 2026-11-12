import asyncio, sys, types, unittest
from unittest import mock
import hq, hq_push as P


class Rec:
    def __init__(self, cfg=True, subs=2):
        self.calls = []; self.cfg = cfg; self.subs = subs

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if "push_config" in path:
            return [{"vapid_public": "pub", "vapid_private": "priv", "subject": "mailto:a@b.co"}] if self.cfg else [{"vapid_public": None, "vapid_private": None}]
        if "push_subscriptions" in path and method == "GET":
            return [{"endpoint": f"https://push.example/{i}", "p256dh": "k", "auth": "a"} for i in range(self.subs)]
        return None


def fake_lib(side=None):
    m = types.ModuleType("pywebpush")

    class WPE(Exception):
        def __init__(self, code):
            self.response = types.SimpleNamespace(status_code=code)
    m.WebPushException = WPE; m.sent = []

    def webpush(**kw):
        if side:
            r = side.pop(0)
            if r:
                raise WPE(r)
        m.sent.append(kw)
    m.webpush = webpush
    return m


class T(unittest.TestCase):
    def test_payload_is_short_and_labelled(self):
        p = P.payload_for({"kind": "proposal", "id": "x", "body": "A" * 500 + "\nB"})
        self.assertEqual((p["title"], len(p["body"]), p["urgent"]), ("Needs your decision", 140, False))
        self.assertTrue(P.payload_for({"kind": "emergency", "body": "x"})["urgent"])

    def test_sends_to_every_subscription_with_vapid_key(self):
        lib = fake_lib(); r = Rec()
        with mock.patch.dict(sys.modules, {"pywebpush": lib}), mock.patch.object(hq, "_request", r):
            self.assertEqual(P._send_all({"title": "t"}), 2)
        self.assertEqual(lib.sent[0]["vapid_private_key"], "priv")

    def test_dead_subscription_is_deleted(self):
        lib = fake_lib([410, None]); r = Rec()
        with mock.patch.dict(sys.modules, {"pywebpush": lib}), mock.patch.object(hq, "_request", r):
            self.assertEqual(P._send_all({"title": "t"}), 1)
        self.assertEqual(len([c for c in r.calls if c[0] == "DELETE"]), 1)

    def test_no_keys_or_no_library_is_silent(self):
        with mock.patch.dict(sys.modules, {"pywebpush": fake_lib()}), mock.patch.object(hq, "_request", Rec(cfg=False)):
            self.assertEqual(P._send_all({}), 0)
        with mock.patch.dict(sys.modules, {"pywebpush": None}):
            self.assertEqual(P._send_all({}), 0)

    def test_notify_never_raises(self):
        with mock.patch.object(P, "_send_all", side_effect=RuntimeError("x")):
            asyncio.run(P.notify({"kind": "money", "body": "b"}))


if __name__ == "__main__":
    unittest.main()
