#!/bin/bash
# Offline application gate by default; --live makes ten explicit Groq requests.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=--gate
RUNS=20
case "${1:-}" in
  "") ;;
  --live)
    MODE=--live
    RUNS=5
    # Credentials stay in the process environment, never in harness output.
    if [ -z "${GROQ_API_KEY:-}" ] && [ -f "$HOME/.env" ]; then
      source "$HOME/.env"
    fi
    export GROQ_API_KEY
    [ -n "${GROQ_API_KEY:-}" ] || { printf 'Live mode needs GROQ_API_KEY.\n' >&2; exit 2; }
    ;;
  *) printf 'Usage: %s [--live]\n' "$0" >&2; exit 2 ;;
esac
for tool in python3 espeak-ng ffmpeg Xvfb xclip wl-copy wl-paste jq bc; do
  command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 2; }
done
[ -x "$REPO/xhisperclip" ] || { printf 'Build xhisperclip first (make xhisperclip).\n' >&2; exit 2; }
W=$(mktemp --directory /tmp/xhperf.XXXXXX)
cleanup() {
  if [ "$status" = 0 ] && [ "$MODE" != --live ]; then
    rm --recursive --force -- "$W"
  else
    printf 'Performance evidence retained in %s\n' "$W" >&2
  fi
}
trap cleanup EXIT
export PYTHONDONTWRITEBYTECODE=1
status=0
bash "$REPO/tests/wayland-session.sh" python3 "$REPO/tests/calibrate-perf.py" \
  "$MODE" --paths wayland --editor --samples "$RUNS" --output "$W/wayland.json" || status=1
python3 "$REPO/tests/calibrate-perf.py" "$MODE" --paths x11 --samples "$RUNS" \
  --output "$W/x11.json" || status=1
if [ "$status" = 0 ]; then
  printf 'perf: PASS (%s)\n' "${MODE#--}"
else
  printf 'perf: FAIL (%s); see rejected samples and per-path statistics above.\n' "${MODE#--}" >&2
fi
exit "$status"
