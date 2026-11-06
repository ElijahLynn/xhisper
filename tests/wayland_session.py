"""Accident guard: native tests must be launched by wayland-session.sh."""
import os
from pathlib import Path


def require_private_session():
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"))
    marker = runtime / ".xhisper-test-session"
    if (os.environ.get("XHISPER_NESTED") != "1"
            or os.environ.get("DISPLAY")
            or os.environ.get("WAYLAND_DISPLAY") != "xhisper-test"
            or not (runtime / "xhisper-test").is_socket()
            or not marker.is_file()
            or marker.read_text() != os.environ.get("DBUS_SESSION_BUS_ADDRESS")):
        raise RuntimeError("Use tests/wayland-session.sh; refusing to touch a desktop session")
