#!/bin/bash
# xhisper-stream tests against a stand-in AssemblyAI server (tests/fake_assemblyai.py)
# and a stand-in microphone. Offline: no key, no network, no audio device.
#
# usage: tests/stream.sh   (or: make test-stream)

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d); SERVER=""
trap '[ -n "$SERVER" ] && kill $SERVER 2>/dev/null; rm -rf "$W"' EXIT
fails=0
check() {  # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: [$2]"; echo "     got:  [$3]"; fails=$((fails + 1)); fi
}

# Stand-in microphone: s16le 16 kHz mono silence in real time, until interrupted.
cat > "$W/mic.py" <<'EOF'
import signal, sys, time
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
while True:
    sys.stdout.buffer.write(bytes(1600)); sys.stdout.buffer.flush(); time.sleep(0.05)
EOF

PORT=$(( 20000 + RANDOM % 20000 ))
start_server() {  # mode
  [ -n "$SERVER" ] && kill $SERVER 2>/dev/null && wait $SERVER 2>/dev/null
  python3 "$REPO/tests/fake_assemblyai.py" "$PORT" "$W/server.log" "$1" & SERVER=$!
  for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.05; done
}

# One dictation: record for $1 s, press stop, wait. Prints "exitcode stop_to_exit_ms".
dictate() {
  rm -f "$W/out.txt" "$W/out.wav"
  env ASSEMBLYAI_API_KEY="${KEY:-test-key}" XHISPER_STREAM_URL="ws://127.0.0.1:$PORT/v3/ws" \
      XHISPER_RECORD_CMD="python3 $W/mic.py" XHISPER_KEYTERMS='["Claude","XWayland"]' \
      python3 "$REPO/xhisper-stream" --wav "$W/out.wav" --text "$W/out.txt" --model universal-3-5-pro \
      2>>"$W/stderr" &
  local pid=$!
  sleep "$1"
  local t0=$EPOCHREALTIME
  kill -USR1 $pid; wait $pid; local rc=$?
  echo "$rc $(( (${EPOCHREALTIME/./} - ${t0/./}) / 1000 ))"
}

start_server ok
read -r rc ms < <(dictate 1)
check "streams, finalizes on stop" 0 "$rc"
text=$(cat "$W/out.txt" 2>/dev/null)
[[ "$text" =~ ^Got\ ([0-9]+)\ ms\;\ terms\ Claude,XWayland\.$ ]] && heard=${BASH_REMATCH[1]} || heard=0
check "transcript and keyterms arrive" "yes" "$([ "$heard" -ge 800 ] && echo yes || echo "no: $text")"
check "audio was streamed live (server got ~1 s)" "yes" "$([ "$heard" -le 1300 ] && echo yes || echo "no: $heard ms")"
check "stop to transcript under 300 ms" "yes" "$([ "$ms" -lt 300 ] && echo yes || echo "no: $ms ms")"
wav_ms=$(( ($(stat -c %s "$W/out.wav") - 44) / 32 ))
check "recording saved for fallback" "yes" "$([ "$wav_ms" -ge 800 ] && echo yes || echo "no: $wav_ms ms")"
check "model passed through" "universal-3-5-pro" "$(tail -1 "$W/server.log" | jq -r .model)"

start_server silent
read -r rc ms < <(dictate 0.5)
check "no speech: empty transcript, quick exit" "0 empty" "$rc $( [ -s "$W/out.txt" ] && echo text || echo empty)"
check "no speech: exits within 500 ms" "yes" "$([ "$ms" -lt 500 ] && echo yes || echo "no: $ms ms")"

start_server ok
KEY=wrong read -r rc ms < <(KEY=wrong dictate 0.5)
check "bad key: fails so xhisper falls back" "2 nofile" "$rc $( [ -e "$W/out.txt" ] && echo file || echo nofile)"
check "bad key: recording still saved" "yes" "$([ -s "$W/out.wav" ] && echo yes || echo no)"

kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; SERVER=""
read -r rc ms < <(dictate 0.5)
check "no server: fails so xhisper falls back" "2" "$rc"

# A key lookup that hangs (e.g. an unanswered 1Password prompt) must not delay stop.
mkdir -p "$W/opbin"; printf '#!/bin/bash\nsleep 30\n' > "$W/opbin/op"; chmod +x "$W/opbin/op"
start_server ok
read -r rc ms < <(PATH="$W/opbin:$PATH" KEY="op://vault/item/field" dictate 0.5)
check "hung key lookup: fails fast on stop" "2 yes" "$rc $([ "$ms" -lt 1000 ] && echo yes || echo "no: $ms ms")"

# --- xhisper.sh end to end, backend: assemblyai -----------------------------------
# Start and stop a dictation through the real script, on a private X display (so the
# real clipboard is never touched), with stand-ins for the key sender and D-Bus.
if command -v Xvfb >/dev/null && command -v xclip >/dev/null; then
  mkdir -p "$W/bin" "$W/cfg/xhisper" "$W/cache/xhisper" "$W/rt"
  printf 'insert-mode : paste\nbackend : assemblyai\nmin-latency : 0\nauto-vocab : off\n' > "$W/cfg/xhisper/xhisperrc"
  printf 'XWayland\n' > "$W/cfg/xhisper/words"
  printf '#!/bin/bash\necho "$1 $EPOCHREALTIME" >> "%s/keys"\n' "$W" > "$W/bin/xhispertool"
  printf '#!/bin/bash\ncase "$*" in *FocusedWindow*) echo "(%s, %s, %s)";; esac\n' \
    "'dev.warp.Warp'" "'dev.warp.Warp.desktop'" "'x11'" > "$W/bin/gdbus"
  printf '#!/bin/bash\necho "$*" >> "%s/notes"\n' "$W" > "$W/bin/notify-send"
  # Groq stand-in for the fallback: answers like the transcription API.
  cat > "$W/bin/curl" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in --output) printf '%s' '{"text":" Groq fallback text."}' > "$2"; shift 2 ;; *) shift ;; esac
done
printf '200'
STUB
  chmod +x "$W/bin/"*
  # A noisy microphone, so the fallback's silence check sees sound.
  sed -i 's/bytes(1600)/bytes(b % 64 for b in __import__("os").urandom(1600))/' "$W/mic.py"
  for n in $(seq 90 120); do [ -e "/tmp/.X11-unix/X$n" ] || { XNUM=$n; break; }; done
  Xvfb ":$XNUM" -nolisten tcp >/dev/null 2>&1 & XVFB=$!
  for _ in $(seq 50); do [ -e "/tmp/.X11-unix/X$XNUM" ] && break; sleep 0.05; done
  run_xhisper() {
    env PATH="$W/bin:$PATH" DISPLAY=":$XNUM" XHISPER_RUNTIME_DIR="$W/rt" XHISPER_SKIP_DAEMON=1 \
      XHISPER_TOOL_OVERRIDE=1 XHISPERTOOL="$W/bin/xhispertool" XHISPERCLIP="$REPO/xhisperclip" \
      XHISPER_STREAM="$REPO/xhisper-stream" XHISPER_VOCAB=true \
      XDG_CONFIG_HOME="$W/cfg" XDG_CACHE_HOME="$W/cache" ASSEMBLYAI_API_KEY=test-key \
      XHISPER_STREAM_URL="ws://127.0.0.1:$PORT/v3/ws" XHISPER_RECORD_CMD="python3 $W/mic.py" \
      timeout 15 bash "$REPO/xhisper.sh" >/dev/null 2>&1
  }
  e2e_ms() {
    : > "$W/keys"; run_xhisper & local starter=$!
    sleep 1
    local t0=$EPOCHREALTIME; run_xhisper; wait $starter 2>/dev/null
    local line t1; line=$(grep -m1 -E '^paste(shift)? ' "$W/keys") || { echo none; return; }
    t1=${line##* }; echo $(( (${t1/./} - ${t0/./}) / 1000 ))
  }

  start_server ok
  ms=$(e2e_ms)
  check "e2e: streamed text pasted (paste key sent)" "yes" "$([ "$ms" != none ] && echo yes || echo no)"
  check "e2e: logged as a successful assemblyai attempt" "success" \
    "$(grep '"backend":"assemblyai"' "$W/rt/xhisper.log" | tail -1 | jq -r .outcome)"
  check "e2e: no transcript text in the log" "0" "$(grep -c 'Got ' "$W/rt/xhisper.log")"
  check "e2e: taught word sent as a keyterm" "XWayland" "$(tail -1 "$W/server.log" | jq -r '.terms | join(",")')"
  check "e2e: stop to paste key under 500 ms" "yes" "$([ "$ms" != none ] && [ "$ms" -lt 500 ] && echo yes || echo "no: $ms ms")"
  echo "     (stop to paste key: $ms ms)"

  kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; SERVER=""
  ms=$(e2e_ms)
  check "e2e: streaming down falls back to Groq (text pasted)" "yes" "$([ "$ms" != none ] && echo yes || echo no)"
  check "e2e: fallback transcription logged" "success" "$(grep '"curl_exit"' "$W/rt/xhisper.log" | tail -1 | jq -r .outcome)"
  check "e2e: stream failure logged" "stream_failed" \
    "$(grep '"backend":"assemblyai"' "$W/rt/xhisper.log" | tail -1 | jq -r .outcome)"
  kill $XVFB 2>/dev/null
else
  echo "skip e2e: needs Xvfb and xclip"
fi

[ "$fails" -eq 0 ] && echo "stream: PASS" || { echo "stream: $fails FAILED"; cat "$W/stderr"; exit 1; }
