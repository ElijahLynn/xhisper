#!/bin/bash

# xhisper: push-to-dictate for Linux. Run once to start recording, again to stop,
# transcribe with Groq Whisper and paste the text at the cursor.
#
# Settings: ~/.config/xhisper/xhisperrc (see default_xhisperrc and README.md):
#   insert-mode, paste-key, indicator-color, indicator-style, transcription-prompt,
#   long-recording-threshold, silence-threshold, type-key-gap,
#   non-ascii-initial-delay, non-ascii-default-delay
#
# Requires: pipewire (pw-record), curl, jq, ffmpeg, wl-clipboard, xclip, gdbus,
# notify-send; xhispertool/xhispertoold (make && sudo make install); optionally the
# xhisper-indicator GNOME Shell extension in extension/.

T0=$(date +%s%N)  # per-step timing, logged after each dictation
[ -f "$HOME/.env" ] && source "$HOME/.env"

# Parse command-line arguments
LOCAL_MODE=0
WRAP_KEY=""
for arg in "$@"; do
  case "$arg" in
    --local)
      LOCAL_MODE=1
      ;;
    --log)
      if [ -f "/tmp/xhisper.log" ]; then
        cat /tmp/xhisper.log
      else
        echo "No log file found at /tmp/xhisper.log" >&2
      fi
      exit 0
      ;;
    --leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super)
      if [ -n "$WRAP_KEY" ]; then
        echo "Error: Multiple wrap keys not yet supported" >&2
        exit 1
      fi
      WRAP_KEY="${arg#--}"
      ;;
    *)
      echo "Error: Unknown option '$arg'" >&2
      echo "Usage: xhisper [--local] [--log] [--leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super]" >&2
      exit 1
      ;;
  esac
done

# Set binary paths based on local mode
if [ "$LOCAL_MODE" -eq 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  XHISPERTOOL="$SCRIPT_DIR/xhispertool"
  XHISPERTOOLD="$SCRIPT_DIR/xhispertoold"
else
  XHISPERTOOL="xhispertool"
  XHISPERTOOLD="xhispertoold"
fi

RECORDING="/tmp/xhisper.wav"
LOGFILE="/tmp/xhisper.log"

# Default configuration
long_recording_threshold=1000
transcription_prompt=""
silence_threshold=-50
non_ascii_initial_delay=0.1
non_ascii_default_delay=0.025
# Microseconds to pause after each ASCII key. Default matches built-in speed;
# raise it only if a target app drops keys (e.g. Warp under GPU load).
type_key_gap=2000
# "paste" (default) puts the whole transcription on the clipboard, pastes once, then
# restores it; "type" sends one key per character (slow: one process per key).
insert_mode=paste
paste_key=auto  # auto: ctrl+shift+v in terminals (needs the indicator extension), else ctrl+v
indicator_color=red
indicator_style=meter

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/xhisper/xhisperrc"

if [ -f "$CONFIG_FILE" ]; then
  while IFS=: read -r key value || [ -n "$key" ]; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue

    # Strip inline "# comments", whitespace and quotes (pure bash: no process per line)
    value="${value%%#*}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"; value="${value%\"}"

    case "$key" in
      long-recording-threshold) long_recording_threshold="$value" ;;
      transcription-prompt) transcription_prompt="$value" ;;
      silence-threshold) silence_threshold="$value" ;;
      non-ascii-initial-delay) non_ascii_initial_delay="$value" ;;
      non-ascii-default-delay) non_ascii_default_delay="$value" ;;
      type-key-gap) type_key_gap="$value" ;;
      insert-mode) insert_mode="$value" ;;
      paste-key) paste_key="$value" ;;
      indicator-color) indicator_color="$value" ;;
      indicator-style) indicator_style="$value" ;;
    esac
  done < "$CONFIG_FILE"
fi

# Is a process with this PID running and named NAME? Reads /proc directly: pgrep scans
# every process and costs ~50 ms on a busy desktop, several times per dictation.
pid_is() {  # pid name
  local comm state
  [ -n "$1" ] && read -r comm 2>/dev/null < "/proc/$1/comm" && [ "$comm" = "$2" ] || return 1
  read -r state 2>/dev/null < "/proc/$1/stat"; state="${state##*) }"
  [ "${state%% *}" != Z ]  # an exited process waiting to be reaped doesn't count
}
read_pid() { local pid; read -r pid < "$1" 2>/dev/null && echo "$pid"; }

# Auto-start the key-sending daemon if it isn't running
DAEMON_PID_FILE=/tmp/xhispertoold.pid
if ! pid_is "$(read_pid "$DAEMON_PID_FILE")" xhispertoold; then
  if pid=$(pgrep -x -n xhispertoold); then
    echo "$pid" > "$DAEMON_PID_FILE"  # started some other way; remember it
  else
    "$XHISPERTOOLD" 2>> /tmp/xhispertoold.log &
    echo $! > "$DAEMON_PID_FILE"
    sleep 1  # Give daemon time to start
    if ! pid_is "$(read_pid "$DAEMON_PID_FILE")" xhispertoold; then
      echo "Error: Failed to start xhispertoold daemon" >&2
      echo "Check /tmp/xhispertoold.log for details" >&2
      exit 1
    fi
  fi
fi

# Check if xhispertool is available
if ! command -v "$XHISPERTOOL" &> /dev/null; then
    echo "Error: xhispertool not found" >&2
    echo "Please either:" >&2
    echo "  - Run 'sudo make install' to install system-wide" >&2
    echo "  - Run 'xhisper --local' from the build directory" >&2
    exit 1
fi

# Detect clipboard tool (only needed for non-ASCII text; error is deferred
# to paste() so ASCII-only dictation still works without one installed)
if command -v wl-copy &> /dev/null; then
    CLIP_COPY="wl-copy"
    CLIP_PASTE="wl-paste"
elif command -v xclip &> /dev/null; then
    CLIP_COPY() { xclip -selection clipboard; }
    CLIP_PASTE() { xclip -o -selection clipboard; }
else
    CLIP_COPY=""
    CLIP_PASTE=""
fi

press_wrap_key() {
  if [ -n "$WRAP_KEY" ]; then
    "$XHISPERTOOL" "$WRAP_KEY"
  fi
}

paste() {
  local text="$1"
  press_wrap_key
  # Type character by character
  # Use xhispertool type for ASCII (32-126), clipboard+paste for Unicode
  for ((i=0; i<${#text}; i++)); do
    local char="${text:$i:1}"
    local ascii=$(printf '%d' "'$char")

    if [[ $ascii -ge 32 && $ascii -le 126 ]]; then
      # ASCII printable character - use direct key typing (faster)
      "$XHISPERTOOL" type "$char" "$type_key_gap"
    else
      # Unicode or special character - use clipboard
      if [ -z "$CLIP_COPY" ]; then
        echo "Error: No clipboard tool found. Install wl-clipboard or xclip to paste non-ASCII text." >&2
        return 1
      fi
      echo -n "$char" | $CLIP_COPY
      "$XHISPERTOOL" paste
      # On first character (more error-prone), sleep longer
      [ "$i" -eq 0 ] && sleep "$non_ascii_initial_delay" || sleep "$non_ascii_default_delay"
    fi
  done
  press_wrap_key
}

# insert-mode paste, in two steps so no keystrokes are in flight while the clipboard
# is touched: on GNOME, wl-copy/wl-paste briefly take keyboard focus, and keys sent
# meanwhile (e.g. the backspaces erasing "(transcribing...)") go to them and are lost.
#   clip_save        - save the user's clipboard (runs during the upload)
#   clip_stage TEXT  - put TEXT on the clipboard (before any keys)
#   paste_staged     - send the paste key, then restore the user's clipboard
CLIP_STATE=unknown  # after clip_save: saved | empty | unknown (couldn't read)
CLIP_TYPE=""        # MIME type / X11 target of the saved content
CLIP_FILE=""        # saved bytes (a file, so images and other binary data survive)
# Put text on the clipboard. wl-copy first; xclip as the fallback, because wl-copy
# fails or times out while an X11 (XWayland) window such as Warp has focus, and
# Mutter bridges the X11 clipboard to Wayland apps anyway.
CLIP_XCLIP_ONLY=0  # set once wl-copy fails, so later calls skip straight to xclip

# The focused window, asked once per dictation from the indicator extension:
# FOCUS is "('wm_class', 'app_id')", FOCUS_CLASS the wm_class. Apps where the Wayland
# clipboard failed before (X11/XWayland apps such as Warp) are remembered in
# X11_APPS_FILE and go straight to xclip, skipping two timeouts (~400 ms).
FOCUS=""; FOCUS_CLASS=""
X11_APPS_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/xhisper/x11-apps"
focus_query() {
  FOCUS=$(timeout 0.2 gdbus call "${INDICATOR_DBUS[@]}" \
          --method io.github.elijahlynn.XhisperIndicator.FocusedWindow 2>/dev/null) || FOCUS=""
  [[ "$FOCUS" =~ ^\(\'([^\']*)\' ]] && FOCUS_CLASS="${BASH_REMATCH[1]}"
  local app
  if [ -n "$FOCUS_CLASS" ] && [ -f "$X11_APPS_FILE" ]; then
    while IFS= read -r app; do [ "$app" = "$FOCUS_CLASS" ] && CLIP_XCLIP_ONLY=1 && break; done < "$X11_APPS_FILE"
  fi
}
remember_x11_app() {
  CLIP_XCLIP_ONLY=1
  [ -n "$FOCUS_CLASS" ] || return 0
  grep -qxF "$FOCUS_CLASS" "$X11_APPS_FILE" 2>/dev/null && return 0
  mkdir -p "${X11_APPS_FILE%/*}" && echo "$FOCUS_CLASS" >> "$X11_APPS_FILE"
}
# The transcription is marked sensitive (KDE password-manager hint, which clipboard
# history tools honour) so dictations don't pile up in clipboard history.
clip_set() {
  local text="$1"
  if [ "$CLIP_XCLIP_ONLY" -eq 0 ] && command -v wl-copy >/dev/null 2>&1 &&
     printf '%s' "$text" | timeout 0.3 wl-copy --sensitive 2>/dev/null; then
    return 0
  fi
  [ "$CLIP_XCLIP_ONLY" -eq 0 ] && remember_x11_app
  command -v xclip >/dev/null 2>&1 &&
    printf '%s' "$text" | timeout 0.5 xclip -selection clipboard -i 2>/dev/null
}

# Best type to save from a list of offered types (one per line): text, then image,
# then whatever comes first.
clip_pick_type() {
  local types="$1" t
  for t in 'text/plain;charset=utf-8' 'UTF8_STRING' 'text/plain'; do
    printf '%s\n' "$types" | grep -qxF "$t" && { echo "$t"; return; }
  done
  t=$(printf '%s\n' "$types" | grep -m1 '^image/') && { echo "$t"; return; }
  printf '%s\n' "$types" | grep -v -m1 -E '^(TARGETS|TIMESTAMP|MULTIPLE|SAVE_TARGETS)$'
}

# Put the saved clipboard back, or clear it if it was empty, so dictations never
# stay on the clipboard.
clip_restore() {
  local wtype="$CLIP_TYPE" xtype="$CLIP_TYPE"
  case "$wtype" in UTF8_STRING|STRING|TEXT) wtype='text/plain;charset=utf-8' ;; esac
  case "$xtype" in text/plain*) xtype=UTF8_STRING ;; esac
  case "$CLIP_STATE" in
    saved)
      { [ "$CLIP_XCLIP_ONLY" -eq 0 ] && timeout 0.3 wl-copy --type "$wtype" < "$CLIP_FILE" 2>/dev/null; } ||
        timeout 0.5 xclip -selection clipboard -t "$xtype" -i "$CLIP_FILE" 2>/dev/null ||
        echo "=== paste mode: could not restore the old clipboard ===" >> "$LOGFILE"
      ;;
    empty)
      { [ "$CLIP_XCLIP_ONLY" -eq 0 ] && timeout 0.3 wl-copy --clear 2>/dev/null; } ||
        printf '' | timeout 0.5 xclip -selection clipboard -i 2>/dev/null
      ;;
  esac
  [ -n "$CLIP_FILE" ] && rm -f "$CLIP_FILE"
}

clip_stage() {
  if ! clip_set "$1"; then
    echo "=== paste mode: could not set the clipboard (install wl-clipboard or xclip); typing instead ===" >> "$LOGFILE"
    return 1
  fi
  # wl-copy briefly takes keyboard focus on GNOME; let it return before the paste key.
  # xclip doesn't, so no wait then.
  [ "$CLIP_XCLIP_ONLY" -eq 0 ] && sleep 0.08
  return 0
}

# Save the user's clipboard (text only) so paste_staged can restore it. Run while the
# transcription uploads, so it costs nothing. Binary content like images can't
# round-trip through a shell variable and is left replaced. Every clipboard call is
# time-limited: some clipboard owners never answer a read, and wl-paste then blocks.
clip_save() {
  local types rc
  if [ "$CLIP_XCLIP_ONLY" -eq 0 ] && command -v wl-paste >/dev/null 2>&1; then
    types=$(timeout 0.25 wl-paste --list-types 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$types" ]; then
      CLIP_TYPE=$(clip_pick_type "$types")
      CLIP_FILE=$(mktemp /tmp/xhisper-clip.XXXXXX)
      timeout 0.5 wl-paste --no-newline --type "$CLIP_TYPE" > "$CLIP_FILE" 2>/dev/null &&
        { CLIP_STATE=saved; return 0; }
    elif [ "$rc" -ne 124 ]; then
      CLIP_STATE=empty; return 0  # answered quickly with nothing: "Nothing is copied"
    else
      remember_x11_app  # timed out: an X11 window has focus
    fi
  fi
  # wl-paste fails while an X11 window has focus; ask the X11 clipboard instead.
  if command -v xclip >/dev/null 2>&1; then
    types=$(timeout 0.25 xclip -o -selection clipboard -t TARGETS 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$types" ]; then
      CLIP_TYPE=$(clip_pick_type "$types")
      CLIP_FILE=${CLIP_FILE:-$(mktemp /tmp/xhisper-clip.XXXXXX)}
      timeout 0.5 xclip -o -selection clipboard -t "$CLIP_TYPE" > "$CLIP_FILE" 2>/dev/null &&
        { CLIP_STATE=saved; return 0; }
    elif [ "$rc" -eq 1 ]; then
      CLIP_STATE=empty; return 0  # no clipboard owner
    fi
  fi
  echo "=== paste mode: could not read the old clipboard; it will not be restored ===" >> "$LOGFILE"
}

# Terminals paste with Ctrl+Shift+V. paste-key "auto" asks the xhisper-indicator
# extension which window has focus (only a Shell extension can see that on Wayland).
TERMINAL_CLASSES='warp|kitty|alacritty|foot|wezterm|ghostty|terminal|ptyxis|konsole|xterm|tilix|terminator|kgx|console|blackbox|rio'
resolve_paste_key() {
  [ "$paste_key" = "auto" ] || { echo "$paste_key"; return; }
  if [ -n "$FOCUS" ]; then
    shopt -s nocasematch
    if [[ "$FOCUS" =~ $TERMINAL_CLASSES ]]; then echo ctrl+shift+v; else echo ctrl+v; fi
    shopt -u nocasematch
  elif [ "$CLIP_XCLIP_ONLY" -eq 1 ]; then
    # No extension to ask. wl-copy only fails while an X11 window (e.g. Warp) has
    # focus, which on this setup is most likely a terminal.
    echo ctrl+shift+v
  else
    echo ctrl+v
  fi
}

paste_staged() {
  local key; key=$(resolve_paste_key)
  press_wrap_key
  if [ "$key" = "ctrl+shift+v" ]; then
    "$XHISPERTOOL" pasteshift
  else
    "$XHISPERTOOL" paste
  fi
  press_wrap_key
  sleep 0.3  # let the target app read the clipboard before it changes again
  clip_restore
}

# Status is shown on screen, never typed into the focused app (typing and then
# erasing placeholder text raced with other input and left fragments behind).
notify() {
  command -v notify-send >/dev/null 2>&1 &&
    notify-send -a xhisper -h int:transient:1 -t "${2:-2000}" "$1" 2>/dev/null || true
}

# Recording indicator: an on-screen overlay drawn by the xhisper-indicator GNOME Shell
# extension (bottom-center level meter, like groq-flow on macOS), reached over D-Bus.
# Without the extension there is no indicator (no notification either: they pile up).
INDICATOR_DBUS=(--session --dest org.gnome.Shell --object-path /io/github/elijahlynn/XhisperIndicator)
indicator_show() {
  local color="${indicator_color//[^a-zA-Z]/}" style="${indicator_style//[^a-zA-Z]/}"
  gdbus call "${INDICATOR_DBUS[@]}" --method io.github.elijahlynn.XhisperIndicator.Show \
    "${color:-red}" "${style:-meter}" >/dev/null 2>&1 ||
    echo "=== indicator unavailable: is the xhisper-indicator extension enabled? ===" >> "$LOGFILE"
}
indicator_hide() {
  gdbus call "${INDICATOR_DBUS[@]}" --method io.github.elijahlynn.XhisperIndicator.Hide \
    >/dev/null 2>&1 || true
}

delete_n_chars() {
  local n="$1"
  for ((i=0; i<n; i++)); do
    "$XHISPERTOOL" backspace
  done
}

get_duration() {
  # From the file size: pw-record writes 16 kHz mono 16-bit WAV (32000 bytes/s, 44-byte
  # header). Much faster than spawning ffprobe on every dictation.
  local bytes=$(stat -c %s "$1" 2>/dev/null || echo 44)
  echo $(( (bytes - 44) / 32000 ))
}

is_silent() {
  local recording="$1"

  # Use ffmpeg volumedetect to get mean and max volume
  local vol_stats=$(ffmpeg -i "$recording" -af "volumedetect" -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume")
  local max_vol=$(echo "$vol_stats" | grep "max_volume" | awk '{print $5}')

  # If max volume is below threshold, consider it silent
  # Note: ffmpeg reports in dB, negative values (e.g., -50 dB is quiet)
  if [ -n "$max_vol" ]; then
    local is_quiet=$(echo "$max_vol < $silence_threshold" | bc -l)
    [ "$is_quiet" -eq 1 ] && return 0
  fi

  return 1
}

logging_end_and_write_to_logfile() {
  local title="$1"
  local result="$2"
  local logging_start="$3"

  local logging_end=$(date +%s%N)
  local time=$(echo "scale=3; ($logging_end - $logging_start) / 1000000000" | bc)

  echo "=== $title ===" >> "$LOGFILE"
  echo "Result: [$result]" >> "$LOGFILE"
  echo "Time: ${time}s" >> "$LOGFILE"
}

transcribe() {
  local recording="$1"
  local logging_start=$(date +%s%N)

  # Use large model for longer recordings, turbo for short ones
  local is_long_recording=$(echo "$(get_duration "$recording") > $long_recording_threshold" | bc -l)
  local model=$([[ $is_long_recording -eq 1 ]] && echo "whisper-large-v3" || echo "whisper-large-v3-turbo")

  local transcription=$(curl -s -X POST "https://api.groq.com/openai/v1/audio/transcriptions" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@$recording" \
    -F "model=$model" \
    -F "prompt=$transcription_prompt" \
    | jq -r '.text' | sed 's/^ //') # Transcription always returns a leading space, so remove it via sed

  logging_end_and_write_to_logfile "Transcription" "$transcription" "$logging_start"

  echo "$transcription"
}

# Main

# Never leave a saved clipboard copy behind, whatever path the script exits by.
trap '[ -n "$CLIP_FILE" ] && rm -f "$CLIP_FILE"' EXIT

# ms since the previous mark; appends "name=Nms" to TIMING
TIMING=""; T_LAST=$T0
mark() { local now=$(date +%s%N); TIMING+="$1=$(( (now - T_LAST) / 1000000 ))ms "; T_LAST=$now; }

REC_PID_FILE=/tmp/xhisper-rec.pid

# A recording is running: stop it and transcribe
if REC_PID=$(read_pid "$REC_PID_FILE") && pid_is "$REC_PID" pw-record; then
  mark startup
  kill "$REC_PID"
  # pw-record finalizes the WAV header on exit; wait for that (up to 0.5 s).
  for _ in {1..100}; do pid_is "$REC_PID" pw-record || break; sleep 0.005; done
  rm -f "$REC_PID_FILE"
  indicator_hide
  mark stop

  # Upload right away; check for silence and save the clipboard while it runs.
  TRANSCRIPT_FILE=$(mktemp /tmp/xhisper-transcript.XXXXXX)
  transcribe "$RECORDING" > "$TRANSCRIPT_FILE" &
  TRANSCRIBE_PID=$!

  if is_silent "$RECORDING"; then
    kill "$TRANSCRIBE_PID" 2>/dev/null
    notify "No sound detected"
    rm -f "$RECORDING" "$TRANSCRIPT_FILE"
    exit 0
  fi
  if [ "$insert_mode" = "paste" ]; then focus_query; clip_save; fi
  mark silence+focus+clipboard-save

  wait "$TRANSCRIBE_PID"
  TRANSCRIPTION=$(cat "$TRANSCRIPT_FILE"); rm -f "$TRANSCRIPT_FILE"
  mark transcribe-wait
  if [ -z "$TRANSCRIPTION" ] || [ "$TRANSCRIPTION" = "null" ]; then
    notify "Transcription failed (see /tmp/xhisper.log)" 4000
    rm -f "$RECORDING"
    exit 1
  fi

  if [ "$insert_mode" = "paste" ] && clip_stage "$TRANSCRIPTION"; then
    mark clipboard
    paste_staged
    mark paste+restore
  else
    paste "$TRANSCRIPTION"
    mark type
  fi
  echo "Timing: ${TIMING}total=$(( ($(date +%s%N) - T0) / 1000000 ))ms (${#TRANSCRIPTION} chars)" >> "$LOGFILE"

  rm -f "$RECORDING"
else
  # No recording running, so start
  indicator_show
  pw-record --channels=1 --rate=16000 "$RECORDING" &
  echo $! > "$REC_PID_FILE"
  wait $!
fi
