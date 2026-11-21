"""Unit tests for the helper. Run with the helper's runtime:
    PythonHelper/.runtime/python/bin/python3 -B PythonHelper/tests/test_python_helper.py
"""

import json
import os
import subprocess
import sys
import unittest
from types import SimpleNamespace

import numpy as np

HELPER_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HELPER_ROOT)

from encore_helper.engines import _merge_subword_tokens, available_engines  # noqa: E402
from encore_helper.voice_conversion import split_points  # noqa: E402


class PythonHelperTests(unittest.TestCase):
    def test_short_audio_is_one_chunk(self):
        self.assertEqual(split_points(np.zeros(16000 * 10, np.float32), 16000), [(0, 160000)])

    def test_long_audio_is_cut_in_pauses_and_covers_everything(self):
        sr, rng = 16000, np.random.default_rng(0)
        speech = lambda s: rng.normal(0, 0.1, int(s * sr)).astype(np.float32)  # noqa: E731
        silence = lambda s: np.zeros(int(s * sr), np.float32)  # noqa: E731
        audio = np.concatenate([speech(12), silence(0.4), speech(9), silence(0.4), speech(14), silence(0.4), speech(11)])
        ranges = split_points(audio, sr)
        self.assertEqual(ranges[0][0], 0)
        self.assertEqual(ranges[-1][1], audio.size)
        for (a, b), (c, _) in zip(ranges, ranges[1:]):
            self.assertEqual(b, c)
            self.assertLess(np.abs(audio[b - 80:b + 80]).max(), 1e-6, "cut should land in silence")
        self.assertTrue(all(b - a <= 25 * sr for a, b in ranges))

    def test_subword_tokens_merge_into_words(self):
        t = lambda text, s, e: SimpleNamespace(text=text, start=s, end=e)  # noqa: E731
        words = _merge_subword_tokens([t(" Hel", 0.0, 0.2), t("lo", 0.2, 0.3), t(" world", 0.4, 0.8), t(".", 0.8, 0.85)])
        self.assertEqual([w["text"] for w in words], ["Hello", "world."])
        self.assertEqual((words[0]["start"], words[0]["end"]), (0.0, 0.3))

    def test_engine_table(self):
        supported, missing = available_engines()
        self.assertEqual(supported.get("chatterbox_vc"), ["voiceConversion"])
        self.assertIn("wordTimestamps", supported.get("whisper", []))

    def test_protocol_round_trip_keeps_stdout_clean(self):
        env = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/tmp"), "PYTHONPATH": HELPER_ROOT,
               "HF_HUB_OFFLINE": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        requests = [{"id": 1, "op": "hello"}, {"id": 2, "op": "nope"}, {"id": 3, "op": "unload", "model_id": "x"},
                    {"id": 4, "op": "synthesize", "model_id": "missing", "text": "hi", "output_path": "/tmp/x.wav"}]
        p = subprocess.Popen([sys.executable, "-s", "-B", "-m", "encore_helper"], env=env, text=True,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p.stdin.write("".join(json.dumps(r) + "\n" for r in requests))
        p.stdin.flush()
        replies = {}
        while len(replies) < len(requests):
            m = json.loads(p.stdout.readline())  # every stdout line must be protocol JSON
            if "event" not in m:
                replies[m["id"]] = m
        p.stdin.write(json.dumps({"id": 5, "op": "shutdown"}) + "\n")
        p.stdin.flush()
        self.assertEqual(p.wait(timeout=30), 0)
        self.assertEqual(replies[1]["result"]["protocol"], 1)
        self.assertEqual(replies[2]["error"]["code"], "unknown_op")
        self.assertEqual(replies[3]["result"]["was_loaded"], False)
        self.assertEqual(replies[4]["error"]["code"], "model_not_loaded")


if __name__ == "__main__":
    unittest.main()
