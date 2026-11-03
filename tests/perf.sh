#!/bin/bash
# xhisper performance gate: time from the stop key press until the paste key is sent,
# for both clipboard paths, using the real script and real Groq transcription.
#
#   wayland  GUI app: wl-copy/wl-paste in your real session (GNOME needs a keyboard
#            seat for wl-copy, which a headless compositor doesn't have). xhisper
#            saves and restores your clipboard; this test checks it's unchanged.
#   x11      X11 app such as Warp: xclip against a private Xvfb server.
#
# Nothing is ever pasted or typed: a stand-in xhispertool records when the paste key
# would be sent. Fails if a path's median is over XHISPER_PERF_MAX_MS (500), or the
# two paths' medians differ by more than XHISPER_PERF_MAX_SPREAD_MS (50).
#
# usage: tests/perf.sh            (or: make perf)
#   XHISPER_PERF_RUNS=5           runs per path (median is what counts)

set -u
MAX_MS=${XHISPER_PERF_MAX_MS:-500}
MAX_SPREAD_MS=${XHISPER_PERF_MAX_SPREAD_MS:-50}
RUNS=${XHISPER_PERF_RUNS:-5}
REPO=$(cd "$(dirname "$0")/.." && pwd)

die() { echo "perf: $*" >&2; exit 2; }
for c in espeak-ng ffmpeg Xvfb xclip wl-copy wl-paste curl jq; do
  command -v "$c" >/dev/null || die "missing dependency: $c"
done
[ -n "${WAYLAND_DISPLAY:-}" ] || die "needs a Wayland session (WAYLAND_DISPLAY unset)"
grep -q '^GROQ_API_KEY=' "$HOME/.env" 2>/dev/null || [ -n "${GROQ_API_KEY:-}" ] ||
  die "needs GROQ_API_KEY (env or ~/.env)"

W=$(mktemp -d /tmp/xhp.XXXX)  # short path: Unix socket names are capped at 108 chars
XVFB_PID=""
cleanup() { [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/bin" "$W/cfg/xhisper" "$W/cache/xhisper" "$W/rt"

# Settings under test: the defaults, in paste mode.
printf 'insert-mode : paste\npaste-key : auto\n' > "$W/cfg/xhisper/xhisperrc"

# A synthesized speech clip (generated, so no recording is stored in the repo).
espeak-ng -v en-us -s 170 -w "$W/tts.wav" \
  "This is a short dictation used to measure how quickly the text appears after the recording stops." \
  || die "espeak-ng failed"
ffmpeg -loglevel error -y -i "$W/tts.wav" -ac 1 -ar 16000 -c:a pcm_s16le "$W/speech.wav" || die "ffmpeg failed"

# Stand-ins. pw-record: a long sleep the script can stop (named pw-record so the
# script's process check recognizes it). xhispertool: records the paste key and time.
ln -s "$(command -v sleep)" "$W/bin/pw-record"
cat > "$W/bin/xhispertool" <<EOF
#!/bin/bash
echo "\$1 \$EPOCHREALTIME" >> "$W/keys"
EOF
cat > "$W/bin/gdbus" <<'EOF'
#!/bin/bash
case "$*" in *FocusedWindow*) echo "$XHISPER_PERF_FOCUS" ;; esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$W/bin/notify-send"
chmod +x "$W/bin/xhispertool" "$W/bin/gdbus" "$W/bin/notify-send"

# Private X server for the xclip path.
for n in $(seq 90 120); do [ -e "/tmp/.X11-unix/X$n" ] || { XNUM=$n; break; }; done
Xvfb ":$XNUM" -nolisten tcp >/dev/null 2>&1 &
XVFB_PID=$!
for _ in $(seq 50); do [ -e "/tmp/.X11-unix/X$XNUM" ] && break; sleep 0.05; done

clipboard_fingerprint() {  # type list + content hash; never prints the content
  local types; types=$(timeout 1 wl-paste --list-types 2>/dev/null) || { echo empty; return; }
  local t; t=$(printf '%s\n' "$types" | head -1)
  printf '%s|%s' "$(printf '%s' "$types" | md5sum | cut -c1-8)" \
    "$(timeout 1 wl-paste --no-newline --type "$t" 2>/dev/null | md5sum | cut -c1-8)"
}

# One dictation: returns "latency_ms key". $1 = path name.
run_once() {
  local path="$1" focus extra_env=()
  if [ "$path" = x11 ]; then
    focus="('dev.warp.Warp', 'dev.warp.Warp.desktop')"
    echo dev.warp.Warp > "$W/cache/xhisper/x11-apps"   # Warp already learned as X11
  else
    focus="('org.gnome.TextEditor', 'org.gnome.TextEditor.desktop')"
    : > "$W/cache/xhisper/x11-apps"
  fi
  cp "$W/speech.wav" "$W/rt/xhisper.wav"
  "$W/bin/pw-record" 600 &
  echo $! > "$W/rt/xhisper-rec.pid"
  sleep 0.1  # let it exec, so its process name is pw-record
  : > "$W/keys"

  local t0=$EPOCHREALTIME
  env PATH="$W/bin:$PATH" DISPLAY=":$XNUM" XHISPER_RUNTIME_DIR="$W/rt" XHISPER_SKIP_DAEMON=1 \
      XHISPERTOOL="$W/bin/xhispertool" XDG_CONFIG_HOME="$W/cfg" XDG_CACHE_HOME="$W/cache" \
      XHISPER_PERF_FOCUS="$focus" bash "$REPO/xhisper.sh" >/dev/null 2>&1
  local line; line=$(grep -m1 -E '^paste(shift)? ' "$W/keys") || { echo "FAIL nokey"; return; }
  local key=${line%% *} t1=${line##* }
  echo "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%d", (b - a) * 1000 }') $key"
}

median() { sort -n | awk '{ a[NR] = $1 } END { print (NR % 2) ? a[(NR + 1) / 2] : int((a[NR / 2] + a[NR / 2 + 1]) / 2) }'; }

status=0
declare -A MED
before=$(clipboard_fingerprint)
for path in wayland x11; do
  want=paste; [ "$path" = x11 ] && want=pasteshift
  times=()
  for i in $(seq "$RUNS"); do
    read -r ms key < <(run_once "$path")
    if [ "$ms" = FAIL ] || [ "$key" != "$want" ]; then
      echo "perf: $path run $i failed (key=${key:-none}, expected $want); log:" >&2
      tail -5 "$W/rt/xhisper.log" >&2
      status=1; continue
    fi
    times+=("$ms")
  done
  [ ${#times[@]} -gt 0 ] || { echo "perf: $path: no successful runs" >&2; status=1; continue; }
  MED[$path]=$(printf '%s\n' "${times[@]}" | median)
  verdict=ok; [ "${MED[$path]}" -gt "$MAX_MS" ] && { verdict="OVER ${MAX_MS} ms"; status=1; }
  printf '%-8s median %4s ms   runs: %s   [%s]\n' "$path" "${MED[$path]}" "${times[*]}" "$verdict"
done
after=$(clipboard_fingerprint)

if [ -n "${MED[wayland]:-}" ] && [ -n "${MED[x11]:-}" ]; then
  spread=$(( MED[wayland] - MED[x11] )); spread=${spread#-}
  verdict=ok; [ "$spread" -gt "$MAX_SPREAD_MS" ] && { verdict="OVER ${MAX_SPREAD_MS} ms"; status=1; }
  printf 'spread   %4s ms between paths   [%s]\n' "$spread" "$verdict"
fi
if [ "$before" != "$after" ]; then
  echo "perf: your clipboard changed during the test (restore failed?)" >&2; status=1
fi
grep -h '^Timing:' "$W/rt/xhisper.log" | tail -2 | sed 's/^/  last: /'
[ "$status" -eq 0 ] && echo "perf: PASS" || echo "perf: FAIL"
exit "$status"
