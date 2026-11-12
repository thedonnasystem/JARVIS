import io, json, os, unittest
from unittest import mock
import hq_voice as V


class T(unittest.TestCase):
    def test_limits(self):
        self.assertIn("minutes", V.too_long(500, 100)); self.assertIn("too large", V.too_long(10, 20_000_000)); self.assertIsNone(V.too_long(30, 1000))

    def test_off_without_key(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertFalse(V.configured()); self.assertIsNone(V.transcribe(b"abc"))

    def test_transcribe_ok_and_failure(self):
        class R(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *a): pass
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "k"}):
            with mock.patch("urllib.request.urlopen", return_value=R(json.dumps({"text": " hello there "}).encode())) as u:
                self.assertEqual(V.transcribe(b"audio"), "hello there")
                req = u.call_args[0][0]; self.assertIn("multipart/form-data", req.get_header("Content-type")); self.assertIn(b"whisper-1", req.data)
            with mock.patch("urllib.request.urlopen", side_effect=OSError("x")):
                self.assertIsNone(V.transcribe(b"audio"))


if __name__ == "__main__":
    unittest.main()
