#!/usr/bin/env python3
"""Calibrate old/current code, gate local latency, or benchmark live API latency.

The metric ends at paste dispatch, not actual editor delivery. Clipboard tools
are real; focus and recorder are simulated at the application's existing seams.
Native Wayland also verifies actual GTK delivery through a private virtual keyboard.
Invalid samples are recorded, never silently used.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from wayland_session import require_private_session


REPO = Path(__file__).resolve().parents[1]
FIXTURE = b"xhisper calibration clipboard fixture"
TRANSCRIPT = "xhisper synthetic calibration transcription"
NATIVE = os.environ.get("XHISPER_NESTED") == "1"
LOCAL_PHASES = (
    "startup", "stop", "transcribe-start", "silence", "focus", "clipboard-save",
    "transcribe-wait", "clipboard", "pad", "paste+restore",
)
REQUEST_PHASES = (
    "dns_ms", "tcp_connect_ms", "tls_ms", "transfer_setup_ms", "upload_ms",
    "upstream_wait_ms", "download_ms", "upload_complete_ms", "first_byte_ms", "total_ms",
)


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def focus():
    require_private_session()
    reply = subprocess.check_output([
        "gdbus", "call", "--session", "--timeout", "6",
        "--dest", "org.gnome.Shell", "--object-path", "/org/gnome/Shell",
        "--method", "org.gnome.Shell.Eval",
        "global.display.focus_window?.get_wm_class() ?? ''",
    ], text=True).strip()
    if not reply.startswith("(true,"):
        raise RuntimeError(f"Nested focus query failed: {reply}")
    return reply


def read_clipboard(display):
    if NATIVE:
        return subprocess.check_output([
            "timeout", "2", "wl-paste", "--no-newline", "--type",
            "text/plain;charset=utf-8",
        ], stderr=subprocess.DEVNULL)
    return subprocess.check_output([
        "timeout", "2", "xclip", "-out", "-selection", "clipboard",
        "-target", "UTF8_STRING",
    ], env=dict(os.environ, DISPLAY=display), stderr=subprocess.DEVNULL)


def write_clipboard(display, content):
    if NATIVE:
        run(["timeout", "2", "wl-copy", "--sensitive", "--type",
             "text/plain;charset=utf-8"], input=content)
        return
    run(["timeout", "2", str(REPO / "xhisperclip")],
        env=dict(os.environ, DISPLAY=display), input=content,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def describe(values):
    if not values:
        return None
    median = statistics.median(values)
    return {
        "count": len(values), "median_ms": round(median, 2),
        "p95_ms": round(sorted(values)[math.ceil(0.95 * len(values)) - 1], 2),
        "mad_ms": round(statistics.median(abs(value - median) for value in values), 2),
    }


def derive_budgets(samples):
    """Pilot noise envelopes, not universal latency SLOs or CI guarantees."""
    budgets = {}
    for path in ("wayland", "x11"):
        baseline = [sample["dispatch_ms"] for sample in samples
                    if sample["path"] == path and sample["version"] == "baseline"
                    and sample["valid"]]
        if len(baseline) < 40:
            budgets[path] = None
            continue
        rng = random.Random(0)
        medians, tails = [], []
        for _ in range(10000):
            batch = sorted(rng.choices(baseline, k=20))
            medians.append(statistics.median(batch))
            tails.append(batch[18])  # nearest-rank p95 of 20 samples
        budgets[path] = {
            "status": "provisional",
            "batch_size": 20,
            "median_ms": math.ceil(sorted(medians)[9899]),
            "p95_ms": math.ceil(sorted(tails)[9899]),
            "method": "99th percentile of 10000 bootstrap batches; seed=0; baseline only",
            "caveat": "Two rounds do not establish long-term noise; p95 especially uncertain",
        }
    return budgets


def within_budget(stats, limits):
    return (stats is not None and limits is not None
            and all(stats[metric] <= limits[metric] for metric in ("median_ms", "p95_ms")))


def parse_local_timing(stages):
    return {name: int(value) for name, value in re.findall(r"(\S+)=(\d+)ms", stages)
            if name in LOCAL_PHASES}


def phase_summary(samples, group, names):
    return {name: describe([sample.get(group, {}).get(name) for sample in samples
                            if isinstance(sample.get(group, {}).get(name), (int, float))])
            for name in names}


def print_phase_summary(label, summary):
    values = ", ".join(f"{name}={stats['median_ms']}/{stats['p95_ms']}"
                       for name, stats in summary.items() if stats is not None)
    if values:
        print(f"{label} median/p95 (ms): {values}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="d8e555176abd46f9791ad631f7d72223acdda74e")
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--rounds", type=int)
    parser.add_argument("--gate", action="store_true",
                        help="test current code against frozen budgets, never derive new limits")
    parser.add_argument("--live", action="store_true",
                        help="benchmark live Groq with normal pacing, not a latency gate")
    parser.add_argument("--editor", action="store_true",
                        help="open a disposable GTK editor inside the private Wayland session")
    parser.add_argument("--paths", nargs="+", choices=("wayland", "x11"),
                        help="default: wayland in the private session, otherwise private x11")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.paths = args.paths or (["wayland"] if NATIVE else ["x11"])
    current_only = args.gate or args.live
    args.rounds = args.rounds if args.rounds is not None else (1 if current_only else 2)
    if args.gate and args.live:
        parser.error("--live and --gate are mutually exclusive")
    if args.live and not os.environ.get("GROQ_API_KEY"):
        parser.error("live mode needs GROQ_API_KEY")
    if NATIVE:
        require_private_session()
    if "wayland" in args.paths and not NATIVE:
        parser.error("Wayland requires tests/wayland-session.sh; desktop access is forbidden")
    if args.editor and not NATIVE:
        parser.error("--editor requires the private native Wayland session")
    if args.samples < 2 or args.rounds < (1 if current_only else 2):
        parser.error("at least two samples and rounds are required")
    frozen = json.loads((REPO / "tests/perf-budget.json").read_text()) if args.gate else None
    if args.gate and (args.samples != frozen["batch_size"] or args.rounds != 1):
        parser.error("the frozen gate requires exactly one batch of 20 samples")
    revision = subprocess.check_output(
        ["git", "--no-pager", "-C", str(REPO), "rev-parse", args.baseline],
        text=True).strip()
    baseline = subprocess.check_output(
        ["git", "--no-pager", "-C", str(REPO), "show", f"{revision}:xhisper.sh"])
    current = (REPO / "xhisper.sh").read_bytes()
    if NATIVE and args.paths != ["wayland"]:
        parser.error("nested native mode permits only --paths wayland")
    session_display = os.environ.get("DISPLAY", "")
    restore_key = "fixture_restored"
    expected_focus = focus() if "wayland" in args.paths else "private Xvfb (simulated focus)"
    result = {
        "baseline_commit": revision,
        "current_sha256": hashlib.sha256(current).hexdigest(),
        "metric": "script invocation to mock paste dispatch; not editor delivery",
        "api": "live Groq (includes network)" if args.live else "mocked immediate response",
        "min_latency_ms": 450 if args.live else 0,
        "samples_per_round": args.samples, "rounds": args.rounds,
        "focus": expected_focus, "samples": [], "complete": False,
        "isolation": "private headless Mutter; X11 forbidden" if NATIVE else "private Xvfb",
        "delivery": "actual GTK buffer" if NATIVE else "mock dispatch only",
        "mode": "live" if args.live else "gate" if args.gate else "calibration",
    }
    xvfb = None
    editor = None
    editor_directory = None
    try:
        if args.editor:
            if NATIVE:
                editor_directory = tempfile.TemporaryDirectory(prefix="xhgtk.")
                editor_root = Path(editor_directory.name)
                (editor_root / "command").write_text('{"id": -1}')
                editor_command = [sys.executable, str(REPO / "tests/paste-delay.py"),
                                  "--editor", editor_directory.name]
                editor_id = "org.xhisper.PasteProbe"
            editor = subprocess.Popen(
                editor_command,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(50):
                expected_focus = focus()
                if editor_id in expected_focus:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Editor did not acquire focus; no samples collected")
            result["focus"] = expected_focus
        if NATIVE:
            reply = subprocess.check_output([
                "gdbus", "call", "--session", "--timeout", "6",
                "--dest", "org.gnome.Shell", "--object-path", "/org/gnome/Shell",
                "--method", "org.gnome.Shell.Eval",
                "const C=imports.gi.Clutter; "
                "global._xhisperKeyboard ??= global.stage.get_context().get_backend()"
                ".get_default_seat().create_virtual_device(C.InputDeviceType.KEYBOARD_DEVICE);"
                "const t=imports.gi.GLib.get_monotonic_time();"
                "global._xhisperKeyboard.notify_keyval(t,C.KEY_Shift_L,C.KeyState.PRESSED);"
                "global._xhisperKeyboard.notify_keyval(t,C.KEY_Shift_L,C.KeyState.RELEASED); 'ready'",
            ], text=True)
            if not reply.startswith("(true,"):
                raise RuntimeError(f"Virtual keyboard setup failed: {reply}")
        print(f"Actual focus: {expected_focus}", flush=True)
        with tempfile.TemporaryDirectory(prefix="xhcal.") as directory:
            root = Path(directory)
            for name in ("bin", "runtime", "home", "config/xhisper", "cache/xhisper"):
                (root / name).mkdir(parents=True)
            (root / "baseline.sh").write_bytes(baseline)
            (root / "current.sh").write_bytes(current)
            (root / "config/xhisper/xhisperrc").write_text(
                "insert-mode : paste\npaste-key : auto\n"
                + ("" if args.live else "min-latency : 0\n"))
            run(["espeak-ng", "-w", str(root / "speech-raw.wav"), TRANSCRIPT],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(root / "speech-raw.wav"),
                 "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(root / "speech.wav")])
            private_display = None
            if "x11" in args.paths:
                private_display = start_xvfb(root)
                xvfb = private_display[1]
                private_display = private_display[0]
            tools = {
                "curl": """#!/bin/bash
output=
while [ "$#" -gt 0 ]; do
  case "$1" in --output) output=$2; shift 2 ;; *) shift ;; esac
done
body='{"text":"xhisper synthetic calibration transcription"}'
if [ -n "$output" ]; then printf '%s' "$body" > "$output"; printf '200'
else printf '%s' "$body"; fi
""",
                "gdbus": """#!/bin/bash
case "$*" in *FocusedWindow*) printf '%s\\n' "$MOCK_FOCUS" ;; esac
""",
                "xhispertool": """#!/bin/bash
printf '%s %s\\n' "$1" "$EPOCHREALTIME" > "$KEY_FILE"
""",
                "notify-send": "#!/bin/bash\nexit 0\n",
            }
            if args.live:
                tools["curl"] = f'#!/bin/bash\nexec "{shutil.which("curl")}" "$@"\n'
            if NATIVE:
                if editor_directory is None:
                    raise RuntimeError("Native calibration requires --editor for buffer verification")
                tools["xhispertool"] += f"""
[ -z "${{XHISPER_TEST_DROP_KEYS:-}}" ] || exit 0
reply=$("{shutil.which('gdbus')}" call --session --timeout 6 --dest org.gnome.Shell \\
  --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \\
  'const C=imports.gi.Clutter, k=global._xhisperKeyboard, t=imports.gi.GLib.get_monotonic_time();
   k.notify_keyval(t,C.KEY_Control_L,C.KeyState.PRESSED);
   k.notify_keyval(t,C.KEY_v,C.KeyState.PRESSED);
   k.notify_keyval(t,C.KEY_v,C.KeyState.RELEASED);
   k.notify_keyval(t,C.KEY_Control_L,C.KeyState.RELEASED); "sent"') || exit 1
case "$reply" in "(true,"*) ;; *) exit 1 ;; esac
"""
            for tool in ("wl-copy", "wl-paste", "xclip", "xhisperclip"):
                if NATIVE and tool in ("xclip", "xhisperclip"):
                    tools[tool] = f"""#!/bin/bash
printf '{tool} FORBIDDEN\\n' >> "$ROUTE_FILE"
exit 90
"""
                    continue
                executable = str(REPO / tool) if tool == "xhisperclip" else shutil.which(tool)
                tools[tool] = f"""#!/bin/bash
"{executable}" "$@"
rc=$?
printf '{tool} %s\\n' "$rc" >> "$ROUTE_FILE"
exit "$rc"
"""
            for name, content in tools.items():
                path = root / "bin" / name
                path.write_text(content)
                path.chmod(0o700)
            (root / "bin/pw-record").symlink_to(shutil.which("sleep"))
            rejected_paths = set()
            for round_number in range(args.rounds):
                paths = list(args.paths)
                if round_number % 2:
                    paths.reverse()
                for path in paths:
                    if path in rejected_paths:
                        continue
                    display = session_display if path == "wayland" else private_display
                    print(f"ROUND {round_number + 1} PATH {path}", flush=True)
                    for pair in range(args.samples):
                        versions = ["current"] if current_only else ["baseline", "current"]
                        if (pair + round_number) % 2:
                            versions.reverse()
                        for version in versions:
                            if path == "wayland" and focus() != expected_focus:
                                raise RuntimeError("Actual focus changed; stopped before next sample")
                            if NATIVE:
                                sample_id = len(result["samples"])
                                (editor_root / "command.tmp").write_text(
                                    json.dumps({"id": sample_id}))
                                (editor_root / "command.tmp").replace(editor_root / "command")
                                for _ in range(100):
                                    state_file = editor_root / "state"
                                    state = json.loads(state_file.read_text()) if state_file.exists() else {}
                                    if state.get("id") == sample_id and state.get("text") == "":
                                        break
                                    time.sleep(0.01)
                                else:
                                    raise RuntimeError("GTK editor did not reset before sample")
                            write_clipboard(display, FIXTURE)
                            runtime = root / "runtime"
                            shutil.copyfile(root / "speech.wav", runtime / "xhisper.wav")
                            for name in ("keys", "routes", "xhisper.log"):
                                (runtime / name).write_text("")
                            for name in ("x11-apps", "x11-apps.pending"):
                                (root / "cache/xhisper" / name).write_text("")
                            recorder = subprocess.Popen(
                                [str(root / "bin/pw-record"), "600"])
                            (runtime / "xhisper-rec.pid").write_text(f"{recorder.pid}\n")
                            time.sleep(0.02)
                            environment = dict(
                                os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                                HOME=str(root / "home"),
                                GROQ_API_KEY=os.environ.get("GROQ_API_KEY", "") if args.live else "",
                                DISPLAY=display, XHISPER_SKIP_DAEMON="1",
                                XHISPER_RUNTIME_DIR=str(runtime),
                                XDG_CONFIG_HOME=str(root / "config"),
                                XDG_CACHE_HOME=str(root / "cache"),
                                XHISPERTOOL=str(root / "bin/xhispertool"),
                                XHISPERCLIP=str(root / "bin/xhisperclip"),
                                KEY_FILE=str(runtime / "keys"), ROUTE_FILE=str(runtime / "routes"),
                                MOCK_FOCUS=f"('calibration', 'calibration', '{path}')",
                            )
                            start = time.time_ns()
                            try:
                                process = subprocess.run(
                                    ["bash", str(root / f"{version}.sh")], env=environment,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                    timeout=10)
                            finally:
                                if recorder.poll() is None:
                                    recorder.terminate()
                                recorder.wait()
                            diagnostic = {}
                            stages = ""
                            for line in (runtime / "xhisper.log").read_text().splitlines():
                                if line.startswith("Timing:"):
                                    stages = line
                                try:
                                    event = json.loads(line)
                                except ValueError:
                                    continue
                                if isinstance(event, dict) and "outcome" in event:
                                    diagnostic = event
                            routes = (runtime / "routes").read_text().splitlines()
                            keys = (runtime / "keys").read_text().split()
                            expected_key = "paste"  # synthetic non-terminal focus for both paths
                            # X11 is entirely on Xvfb with a fixed simulated focus.
                            # Private compositor focus is verified on the Wayland path.
                            valid = (process.returncode == 0 and len(keys) == 2
                                     and keys[0] == expected_key)
                            local_ms = parse_local_timing(stages)
                            if version == "current":
                                valid &= {"silence", "focus", "clipboard-save"} <= local_ms.keys()
                            if path == "wayland":
                                valid &= (focus() == expected_focus
                                          and "wl-copy 0" in routes and "wl-paste 0" in routes
                                          and not any("xclip" in item or "xhisperclip" in item
                                                      for item in routes))
                            else:
                                valid &= ("xhisperclip 0" in routes
                                          and not any(item.startswith("wl-") for item in routes))
                            restored = read_clipboard(display) == FIXTURE
                            valid &= restored
                            delivered = None
                            if NATIVE:
                                state = json.loads((editor_root / "state").read_text())
                                delivered = (state["id"] == sample_id and
                                             (bool(state["text"]) if args.live
                                              else state["text"] == TRANSCRIPT))
                                valid &= delivered
                            sample = {
                                "round": round_number + 1, "pair": pair,
                                "path": path, "version": version, "valid": bool(valid),
                                "restored": restored, "exit": process.returncode, "routes": routes,
                                "delivered": delivered,
                                "request_ms": diagnostic.get("request_ms"),
                                "request_timing": diagnostic.get("request_timing", {}),
                                "local_ms": local_ms,
                                "outcome": diagnostic.get("outcome"),
                                "stages": stages,
                                "error": process.stderr.decode(errors="replace")[:1000],
                                "dispatch_ms": round((float(keys[1]) * 1e9 - start) / 1e6, 3)
                                if len(keys) == 2 else None,
                            }
                            result["samples"].append(sample)
                            if args.live:
                                print(f"{path} {pair + 1}: dispatch={sample['dispatch_ms']}ms "
                                      f"request={sample['request_ms']}ms "
                                      f"outcome={sample['outcome']} valid={bool(valid)}", flush=True)
                                print(f"  phases={json.dumps(sample['request_timing'], sort_keys=True)} "
                                      f"local_ms={json.dumps(local_ms, sort_keys=True)}", flush=True)
                            if not valid:
                                print("REJECTED", json.dumps(sample), flush=True)
                                if not routes:
                                    raise RuntimeError("Application exited before clipboard operations")
                        if (pair + 1) % 5 == 0:
                            print(f"  completed {pair + 1}/{args.samples} pairs", flush=True)
                        recent = result["samples"][-4:]
                        if len(recent) == 4 and all(
                                sample["path"] == path and not sample["valid"] for sample in recent):
                            print(f"Cannot establish native {path} route; skipping further samples",
                                  flush=True)
                            rejected_paths.add(path)
                            break
            result["summary"] = {}
            for path in args.paths:
                for version in (["current"] if current_only else ["baseline", "current"]):
                    samples = [sample for sample in result["samples"]
                               if sample["path"] == path and sample["version"] == version
                               and sample["valid"]]
                    result["summary"][f"{path}/{version}"] = {
                        "overall": describe([sample["dispatch_ms"] for sample in samples]),
                        "request": describe([sample["request_ms"] for sample in samples
                                             if sample["request_ms"] is not None]),
                        "request_timing": phase_summary(samples, "request_timing", REQUEST_PHASES),
                        "local_ms": phase_summary(samples, "local_ms", LOCAL_PHASES),
                        "rounds": [
                            describe([sample["dispatch_ms"] for sample in samples
                                      if sample["round"] == round_number + 1])
                            for round_number in range(args.rounds)
                        ],
                    }
            print(json.dumps({
                label: {key: value for key, value in summary.items()
                        if key not in ("request_timing", "local_ms")}
                for label, summary in result["summary"].items()
            }, indent=2), flush=True)
            for label, summary in result["summary"].items():
                print_phase_summary(f"{label} request phases", summary["request_timing"])
                print_phase_summary(f"{label} local stages", summary["local_ms"])
            if current_only:
                for sample in sorted(result["samples"],
                                     key=lambda item: item["dispatch_ms"] or 0,
                                     reverse=True)[:3]:
                    print(f"Slow sample: {sample['path']} {sample['dispatch_ms']}ms "
                          f"{sample['stages']}", flush=True)
            if not current_only:
                result["provisional_budgets"] = derive_budgets(result["samples"])
                print(json.dumps(result["provisional_budgets"], indent=2), flush=True)
            result["complete"] = all(
                sum(sample["path"] == path and sample["version"] == version
                    and sample["valid"] for sample in result["samples"])
                == args.samples * args.rounds
                for path in args.paths
                for version in (["current"] if current_only else ["baseline", "current"]))
            result["fixture_restored"] = bool(result["samples"]) and all(
                sample["restored"] for sample in result["samples"])
            if args.gate:
                result["budgets"] = frozen["budgets"]
                result["budget_passed"] = all(
                    within_budget(result["summary"][f"{path}/current"]["overall"],
                                  frozen["budgets"].get(path))
                    for path in args.paths)
                print(f"Frozen budget check: {result['budget_passed']}", flush=True)
            elif args.live:
                for path in args.paths:
                    stats = result["summary"][f"{path}/current"]["overall"]
                    label = "within" if stats and stats["median_ms"] <= 500 else "over"
                    print(f"{path}: median {label} 500ms live target (informational only).",
                          flush=True)
    finally:
        if xvfb is not None:
            xvfb.terminate()
            xvfb.wait(timeout=10)
        if editor is not None:
            editor.terminate()
            editor.wait(timeout=10)
        if editor_directory is not None:
            editor_directory.cleanup()
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Saved {args.output}; {restore_key}={result.get(restore_key)}", flush=True)
    return 0 if (result["complete"] and result.get(restore_key)
                 and result.get("budget_passed", True)) else 2


def start_xvfb(root):
    with (root / "display").open("w+") as display_file:
        process = subprocess.Popen(
            ["Xvfb", "-displayfd", str(display_file.fileno()), "-nolisten", "tcp"],
            pass_fds=(display_file.fileno(),), stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        for _ in range(100):
            display_file.seek(0)
            number = display_file.read().strip()
            if number:
                return f":{number}", process
            time.sleep(0.02)
        process.terminate()
        process.wait(timeout=10)
        raise RuntimeError("Private X server did not start")


if __name__ == "__main__":
    raise SystemExit(main())
