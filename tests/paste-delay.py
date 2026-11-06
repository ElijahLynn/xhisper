#!/usr/bin/env python3
"""Real paste keys into a disposable GTK editor, isolated by default.

Run through bash tests/wayland-session.sh. Uses synthetic text and verifies the
GTK buffer. --interactive explicitly opts into desktop clipboard/key access,
and refuses to start if it cannot snapshot a supported text representation.
"""
import argparse
import json
import os
from pathlib import Path
import random
import re
import subprocess
import sys
import tempfile
import time
from wayland_session import require_private_session


APP_ID = "org.xhisper.PasteProbe"


def editor(directory):
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, GLib

    GLib.set_prgname(APP_ID)
    root = Path(directory)
    app = Gtk.Application(application_id=APP_ID)

    def activate(application):
        window = Gtk.ApplicationWindow(application=application)
        window.set_title("xhisper paste-delay probe — leave focused")
        window.set_default_size(640, 240)
        view = Gtk.TextView()
        window.set_child(view)
        buffer = view.get_buffer()
        last = None

        def poll():
            nonlocal last
            command = json.loads((root / "command").read_text())
            if command["id"] != last:
                buffer.set_text("")
                view.grab_focus()
                last = command["id"]
            start, end = buffer.get_bounds()
            state = {"id": last, "text": buffer.get_text(start, end, False)}
            temporary = root / "state.tmp"
            temporary.write_text(json.dumps(state))
            temporary.replace(root / "state")
            return True

        GLib.timeout_add(10, poll)
        window.present()
        view.grab_focus()

    app.connect("activate", activate)
    app.run([])


def nested_eval(expression):
    reply = subprocess.check_output([
        "gdbus", "call", "--session", "--timeout", "6",
        "--dest", "org.gnome.Shell", "--object-path", "/org/gnome/Shell",
        "--method", "org.gnome.Shell.Eval", expression,
    ], text=True).strip()
    if not reply.startswith("(true,"):
        raise RuntimeError(f"Nested shell Eval failed: {reply}")
    return reply


def focus():
    if os.environ.get("XHISPER_NESTED") == "1":
        return nested_eval("global.display.focus_window?.get_wm_class() ?? ''")
    return subprocess.check_output([
        "gdbus", "call", "--session", "--dest", "org.gnome.Shell",
        "--object-path", "/io/github/elijahlynn/XhisperIndicator",
        "--method", "io.github.elijahlynn.XhisperIndicator.FocusedWindow",
    ], text=True).strip()


def clipboard_read(*arguments):
    return subprocess.check_output(["timeout", "2", "wl-paste", *arguments],
                                   stderr=subprocess.DEVNULL)

def snapshot():
    try:
        types = clipboard_read("--list-types").decode().splitlines()
        mime = next((item for item in ("text/plain;charset=utf-8", "text/plain")
                     if item in types), None)
        if mime is not None:
            return mime, clipboard_read("--no-newline", "--type", mime), "wayland"
    except subprocess.CalledProcessError:
        pass
    # Read the real session's bridged X11 clipboard, not a private X server.
    original = subprocess.check_output([
        "timeout", "2", "xclip", "-out", "-selection", "clipboard", "-target", "UTF8_STRING",
    ], stderr=subprocess.DEVNULL)
    return "text/plain;charset=utf-8", original, "x11"


def probe(args):
    if os.environ.get("XHISPER_NESTED") == "1":
        require_private_session()
    elif not args.interactive:
        raise RuntimeError("Use tests/wayland-session.sh or explicitly opt in with --interactive")
    original = None
    mime = None
    process = None
    report = {"complete": False, "samples": [],
              "metric": "actual GTK buffer delivery; virtual keyboard in nested mode"}
    with tempfile.TemporaryDirectory(prefix="xhisper-paste-delay-") as directory:
        root = Path(directory)
        (root / "command").write_text('{"id": -1}')
        try:
            process = subprocess.Popen(
                [sys.executable, __file__, "--editor", directory],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env=dict(os.environ, GDK_BACKEND="wayland"))
            if os.environ.get("XHISPER_NESTED") == "1":
                nested_eval(
                    "Main.overview.hide(); const C = imports.gi.Clutter; "
                    "global._xhisperKeyboard = global.stage.get_context().get_backend().get_default_seat()"
                    ".create_virtual_device(C.InputDeviceType.KEYBOARD_DEVICE); "
                    "const t=imports.gi.GLib.get_monotonic_time(); "
                    "global._xhisperKeyboard.notify_keyval(t,C.KEY_Shift_L,C.KeyState.PRESSED);"
                    "global._xhisperKeyboard.notify_keyval(t,C.KEY_Shift_L,C.KeyState.RELEASED); 'ready'")
            print("Waiting for the disposable GTK editor to acquire focus.", flush=True)
            for _ in range(600):
                if (root / "state").exists() and APP_ID in focus():
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(
                    f"Probe did not acquire focus; no keys sent "
                    f"(process={process.poll()}, state={(root / 'state').exists()}, focus={focus()})")
            if os.environ.get("XHISPER_NESTED") == "1":
                # The disposable session starts without a clipboard owner.
                # Never invoke X11 fallback or snapshot the host clipboard here.
                subprocess.run(["timeout", "2", "wl-copy", "--sensitive", "--type",
                                "text/plain;charset=utf-8"], input=b"probe fixture", check=True)
                snapshot_route = "native-wayland-only"
                if clipboard_read("--no-newline", "--type",
                                  "text/plain;charset=utf-8") != b"probe fixture":
                    raise RuntimeError("Native clipboard smoke read did not match fixture")
            else:
                mime, original, snapshot_route = snapshot()
            print(f"clipboard_snapshot_route={snapshot_route}", flush=True)
            outcomes = {delay: [] for delay in args.delays}
            delays = list(outcomes) * args.runs
            random.Random(0).shuffle(delays)
            for index, delay in enumerate(delays):
                if APP_ID not in focus():
                    raise RuntimeError("Focus left probe; stopped before sending keys")
                (root / "command.tmp").write_text(json.dumps({"id": index}))
                (root / "command.tmp").replace(root / "command")
                for _ in range(100):
                    state = json.loads((root / "state").read_text())
                    if state["id"] == index and state["text"] == "":
                        break
                    time.sleep(0.01)
                else:
                    raise RuntimeError("Editor failed to reset")
                text = f"xhisper synthetic paste {index}"
                start = time.monotonic()
                subprocess.run(["timeout", "1", "wl-copy", "--sensitive",
                                "--type", "text/plain;charset=utf-8"],
                               input=text.encode(), check=True)
                copy_finished = time.monotonic()
                copy_ms = round((copy_finished - start) * 1000, 3)
                # No focus query here: that would add an unmeasured safety delay.
                if delay:
                    time.sleep(delay / 1000)
                if os.environ.get("XHISPER_NESTED") == "1":
                    reply = nested_eval(
                        "const C=imports.gi.Clutter, k=global._xhisperKeyboard, "
                        "t=imports.gi.GLib.get_monotonic_time(); "
                        "k.notify_keyval(t,C.KEY_Control_L,C.KeyState.PRESSED);"
                        "k.notify_keyval(t,C.KEY_v,C.KeyState.PRESSED);"
                        "k.notify_keyval(t,C.KEY_v,C.KeyState.RELEASED);"
                        "k.notify_keyval(t,C.KEY_Control_L,C.KeyState.RELEASED); 'sent:'+t")
                    enqueued = int(re.search(r"sent:(\d+)", reply).group(1)) / 1e6
                else:
                    enqueued = time.monotonic()
                    subprocess.run(["xhispertool", "paste"], check=True)
                interval_ms = round((enqueued - copy_finished) * 1000, 3)
                delivered = False
                for _ in range(50):
                    state = json.loads((root / "state").read_text())
                    if state["id"] == index and state["text"] == text:
                        delivered = True
                        break
                    time.sleep(0.01)
                if APP_ID not in focus():
                    raise RuntimeError("Focus changed during sample; result invalid")
                outcomes[delay].append(delivered)
                report["samples"].append({
                    "delay_ms": delay, "copy_ms": copy_ms,
                    "copy_return_to_key_enqueue_ms": interval_ms, "delivered": delivered,
                })
                print(f"delay={delay}ms copy={copy_ms}ms "
                      f"key_enqueue_gap={interval_ms}ms delivered={delivered}", flush=True)
            print("SUMMARY", {delay: f"{sum(results)}/{len(results)}"
                              for delay, results in outcomes.items()}, flush=True)
            report["complete"] = True
            report["passed"] = all(sample["delivered"] for sample in report["samples"])
        finally:
            try:
                if original is not None:
                    restore = subprocess.run(
                        ["timeout", "2", "wl-copy", "--sensitive", "--type", mime],
                        input=original)
                    if restore.returncode != 0:
                        subprocess.run(["timeout", "2", "xclip", "-in", "-selection",
                                        "clipboard", "-target", "UTF8_STRING"],
                                       input=original, check=True)
                    _, actual, _ = snapshot()
                    restored = actual == original
                    print(f"original_clipboard_restored={restored}", flush=True)
                    if not restored:
                        raise RuntimeError("Clipboard restoration verification failed")
            finally:
                if process is not None:
                    process.terminate()
                    process.wait(timeout=10)
                if args.output is not None:
                    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--editor":
        editor(sys.argv[2])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--interactive", action="store_true")
        parser.add_argument("--delays", nargs="+", type=int, default=[40])
        parser.add_argument("--runs", type=int, default=20)
        parser.add_argument("--output", type=Path)
        args = parser.parse_args()
        if args.runs < 1 or any(delay < 0 for delay in args.delays):
            parser.error("runs must be positive and delays nonnegative")
        raise SystemExit(probe(args))
