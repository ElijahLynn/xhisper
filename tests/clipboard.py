#!/usr/bin/env python3
"""Test preservation verification without accessing the session clipboard."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import importlib.util
import sys


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "calibrate_perf", Path(__file__).with_name("calibrate-perf.py"))
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)


class ClipboardTests(unittest.TestCase):
    def test_transcription_copy_is_sensitive_explicit_utf8(self):
        application = (Path(__file__).resolve().parents[1] / "xhisper.sh").read_text()
        copy_function = application[application.index("clip_set() {"):
                                    application.index("# Best type to save")]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "wl-copy"
            tool.write_text("""#!/bin/bash
printf '%s\\n' "$@" > "$PROBE_ROOT/arguments"
cat > "$PROBE_ROOT/content"
""")
            tool.chmod(0o700)
            result = subprocess.run(
                ["bash", "-c", copy_function + """
CLIP_XCLIP_ONLY=0
clip_set 'synthetic transcription'
"""],
                env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                         PROBE_ROOT=directory),
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "arguments").read_text().splitlines(),
                             ["--sensitive", "--type", "text/plain;charset=utf-8"])
            self.assertEqual((root / "content").read_text(), "synthetic transcription")

    def test_native_read_uses_fixed_mime_and_preserves_bytes(self):
        self.run_probe(False)

    def test_failed_native_read_is_an_error_not_empty_content(self):
        self.run_probe(True)

    def run_probe(self, fail):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "wl-paste"
            tool.write_text("""#!/bin/bash
if [ "$FAIL_READ" = 1 ]; then
  exit 2
elif [ "$3" = 'text/plain;charset=utf-8' ]; then
  printf 'synthetic plain text\\n'
else
  exit 3
fi
""")
            tool.chmod(0o700)
            with patch.object(calibration, "NATIVE", True), patch.dict(
                    os.environ, PATH=f"{root}:{os.environ['PATH']}", FAIL_READ=str(int(fail))):
                if fail:
                    with self.assertRaises(subprocess.CalledProcessError):
                        calibration.read_clipboard("")
                else:
                    self.assertEqual(calibration.read_clipboard(""), b"synthetic plain text\n")


if __name__ == "__main__":
    unittest.main()
