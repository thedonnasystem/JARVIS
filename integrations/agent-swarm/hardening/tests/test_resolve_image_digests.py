"""Offline tests for resolve_image_digests.py (parsing only; the registry is never contacted)."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import resolve_image_digests as r  # noqa: E402

D = "sha256:" + "a" * 64


class T(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(r.parse("postgres:16"), ("docker.io", "library/postgres", "16", None))
        self.assertEqual(r.parse("ubuntu/squid:6.6-24.04_edge"), ("docker.io", "ubuntu/squid", "6.6-24.04_edge", None))
        self.assertEqual(r.parse(f"ghcr.io/desplega-ai/agent-swarm:2.13.2@{D}"), ("ghcr.io", "desplega-ai/agent-swarm", "2.13.2", D))
        with self.assertRaises(ValueError):
            r.parse("not a ref!")

    def test_refs_from_real_files(self):
        refs = r.refs_from(os.path.join(ROOT, "docker-compose.hardened.yml"), os.path.join(ROOT, "worker", "Dockerfile.worker-hardened"), ["postgres:16"])
        kinds = [k for k, _ in refs]
        self.assertEqual(kinds.count("compose"), 4)            # api, worker-gate, egress-proxy, api-ingress (the worker image id is a local sha256: id)
        self.assertIn("dockerfile syntax", kinds)
        self.assertIn("dockerfile ARG", kinds)
        self.assertTrue(all("@sha256:" in ref for k, ref in refs if k != "extra"), refs)

    def test_placeholder_regex(self):
        self.assertTrue(r.ZERO.match("sha256:" + "0" * 64))
        self.assertFalse(r.ZERO.match(D))


if __name__ == "__main__":
    unittest.main()
