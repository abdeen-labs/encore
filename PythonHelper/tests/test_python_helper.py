"""Unit tests for the helper. Run with the helper's runtime:
    PythonHelper/.runtime/python/bin/python3 -B PythonHelper/tests/test_python_helper.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace

import numpy as np

HELPER_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HELPER_ROOT)

from encore_helper.engines import (  # noqa: E402
    LoadedModel, _join_prompt, _merge_subword_tokens, _whisper_temperatures, synthesize, transcribe)
from encore_helper.audio import write_wav_float32  # noqa: E402
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

    def test_voxcpm_clones_from_the_transcript_too(self):
        class FakeVoxCPM:
            calls = []

            def generate(self, text, ref_text=None, ref_audio=None, prompt_text=None, prompt_audio=None, verbose=False):
                self.calls.append(dict(text=text, ref_audio=ref_audio, prompt_audio=prompt_audio, prompt_text=prompt_text))
                yield SimpleNamespace(audio=np.zeros(480, np.float32), sample_rate=48000)

        job = SimpleNamespace(progress=lambda *a: None, check=lambda: None)
        model = FakeVoxCPM()
        loaded = LoadedModel("voxcpm2", "voxcpm2", "tts", "", model)
        with tempfile.TemporaryDirectory() as d:
            ref = os.path.join(d, "ref.wav")
            open(ref, "wb").close()
            base = {"text": "Good evening.", "output_path": os.path.join(d, "out.wav")}
            synthesize(loaded, {**base, "voice": {"reference_audio": ref, "reference_text": " Please let me know. "}}, job)
            synthesize(loaded, {**base, "voice": {"reference_audio": ref}}, job)
        with_text, without = model.calls
        self.assertEqual((with_text["ref_audio"], with_text["prompt_audio"]), (ref, ref))
        self.assertEqual(with_text["prompt_text"] + with_text["text"], "Please let me know. Good evening.")
        self.assertEqual((without["ref_audio"], without["prompt_audio"], without["prompt_text"]), (ref, None, None))

    def test_voxcpm_prompt_joins_without_a_space_in_cjk(self):
        self.assertEqual(_join_prompt("Hello there.", "Good evening."), "Hello there. ")
        self.assertEqual(_join_prompt("你好。", "晚上好"), "你好。")
        self.assertEqual(_join_prompt("Hello.", "晚上好"), "Hello.")

    def test_whisper_temperature_is_where_the_retries_start(self):
        self.assertEqual(_whisper_temperatures(0), (0.0, 0.2, 0.4, 0.6, 0.8, 1.0))
        self.assertEqual(_whisper_temperatures(0.4), (0.4, 0.6, 0.8, 1.0))
        self.assertEqual(_whisper_temperatures(1.0), (1.0,))

    def test_omnivoice_length_zero_means_automatic(self):
        class FakeOmniVoice:
            calls = []

            def generate(self, text, duration_s=None, num_steps=32, verbose=False):
                self.calls.append(dict(duration_s=duration_s, num_steps=num_steps))
                yield SimpleNamespace(audio=np.zeros(240, np.float32), sample_rate=24000)

        job = SimpleNamespace(progress=lambda *a: None, check=lambda: None)
        model = FakeOmniVoice()
        loaded = LoadedModel("omnivoice", "omnivoice", "tts", "", model)
        with tempfile.TemporaryDirectory() as d:
            for length in (0, 0.0, 4.5):
                synthesize(loaded, {"text": "Hi.", "output_path": os.path.join(d, "out.wav"),
                                    "params": {"duration_s": length, "num_steps": 16}}, job)
        self.assertEqual([c["duration_s"] for c in model.calls], [None, None, 4.5])
        self.assertTrue(all(c["num_steps"] == 16 for c in model.calls))

    def test_parakeet_pieces_overlap_by_15_seconds(self):
        class FakeParakeet:
            calls = []

            def generate(self, audio, chunk_duration=None, overlap_duration=2.0, chunk_callback=None):
                self.calls.append((chunk_duration, overlap_duration))
                return SimpleNamespace(text="", sentences=[])

        job = SimpleNamespace(progress=lambda *a: None, check=lambda: None)
        model = FakeParakeet()
        loaded = LoadedModel("parakeet", "parakeet", "stt", "", model)
        with tempfile.TemporaryDirectory() as d:
            long, short = os.path.join(d, "long.wav"), os.path.join(d, "short.wav")
            write_wav_float32(long, np.zeros(16000 * 130, np.float32), 16000)
            write_wav_float32(short, np.zeros(16000 * 30, np.float32), 16000)
            transcribe(loaded, {"audio_path": long}, job)
            transcribe(loaded, {"audio_path": long, "params": {"chunk_duration": 300}}, job)
            transcribe(loaded, {"audio_path": long, "params": {"chunk_duration": 20}}, job)
            transcribe(loaded, {"audio_path": short}, job)
        self.assertEqual(model.calls, [(120.0, 15.0), (300, 15.0), (20, 5.0), (None, 2.0)])

    def test_subword_tokens_merge_into_words(self):
        t = lambda text, s, e: SimpleNamespace(text=text, start=s, end=e)  # noqa: E731
        words = _merge_subword_tokens([t(" Hel", 0.0, 0.2), t("lo", 0.2, 0.3), t(" world", 0.4, 0.8), t(".", 0.8, 0.85)])
        self.assertEqual([w["text"] for w in words], ["Hello", "world."])
        self.assertEqual((words[0]["start"], words[0]["end"]), (0.0, 0.3))

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
        self.assertIn("result", replies[1])
        self.assertEqual(replies[2]["error"]["code"], "unknown_op")
        self.assertEqual(replies[3]["result"]["was_loaded"], False)
        self.assertEqual(replies[4]["error"]["code"], "model_not_loaded")


if __name__ == "__main__":
    unittest.main()
