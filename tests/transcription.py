#!/usr/bin/env python3
"""Exercise the real transcription function without network, secrets or clipboard."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "xhisper.sh").read_text()
FUNCTIONS = SOURCE[SOURCE.index("get_duration() {"):SOURCE.index("# Main\n")]


class TranscriptionTests(unittest.TestCase):
    def run_case(self, body, status="200", exit_code=0, error="", rotate=False, timings="", prompt=""):
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
[ -z "$MOCK_TIMINGS" ] || printf '\\n%s' "$MOCK_TIMINGS"
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
                               MOCK_EXIT=str(exit_code), MOCK_ERROR=error,
                               MOCK_TIMINGS=timings, MOCK_PROMPT=prompt)
            result = subprocess.run(
                ["bash", "-c", FUNCTIONS + """
RUNTIME_DIR=$1
LOGFILE=$1/xhisper.log
GROQ_API_KEY=TEST_SECRET
long_recording_threshold=1000
transcription_prompt=$MOCK_PROMPT
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

    def test_prompt_echo_is_not_a_transcription(self):
        result, record = self.run_case('{"text":" Claude, Warp, Strata, GitHub."}',
                                       prompt="Claude, Warp, Strata, GitHub, Groq")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(record["outcome"], "prompt_echo")

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

    def test_request_phases_are_intervals_not_cumulative_totals(self):
        _, record = self.run_case('{"text":"private speech"}',
                                 timings="0.010\t0.040\t0.090\t0.100\t0.120\t0.420\t0.430")
        self.assertEqual(record["request_timing"], {
            "dns_ms": 10, "tcp_connect_ms": 30, "tls_ms": 50,
            "transfer_setup_ms": 10, "upload_ms": 20, "upstream_wait_ms": 300,
            "download_ms": 10, "upload_complete_ms": 120,
            "first_byte_ms": 420, "total_ms": 430,
        })

    def test_missing_timings_do_not_break_success(self):
        result, record = self.run_case('{"text":"private speech"}')
        self.assertEqual(result.returncode, 0)
        self.assertTrue(record["request_timing"])
        self.assertTrue(all(value is None for value in record["request_timing"].values()))

    def test_unavailable_upload_timing_does_not_invent_upstream_wait(self):
        result, record = self.run_case(
            '{"text":"private speech"}',
            timings="0.010\t0.040\t0.090\t0.100\t\t0.420\t0.430")
        self.assertEqual(result.returncode, 0)
        timing = record["request_timing"]
        self.assertIsNone(timing["upload_ms"])
        self.assertIsNone(timing["upstream_wait_ms"])
        self.assertEqual(timing["first_byte_ms"], 420)

    def test_inverted_or_malformed_timings_are_not_negative_or_trusted(self):
        _, record = self.run_case(
            '{"text":"private speech"}',
            timings="NaN\t-1\tInfinity\t0.100\t0.500\t0.420\t0.430")
        timing = record["request_timing"]
        for key in ("dns_ms", "tcp_connect_ms", "tls_ms", "transfer_setup_ms",
                    "upstream_wait_ms"):
            self.assertIsNone(timing[key])
        self.assertEqual(timing["upload_ms"], 400)
        self.assertEqual(timing["download_ms"], 10)

    def test_older_curl_timing_warning_does_not_fail_transcription(self):
        result, record = self.run_case(
            '{"text":"private speech"}',
            error="curl: unknown --write-out variable: 'time_posttransfer'",
            timings="0.010\t0.040\t0.090\t0.100\t\t0.420\t0.430")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(record["outcome"], "success")
        self.assertEqual(record["http_status"], "200")
        self.assertEqual(record["error"], "")
        self.assertIsNone(record["request_timing"]["upstream_wait_ms"])

    def test_failure_keeps_only_reached_phases(self):
        _, record = self.run_case(
            "", "000", 6, "Could not resolve host",
            timings="0.010\t0\t0\t0\t0\t0\t0.011")
        self.assertEqual(record["outcome"], "transport_error")
        self.assertEqual(record["request_timing"]["dns_ms"], 10)
        self.assertIsNone(record["request_timing"]["tcp_connect_ms"])
        self.assertIsNone(record["request_timing"]["upstream_wait_ms"])
        self.assertEqual(record["request_timing"]["total_ms"], 11)

    def test_local_stage_marks_measure_each_real_call_site(self):
        marks = SOURCE[SOURCE.index('TIMING=""; T_LAST=$T0'):
                       SOURCE.index('REC_PID_FILE="$RUNTIME_DIR/xhisper-rec.pid"')]
        calls = SOURCE[SOURCE.index('  if is_silent "$RECORDING"; then'):
                       SOURCE.index('  wait "$TRANSCRIBE_PID"')]
        result = subprocess.run(["bash", "-c", """
T0=$(date +%s%N)
is_silent() { sleep 0.02; return 1; }
focus_query() { sleep 0.03; }
clip_save() { sleep 0.04; }
insert_mode=paste
RECORDING=unused
""" + marks + calls + '\nprintf "%s\\n" "$TIMING"\n'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        stages = dict((name, int(value))
                      for name, value in re.findall(r"(\S+)=(\d+)ms", result.stdout))
        for name, minimum in (("silence", 20), ("focus", 30), ("clipboard-save", 40)):
            self.assertGreaterEqual(stages[name], minimum)
        self.assertNotIn("silence+focus+clipboard-save", stages)

    def test_local_clock_falls_back_when_builtin_is_unavailable(self):
        marks = SOURCE[SOURCE.index('TIMING=""; T_LAST=$T0'):
                       SOURCE.index('REC_PID_FILE="$RUNTIME_DIR/xhisper-rec.pid"')]
        result = subprocess.run(
            ["bash", "-c", 'unset EPOCHREALTIME\nT0=$(date +%s%N)\n' + marks
             + 'sleep 0.02\nmark fallback\nprintf "%s\\n" "$TIMING"\n'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^fallback=\d+ms ")
        self.assertGreaterEqual(int(re.search(r"=(\d+)ms", result.stdout).group(1)), 20)


if __name__ == "__main__":
    unittest.main()
