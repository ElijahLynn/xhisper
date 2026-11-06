#!/usr/bin/env python3
"""Exercise the real transcription function without network, secrets or clipboard."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "xhisper.sh").read_text()
FUNCTIONS = SOURCE[SOURCE.index("get_duration() {"):SOURCE.index("# Main\n")]


class TranscriptionTests(unittest.TestCase):
    def run_case(self, body, status="200", exit_code=0, error="", rotate=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text("""#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) printf '%s' "$MOCK_BODY" > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$MOCK_STATUS"
printf '%s' "$MOCK_ERROR" >&2
exit "$MOCK_EXIT"
""")
            curl.chmod(0o700)
            audio = root / "audio.wav"
            audio.write_bytes(b"\0" * 32044)
            if rotate:
                (root / "xhisper.log").write_text("x" * 1048576)
            environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                               MOCK_BODY=body, MOCK_STATUS=status,
                               MOCK_EXIT=str(exit_code), MOCK_ERROR=error)
            result = subprocess.run(
                ["bash", "-c", FUNCTIONS + """
RUNTIME_DIR=$1
LOGFILE=$1/xhisper.log
GROQ_API_KEY=TEST_SECRET
long_recording_threshold=1000
transcription_prompt=
transcribe "$1/audio.wav"
""", "test", directory],
                env=environment, capture_output=True, text=True,
            )
            logs = (root / "xhisper.log").read_text()
            self.assertNotIn("TEST_SECRET", logs)
            self.assertNotIn("private speech", logs)
            record = json.loads(logs.splitlines()[-1])
            self.assertRegex(record["timestamp"], r"^\d{4}-.*Z$")
            self.assertTrue(record["attempt"])
            self.assertEqual(record["audio_bytes"], 32044)
            self.assertIsInstance(record["request_ms"], int)
            self.assertGreaterEqual(record["request_ms"], 0)
            self.assertEqual(list(root.glob("xhisper-request.*")), [])
            self.assertEqual((root / "xhisper.log").stat().st_mode & 0o777, 0o600)
            if rotate:
                self.assertEqual((root / "xhisper.log.1").stat().st_size, 1048576)
                self.assertEqual((root / "xhisper.log.1").stat().st_mode & 0o777, 0o600)
            return result, record

    def test_success(self):
        result, record = self.run_case('{"text":" private speech"}')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "private speech\n")
        self.assertEqual(record["outcome"], "success")

    def test_transport_error(self):
        result, record = self.run_case("", "000", 6, "Could not resolve host")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(record["outcome"], "transport_error")
        self.assertEqual(record["curl_exit"], 6)

    def test_api_error(self):
        result, record = self.run_case(
            '{"error":{"code":"rate_limit_exceeded","message":"TEST_SECRET quota"}}',
            "429",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(record["outcome"], "api_error")
        self.assertEqual(record["http_status"], "429")
        self.assertEqual(record["api_code"], "rate_limit_exceeded")

    def test_invalid_response(self):
        result, record = self.run_case("<html>bad gateway</html>")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(record["outcome"], "invalid_response")

    def test_empty_transcription(self):
        for body in ('{"text":""}', '{"text":"   "}', '{"text":null}'):
            with self.subTest(body=body):
                result, record = self.run_case(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(record["outcome"], "empty_transcription")

    def test_rotation_and_bounded_error(self):
        result, record = self.run_case("", "000", 6, "x" * 2000, rotate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(record["error"]), 512)


if __name__ == "__main__":
    unittest.main()
