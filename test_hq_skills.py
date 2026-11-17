"""Restricted skill loader (auto-ship zone): a skill can compute but cannot import or patch protected modules, files, network or the database."""
import unittest

import hq_skills as S


class SkillLoaderTests(unittest.TestCase):
    def test_example_skill_runs(self):
        self.assertEqual(S.run("word_count", {"text": "good morning sir"}), {"words": 3})

    def test_refused_sources(self):
        bad = ["import hq_meter\ndef run(p):\n    return {}\n",
               "import os\ndef run(p):\n    return {}\n",
               "from hq_llm import eligible\ndef run(p):\n    return {}\n",
               "def run(p):\n    return __import__('hq_meter')\n",
               "def run(p):\n    return open('/etc/passwd').read()\n",
               "def run(p):\n    return ().__class__.__bases__[0].__subclasses__()\n",
               "def run(p):\n    return getattr(p, 'x')\n",
               "def run(p):\n    return eval('1')\n",
               "import importlib\ndef run(p):\n    return {}\n",
               "from . import x\ndef run(p):\n    return {}\n",
               "x = 1\n"]
        for src in bad:
            with self.assertRaises(S.SkillRefused, msg=src):
                S.load_source(src, "t")

    def test_runtime_import_is_also_blocked(self):
        run = S.load_source("import json\ndef run(p):\n    return {'x': json.dumps(p)}\n", "t")
        self.assertEqual(run({"a": 1}), {"x": '{"a": 1}'})

    def test_bad_names(self):
        for n in ("../hq_meter", "Hq", "a/b", ""):
            with self.assertRaises(S.SkillRefused):
                S.load(n)


if __name__ == "__main__":
    unittest.main()


class IsolationTests(unittest.TestCase):
    """RVJC2 B4 repros: the escapes that worked in-process now run in a child with an empty environment and none of our modules."""
    def test_escapes_cannot_reach_our_modules_or_the_environment(self):
        import hq_meter  # noqa: F401  (loaded in THIS process; the skill must not see it)
        import os
        os.environ["JARVIS_TEST_SECRET"] = "s"
        try:
            run = S.load_source("import enum\ndef run(p):\n    m = enum.sys.modules\n    return {'hq': sorted(k for k in m if k.startswith('hq')),"
                                " 'env': len(m['os'].environ) if 'os' in m else -1, 'path': [x for x in enum.sys.path if 'jcore' in x or 'wt' in x]}\n", "t")
            out = run({})
            self.assertEqual(out["hq"], []); self.assertLessEqual(out["env"], 1); self.assertEqual(out["path"], [])      # at most LC_CTYPE (PEP 538)
            run = S.load_source("import operator, json\ndef run(p):\n    g = operator.attrgetter('__glo' + 'bals__')(json.dumps)\n"
                                "    os = g['__builtins__']['__import__']('os')\n    return {'env': dict(os.environ)}\n", "t")
            self.assertEqual(set(run({})["env"]) - {"LC_CTYPE"}, set())
            run = S.load_source("import enum\ndef run(p):\n    return {'x': enum.sys.modules['hq_meter'] is not None}\n", "t")
            with self.assertRaises(S.SkillRefused):
                run({})
        finally:
            os.environ.pop("JARVIS_TEST_SECRET", None)

    def test_timeout_and_errors(self):
        with self.assertRaises(S.SkillRefused):
            S.load_source("def run(p):\n    return 1 // 0\n", "t")({})
        with self.assertRaises(S.SkillRefused):
            S.run_isolated("x = 1\n", "t", {})                        # no run()
        with self.assertRaises(S.SkillRefused):
            S.run_isolated("def run(p):\n    while True:\n        pass\n", "t", {}, timeout_s=1)      # CPU limit / timeout
