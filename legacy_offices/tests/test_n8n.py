"""n8n bridge: templates render and validate, imports are inactive, activation needs a confirmed one-time code.
Fake n8n API (no network); the templates are checked structurally, not imported into a live n8n.
Run from the repo root:  python3 -m unittest legacy_offices.tests.test_n8n"""
import json
import unittest

from legacy_offices import n8n

GOOD = {
    "webhook-to-telegram": {"name": "Pings", "path": "site-ping", "chat_id": "123456789"},
    "uptime-check": {"name": "Uptime", "url": "https://example.com/health", "chat_id": "123456789"},
    "form-to-sheet": {"name": "Leads", "form_title": "Get a quote", "sheet_id": "1AbCdEfGhIjKlMnOpQrStUvWxYz_012345"},
    "rss-digest": {"name": "News", "feed_url": "https://example.com/feed.xml", "chat_id": "123456789"},
}


class FakeN8n:
    def __init__(self):
        self.calls, self.wfs = [], {}

    def __call__(self, method, path, body=None, env=None, opener=None):
        self.calls.append((method, path, body))
        if method == "POST" and path == "/workflows":
            wid = f"w{len(self.wfs) + 1}"
            self.wfs[wid] = dict(body, id=wid, active=False)
            return self.wfs[wid]
        if method == "GET" and path == "/workflows":
            return {"data": list(self.wfs.values())}
        if path.endswith("/activate"):
            self.wfs[path.split("/")[2]]["active"] = True
            return {}
        if path.endswith("/deactivate"):
            self.wfs[path.split("/")[2]]["active"] = False
            return {}
        raise AssertionError(path)


class Templates(unittest.TestCase):
    def test_every_template_renders_valid_and_safe(self):
        tpls = n8n.templates()
        self.assertEqual(set(tpls), set(GOOD))
        for tid, t in tpls.items():
            self.assertEqual(n8n.missing_params(t, GOOD[tid]), [], tid)
            self.assertEqual(n8n.bad_params(t, GOOD[tid]), [], tid)
            wf = n8n.render(t, GOOD[tid])
            self.assertEqual(n8n.validate(wf), [], tid)
            blob = json.dumps(wf)
            self.assertNotIn("<<", blob)
            self.assertNotIn("credentials", blob)
            self.assertTrue(all(nd["type"] in n8n.ALLOWED_NODES for nd in wf["nodes"]))

    def test_numbers_stay_numbers(self):
        wf = n8n.render(n8n.templates()["uptime-check"], dict(GOOD["uptime-check"], hour="9"))
        self.assertEqual(wf["nodes"][0]["parameters"]["rule"]["interval"][0]["triggerAtHour"], 9)

    def test_validator_refuses_dangerous_or_broken_workflows(self):
        wf = n8n.render(n8n.templates()["webhook-to-telegram"], GOOD["webhook-to-telegram"])
        for mutate, why in [
            (lambda w: w["nodes"].append({"name": "Run", "type": "n8n-nodes-base.executeCommand", "parameters": {}}), "not on the allowed list"),
            (lambda w: w["nodes"].append({"name": "JS", "type": "n8n-nodes-base.code", "parameters": {}}), "not on the allowed list"),
            (lambda w: w["nodes"][1].update(credentials={"telegramApi": {"id": "1"}}), "credentials"),
            (lambda w: w.update(active=True), "inactive"),
            (lambda w: w["nodes"][1]["parameters"].update(chatId="<<chat_id>>"), "unfilled"),
            (lambda w: w["nodes"][0]["parameters"].update(path="http://x.example"), "https only"),
            (lambda w: w["connections"].update(Ghost={"main": [[{"node": "Nope"}]]}), "unknown node"),
        ]:
            w = json.loads(json.dumps(wf))
            mutate(w)
            self.assertTrue(any(why in p for p in n8n.validate(w)), why)

    def test_bad_params_refused(self):
        t = n8n.templates()["uptime-check"]
        self.assertTrue(n8n.bad_params(t, {"url": "http://plain.example"}))
        self.assertTrue(n8n.bad_params(t, {"chat_id": "{{ $env.SECRET }}"}))
        self.assertTrue(n8n.bad_params(t, {"evil": "x"}))


class Flow(unittest.TestCase):
    def setUp(self):
        n8n._pending.clear()
        self.api = FakeN8n()

    def test_new_imports_inactive_then_activation_needs_confirm(self):
        out = n8n.command(["new", "uptime-check", "name=Uptime", "url=https://example.com/health", "chat_id=123456789"], http=self.api)
        self.assertIn("Imported INACTIVE: w1", out)
        posted = self.api.calls[0][2]
        self.assertNotIn("active", posted)
        self.assertFalse(self.api.wfs["w1"]["active"])
        out = n8n.command(["activate", "w1"], http=self.api)
        self.assertFalse(self.api.wfs["w1"]["active"], "asking to activate changes nothing")
        code = out.split("/n8n confirm ")[1].split()[0]
        self.assertIn("no pending activation", n8n.command(["confirm", "000000"], http=self.api))
        self.assertIn("Activated workflow w1", n8n.command(["confirm", code], http=self.api))
        self.assertTrue(self.api.wfs["w1"]["active"])
        self.assertIn("no pending activation", n8n.command(["confirm", code], http=self.api), "single use")
        self.assertIn("Deactivated", n8n.command(["deactivate", "w1"], http=self.api))
        self.assertIn("inactive", n8n.command(["list"], http=self.api))

    def test_confirmation_expires(self):
        t = [1000.0]
        code = n8n.request_activation("w9", now=lambda: t[0])
        t[0] += n8n.CONFIRM_TTL + 1
        with self.assertRaises(n8n.N8nError):
            n8n.confirm_activation(code, http=self.api, now=lambda: t[0])

    def test_plain_words_use_keywords_without_a_brain_and_ask_for_missing(self):
        def refused(*a, **k):
            raise RuntimeError("ClientDataRefused: no self-hosted model")
        out = n8n.command(["new", "send", "me", "a", "telegram", "alert", "when", "my", "website", "is", "down"], http=self.api, complete=refused)
        self.assertIn("uptime-check", out)
        self.assertIn("chosen by keywords", out)
        self.assertIn("Missing: name, url, chat_id", out)
        self.assertEqual(self.api.calls, [], "nothing imported while parameters are missing")

    def test_brain_pick_is_declared_private_and_redacted(self):
        got = {}

        def brain(system, messages, **kw):
            got.update(kw, text=messages[0]["content"])
            return {"text": '{"template": "rss-digest", "params": {"feed_url": "https://example.com/feed.xml"}}'}
        tid, params, how = n8n.brain_pick("daily news digest from my feed, email me at jo@example.com", complete=brain)
        self.assertEqual((tid, how), ("rss-digest", "brain"))
        self.assertEqual(params["feed_url"], "https://example.com/feed.xml")
        self.assertEqual(got["sources"], ["system", "owner_request"])      # hq_llm routes this as private (self-hosted only)
        self.assertNotIn("jo@example.com", got["text"])

    def test_not_connected(self):
        self.assertIn("not connected", n8n.command(["list"], http=lambda *a, **k: n8n._http(*a, env={}, **k)))


if __name__ == "__main__":
    unittest.main()
