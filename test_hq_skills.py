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
