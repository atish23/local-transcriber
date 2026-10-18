#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

# Add current dir to path to import worker directly
sys.path.insert(0, str(Path(__file__).parent))
import worker

class TestWorkerLogic(unittest.TestCase):
    def test_collapse_repeated_phrase(self):
        # 3 or more repetitions
        text = "yeah yeah yeah"
        self.assertEqual(worker.collapse_repeated_phrase(text), "yeah")

        text2 = "thank you thank you thank you so much"
        self.assertEqual(worker.collapse_repeated_phrase(text2), "thank you so much")

        # No repetition
        text3 = "hello world how are you"
        self.assertEqual(worker.collapse_repeated_phrase(text3), "hello world how are you")

        # Two repetitions are retained
        text4 = "hello hello"
        self.assertEqual(worker.collapse_repeated_phrase(text4), "hello hello")

    def test_is_hallucination(self):
        self.assertTrue(worker.is_hallucination("thank you"))
        self.assertTrue(worker.is_hallucination("Thank you for watching."))
        self.assertTrue(worker.is_hallucination("Please subscribe"))
        self.assertTrue(worker.is_hallucination("Subtitles by Community"))
        self.assertTrue(worker.is_hallucination("..."))
        self.assertTrue(worker.is_hallucination("  "))

        self.assertFalse(worker.is_hallucination("We are discussing the payment settlement architecture."))
        self.assertFalse(worker.is_hallucination("ScreenCaptureKit captures both audio and microphone."))

    def test_apply_vocabulary_corrections(self):
        corrections = {
            "open ai": "OpenAI",
            "deep mind": "DeepMind",
            "u p i": "UPI"
        }
        text = "we are integrating with open ai and deep mind for u p i payments"
        corrected = worker.apply_vocabulary_corrections(text, corrections)
        self.assertEqual(corrected, "we are integrating with OpenAI and DeepMind for UPI payments")

    def test_clean_transcript_text(self):
        corrections = {"deepmind": "DeepMind"}
        # Hallucination discarded
        self.assertEqual(worker.clean_transcript_text("Thank you for watching.", corrections), "")
        # Real text with correction
        res = worker.clean_transcript_text("Discussing deepmind deployment today", corrections)
        self.assertEqual(res, "Discussing DeepMind deployment today")

class TestWorkerSubprocess(unittest.TestCase):
    def setUp(self):
        self.env = dict(os.environ)
        self.env["LOCAL_TRANSCRIBER_FAKE"] = "1"
        self.proc = subprocess.Popen(
            [sys.executable, str(Path(__file__).parent / "worker.py")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self.env
        )
        ready_line = self.proc.stdout.readline()
        ready_json = json.loads(ready_line)
        self.assertTrue(ready_json.get("ready"))

    def tearDown(self):
        if self.proc.stdin:
            self.proc.stdin.close()
        if self.proc.stdout:
            self.proc.stdout.close()
        if self.proc.stderr:
            self.proc.stderr.close()
        if self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(timeout=2)

    def send_request(self, req: dict) -> dict:
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        return json.loads(line)

    def test_ping(self):
        res = self.send_request({"command": "ping"})
        self.assertEqual(res.get("status"), "ok")

    def test_invalid_json(self):
        self.proc.stdin.write("INVALID JSON\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        res = json.loads(line)
        self.assertEqual(res.get("status"), "error")

    def test_unknown_command(self):
        res = self.send_request({"command": "something_random"})
        self.assertEqual(res.get("status"), "error")

    def test_transcribe_missing_file(self):
        res = self.send_request({
            "command": "transcribe_chunk",
            "audio_path": "/tmp/non_existent_file_12345.wav"
        })
        self.assertEqual(res.get("status"), "error")

    def test_fake_transcription(self):
        # Create temp file
        temp_audio = Path("/tmp/test_sample_audio.wav")
        temp_audio.write_bytes(b"RIFF dummy wav data")
        try:
            res = self.send_request({
                "command": "transcribe_chunk",
                "audio_path": str(temp_audio),
                "source": "microphone",
                "discard_before": 0.0
            })
            self.assertEqual(res.get("status"), "ok")
            segments = res.get("segments", [])
            self.assertGreaterEqual(len(segments), 1)
            self.assertEqual(segments[0]["source"], "microphone")
            self.assertIn("test_sample_audio", segments[0]["text"])
        finally:
            if temp_audio.exists():
                temp_audio.unlink()

if __name__ == "__main__":
    unittest.main()
