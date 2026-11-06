#!/bin/bash
# Run tests in a disposable headless Mutter, never the desktop's bus or sockets.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for tool in gnome-shell dbus-run-session gsettings gdbus setsid python3 wl-copy wl-paste; do
  command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 2; }
done
W=$(mktemp --directory /tmp/xhwl.XXXXXX)
KEEPER=""
cleanup() {
  if [ -n "$KEEPER" ]; then
    kill -- "-$KEEPER" 2>/dev/null || true
    wait "$KEEPER" 2>/dev/null || true
  fi
  if mountpoint --quiet "$W/runtime/doc"; then
    fusermount3 --unmount "$W/runtime/doc" || return
  fi
  rm --recursive --force -- "$W"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir --parents "$W"/{runtime,data,cache,config,state}
chmod 700 "$W/runtime"
export XDG_RUNTIME_DIR="$W/runtime" XDG_DATA_HOME="$W/data"
export XDG_CACHE_HOME="$W/cache" XDG_CONFIG_HOME="$W/config" XDG_STATE_HOME="$W/state"
unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_ACTIVATION_TOKEN DESKTOP_STARTUP_ID
export NO_AT_BRIDGE=1 GTK_A11Y=none GVFS_DISABLE_FUSE=1 GDK_BACKEND=wayland
EXT="$W/data/gnome-shell/extensions/xhisper-test@local"
mkdir --parents "$EXT"
cat > "$EXT/metadata.json" <<'EOF'
{"uuid":"xhisper-test@local","name":"xhisper isolated test","description":"Private test session only","shell-version":["46","47","48","49","50","51"]}
EOF
cat > "$EXT/extension.js" <<'EOF'
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
export default class XhisperTest extends Extension {
    enable() { global.context.unsafe_mode = true; }
    disable() { global.context.unsafe_mode = false; }
}
EOF
export XHISPER_BUSFILE="$W/bus"
cat > "$W/session.sh" <<'EOF'
#!/bin/bash
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.shell enabled-extensions "['xhisper-test@local']"
printf '%s' "$DBUS_SESSION_BUS_ADDRESS" > "$XHISPER_BUSFILE"
exec gnome-shell --headless --virtual-monitor 1280x720 --wayland \
  --no-x11 --wayland-display xhisper-test
EOF
setsid dbus-run-session -- bash "$W/session.sh" > "$W/shell.log" 2>&1 &
KEEPER=$!
for ((i=0; i<100; i++)); do
  [ -s "$W/bus" ] && break
  kill -0 "$KEEPER" 2>/dev/null || break
  sleep 0.1
done
if [ ! -s "$W/bus" ]; then
  printf 'Private session failed to start:\n' >&2
  cat "$W/shell.log" >&2
  exit 2
fi
DBUS_SESSION_BUS_ADDRESS=$(< "$W/bus")
export DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY=xhisper-test XHISPER_NESTED=1
ready=0
for ((i=0; i<100; i++)); do
  reply=$(gdbus call --session --timeout 1 --dest org.gnome.Shell \
    --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \
    'Main.overview.hide(); global.context.unsafe_mode' 2>/dev/null) || reply=""
  if [ "$reply" = "(true, 'true')" ]; then ready=1; break; fi
  kill -0 "$KEEPER" 2>/dev/null || break
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  printf 'Private compositor did not become ready:\n' >&2
  cat "$W/shell.log" >&2
  exit 2
fi
printf '%s' "$DBUS_SESSION_BUS_ADDRESS" > "$W/runtime/.xhisper-test-session"
printf 'Private native Wayland session ready (Xwayland disabled).\n'
if [ "$#" = 0 ]; then
  python3 "$REPO/tests/paste-delay.py"
else
  "$@"
fi
status=$?
if [ "$status" != 0 ]; then
  printf 'Test failed with exit status %s.\n' "$status" >&2
fi
exit "$status"
