#!/bin/bash

# xhisper: push-to-dictate for Linux. Run once to start recording, again to stop,
# transcribe with Groq Whisper and paste the text at the cursor.
#
# Settings: ~/.config/xhisper/xhisperrc (see default_xhisperrc and README.md):
#   insert-mode, paste-key, indicator-color, indicator-style, min-latency, transcription-prompt,
#   auto-vocab, trailing-space, backend, assemblyai-model,
#   long-recording-threshold, silence-threshold, type-key-gap,
#   non-ascii-initial-delay, non-ascii-default-delay
#
# Vocabulary (spelling hints sent to Whisper, see README.md "Vocabulary"):
#   ~/.config/xhisper/words         terms you taught with --learn (one per line)
#   ~/.config/xhisper/replacements  "heard<TAB>word" fixes learned with --learn
#   ~/.cache/xhisper/vocab          built from what you type by xhisper-vocab
#
# Requires: pipewire (pw-record), curl, jq, ffmpeg, wl-clipboard, xclip, gdbus,
# notify-send; xhispertool/xhispertoold (make && sudo make install); optionally the
# xhisper-indicator GNOME Shell extension in extension/, and python3 for xhisper-vocab.

T0=$(date +%s%N)  # per-step timing, logged after each dictation
[ -f "$HOME/.env" ] && source "$HOME/.env"

# Parse command-line arguments
LOCAL_MODE=0
WRAP_KEY=""
LEARN=0; LEARN_WORD=""
# Where recordings, logs and PID files live. Overridable so tests run isolated.
RUNTIME_DIR="${XHISPER_RUNTIME_DIR:-/tmp}"
for arg in "$@"; do
  case "$arg" in
    --local)
      LOCAL_MODE=1
      ;;
    --log)
      if [ -f "$RUNTIME_DIR/xhisper.log" ]; then
        cat "$RUNTIME_DIR/xhisper.log"
      else
        echo "No log file found at $RUNTIME_DIR/xhisper.log" >&2
      fi
      exit 0
      ;;
    --learn)
      LEARN=1
      ;;
    --leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super)
      if [ -n "$WRAP_KEY" ]; then
        echo "Error: Multiple wrap keys not yet supported" >&2
        exit 1
      fi
      WRAP_KEY="${arg#--}"
      ;;
    *)
      if [ "$LEARN" -eq 1 ] && [ -z "$LEARN_WORD" ] && [[ "$arg" != -* ]]; then
        LEARN_WORD="$arg"  # xhisper --learn WORD (default: the selected text)
        continue
      fi
      echo "Error: Unknown option '$arg'" >&2
      echo "Usage: xhisper [--local] [--log] [--learn [WORD]] [--leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super]" >&2
      exit 1
      ;;
  esac
done

# Set binary paths based on local mode
if [ "$LOCAL_MODE" -eq 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  XHISPERTOOL="$SCRIPT_DIR/xhispertool"
  XHISPERTOOLD="$SCRIPT_DIR/xhispertoold"
  XHISPERCLIP="$SCRIPT_DIR/xhisperclip"
  XHISPER_VOCAB="$SCRIPT_DIR/xhisper-vocab"
  XHISPER_STREAM="$SCRIPT_DIR/xhisper-stream"
else
  XHISPERTOOL="${XHISPERTOOL:-xhispertool}"     # env overrides are for tests
  XHISPERTOOLD="${XHISPERTOOLD:-xhispertoold}"
  XHISPERCLIP="${XHISPERCLIP:-xhisperclip}"
  XHISPER_VOCAB="${XHISPER_VOCAB:-xhisper-vocab}"
  XHISPER_STREAM="${XHISPER_STREAM:-xhisper-stream}"
fi

RECORDING="$RUNTIME_DIR/xhisper.wav"
LOGFILE="$RUNTIME_DIR/xhisper.log"

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
# Text never appears sooner than this many ms after the stop key press, so every
# app (Wayland clipboard or xclip path) feels the same. 0 disables the floor.
min_latency=450
# Add words you type often to the Whisper prompt automatically (xhisper-vocab).
auto_vocab=on
# Paste a space after each dictation so back-to-back dictations don't run together.
trailing_space=on
# Speech-to-text: "groq" (upload after you stop) or "assemblyai" (stream while you talk,
# text ready ~50 ms after stop; falls back to Groq if streaming fails).
backend=groq
assemblyai_model=universal-3-5-pro

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
      min-latency) min_latency="$value" ;;
      auto-vocab) auto_vocab="$value" ;;
      trailing-space) trailing_space="$value" ;;
      backend) backend="$value" ;;
      assemblyai-model) assemblyai_model="$value" ;;
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
read_pid() { local pid; { read -r pid < "$1"; } 2>/dev/null && echo "$pid"; }

# Auto-start the key-sending daemon if it isn't running
DAEMON_PID_FILE="$RUNTIME_DIR/xhispertoold.pid"
if [ -z "$XHISPER_SKIP_DAEMON" ] && ! pid_is "$(read_pid "$DAEMON_PID_FILE")" xhispertoold; then
  if pid=$(pgrep -x -n xhispertoold); then
    echo "$pid" > "$DAEMON_PID_FILE"  # started some other way; remember it
  else
    "$XHISPERTOOLD" 2>> "$RUNTIME_DIR/xhispertoold.log" &
    echo $! > "$DAEMON_PID_FILE"
    sleep 1  # Give daemon time to start
    if [ -z "$XHISPER_SKIP_DAEMON" ] && ! pid_is "$(read_pid "$DAEMON_PID_FILE")" xhispertoold; then
      echo "Error: Failed to start xhispertoold daemon" >&2
      echo "Check $RUNTIME_DIR/xhispertoold.log for details" >&2
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
# Put text on the clipboard. wl-copy first; X11 as the fallback, because wl-copy
# fails or times out while an X11 (XWayland) window such as Warp has focus, and
# Mutter bridges the X11 clipboard to Wayland apps anyway.
CLIP_XCLIP_ONLY=0  # 1: skip the Wayland tools and use X11 straight away

# The focused window, asked once per dictation from the indicator extension:
# FOCUS is "('wm_class', 'app_id', 'client')", FOCUS_CLASS the wm_class and
# FOCUS_CLIENT "x11" (XWayland window) or "wayland" (empty with an older extension).
# X11 windows go straight to the X11 clipboard. Some Wayland apps (Warp in Wayland
# mode) still make the Wayland tools time out (~250 ms each); those are learned in
# X11_APPS_FILE ("apps that need the X11 clipboard") after two timeouts in a row, so
# a one-off hiccup doesn't flag an app for good. X11_PENDING_FILE holds first strikes.
FOCUS=""; FOCUS_CLASS=""; FOCUS_CLIENT=""
X11_APPS_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/xhisper/x11-apps"
X11_PENDING_FILE="$X11_APPS_FILE.pending"
focus_query() {
  FOCUS=$(timeout 0.2 gdbus call "${INDICATOR_DBUS[@]}" \
          --method io.github.elijahlynn.XhisperIndicator.FocusedWindow 2>/dev/null) || FOCUS=""
  [[ "$FOCUS" =~ ^\(\'([^\']*)\' ]] && FOCUS_CLASS="${BASH_REMATCH[1]}"
  [[ "$FOCUS" =~ \'(x11|wayland)\'\)$ ]] && FOCUS_CLIENT="${BASH_REMATCH[1]}"
  [ "$FOCUS_CLIENT" = x11 ] && { CLIP_XCLIP_ONLY=1; return; }
  local app
  if [ -n "$FOCUS_CLASS" ] && [ -f "$X11_APPS_FILE" ]; then
    while IFS= read -r app; do [ "$app" = "$FOCUS_CLASS" ] && CLIP_XCLIP_ONLY=1 && break; done < "$X11_APPS_FILE"
  fi
}
# A Wayland clipboard tool timed out: use X11 for the rest of this dictation. The
# first strike for an app is noted in X11_PENDING_FILE, the second (in a row) moves
# it to X11_APPS_FILE. Not for X11 windows: the extension already routes those.
remember_x11_app() {
  CLIP_XCLIP_ONLY=1
  [ "$FOCUS_CLIENT" != x11 ] && [ -n "$FOCUS_CLASS" ] || return 0
  grep -qxF "$FOCUS_CLASS" "$X11_APPS_FILE" 2>/dev/null && return 0
  mkdir -p "${X11_APPS_FILE%/*}"
  if grep -qxF "$FOCUS_CLASS" "$X11_PENDING_FILE" 2>/dev/null; then
    echo "$FOCUS_CLASS" >> "$X11_APPS_FILE"
    wayland_tools_ok
  else
    echo "$FOCUS_CLASS" >> "$X11_PENDING_FILE"
  fi
}
# The Wayland tools answered in this app: clear its first strike, if any.
wayland_tools_ok() {
  [ -n "$FOCUS_CLASS" ] && [ -s "$X11_PENDING_FILE" ] || return 0
  grep -qxF "$FOCUS_CLASS" "$X11_PENDING_FILE" || return 0
  local rest; rest=$(grep -vxF "$FOCUS_CLASS" "$X11_PENDING_FILE")
  printf '%s' "${rest:+$rest$'\n'}" > "$X11_PENDING_FILE"
}
# The transcription is marked sensitive (KDE password-manager hint, which clipboard
# history tools honour) so dictations don't pile up in clipboard history. On the X11
# path xhisperclip adds the hint (xclip can't); plain xclip is the last resort.
clip_set() {
  local text="$1"
  if [ "$CLIP_XCLIP_ONLY" -eq 0 ] && command -v wl-copy >/dev/null 2>&1 &&
     printf '%s' "$text" | timeout 0.3 wl-copy --sensitive --type 'text/plain;charset=utf-8' 2>/dev/null; then
    return 0
  fi
  [ "$CLIP_XCLIP_ONLY" -eq 0 ] && remember_x11_app
  if command -v "$XHISPERCLIP" >/dev/null 2>&1 &&
     printf '%s' "$text" | timeout 0.5 "$XHISPERCLIP" 2>/dev/null; then
    return 0
  fi
  echo "=== paste mode: xhisperclip unavailable; dictation may enter clipboard history ===" >> "$LOGFILE"
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
  [ "$CLIP_XCLIP_ONLY" -eq 0 ] && sleep 0.04
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
    [ "$rc" -ne 124 ] && wayland_tools_ok
    if [ "$rc" -eq 0 ] && [ -n "$types" ]; then
      CLIP_TYPE=$(clip_pick_type "$types")
      CLIP_FILE=$(mktemp "$RUNTIME_DIR/xhisper-clip.XXXXXX")
      timeout 0.5 wl-paste --no-newline --type "$CLIP_TYPE" > "$CLIP_FILE" 2>/dev/null &&
        { CLIP_STATE=saved; return 0; }
    elif [ "$rc" -ne 124 ]; then
      CLIP_STATE=empty; return 0  # answered quickly with nothing: "Nothing is copied"
    else
      remember_x11_app  # timed out: X11 window, or an app such as Warp that blocks wl-paste
    fi
  fi
  # wl-paste fails while an X11 window has focus; ask the X11 clipboard instead.
  if command -v xclip >/dev/null 2>&1; then
    types=$(timeout 0.25 xclip -o -selection clipboard -t TARGETS 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$types" ]; then
      CLIP_TYPE=$(clip_pick_type "$types")
      CLIP_FILE=${CLIP_FILE:-$(mktemp "$RUNTIME_DIR/xhisper-clip.XXXXXX")}
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

# --- Vocabulary -------------------------------------------------------------------
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xhisper"
WORDS_FILE="$CONFIG_DIR/words"                 # taught with --learn
REPLACEMENTS_FILE="$CONFIG_DIR/replacements"   # "heard<TAB>word", learned with --learn
VOCAB_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/xhisper/vocab"  # built by xhisper-vocab
LEARN_FILE="$RUNTIME_DIR/xhisper-learn"        # the word being taught, while recording
PROMPT_BUDGET=400  # chars (~100 tokens); long prompts make Whisper echo them back

# The Whisper prompt: transcription-prompt, then taught words, then the automatic
# vocabulary, without duplicates, cut to PROMPT_BUDGET. Pure bash (no processes).
build_prompt() {
  local prompt="$transcription_prompt" term low
  local -A seen=()
  local IFS=$'\n'
  if [ -n "$prompt" ]; then
    local t; IFS=',' read -ra t <<< "$prompt"
    for term in "${t[@]}"; do term="${term#"${term%%[![:space:]]*}"}"; seen[${term,,}]=1; done
    IFS=$'\n'
  fi
  local files=("$WORDS_FILE"); [ "$auto_vocab" = on ] && files+=("$VOCAB_FILE")
  local f terms i
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    mapfile -t terms < "$f"
    # Taught words newest first, so the budget never drops what you just taught.
    if [ "$f" = "$WORDS_FILE" ]; then
      local rev=(); for (( i = ${#terms[@]} - 1; i >= 0; i-- )); do rev+=("${terms[i]}"); done
      terms=("${rev[@]}")
    fi
    for term in "${terms[@]}"; do
      [ -n "$term" ] || continue
      low="${term,,}"; [ -n "${seen[$low]-}" ] && continue
      [ $(( ${#prompt} + ${#term} + 2 )) -gt "$PROMPT_BUDGET" ] && break 2
      seen[$low]=1; prompt="${prompt:+$prompt, }$term"
    done
  done
  printf '%s' "$prompt"
}

# Fix what Whisper keeps mishearing: whole-word, case-insensitive "heard" -> "word"
# from REPLACEMENTS_FILE (only non-dictionary mishearings are ever saved there).
apply_replacements() {
  local text="$1" heard word pre post n
  [ -s "$REPLACEMENTS_FILE" ] || { printf '%s' "$text"; return; }
  shopt -s nocasematch
  while IFS=$'\t' read -r heard word; do
    [ -n "$heard" ] && [ -n "$word" ] || continue
    local re="(^|[^[:alnum:]])(${heard})([^[:alnum:]]|$)"
    for (( n = 0; n < 20; n++ )); do
      [[ "$text" =~ $re ]] || break
      pre="${text%%"${BASH_REMATCH[0]}"*}"
      post="${text#*"${BASH_REMATCH[0]}"}"
      text="$pre${BASH_REMATCH[1]}$word${BASH_REMATCH[3]}$post"
    done
  done < "$REPLACEMENTS_FILE"
  shopt -u nocasematch
  printf '%s' "$text"
}

# Rebuild the automatic vocabulary in the background once a day (after a dictation,
# so it never delays one).
refresh_vocab() {
  [ "$auto_vocab" = on ] && command -v "$XHISPER_VOCAB" >/dev/null 2>&1 || return 0
  local stamp="$VOCAB_FILE.stamp"
  [ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ] && return 0
  mkdir -p "${VOCAB_FILE%/*}" && touch "$stamp"
  ( nice -n 10 "$XHISPER_VOCAB" >/dev/null 2>>"$LOGFILE" & ) 2>/dev/null
}

# A dictionary word? Learned fixes are only safe for mishearings that aren't real
# words ("Weiland" -> "Wayland" yes, "clock" -> "Claude" never).
is_dictionary_word() {
  local d
  for d in /usr/share/dict/words /usr/share/dict/american-english /usr/share/dict/cracklib-small; do
    [ -f "$d" ] && grep -qixF -- "$1" "$d" && return 0
  done
  return 1
}

# Keep the current log and one previous generation, approximately 1 MiB each.
prepare_log() {
  if [ -f "$LOGFILE" ] && [ "$(stat --format=%s "$LOGFILE")" -ge 1048576 ]; then
    mv --force -- "$LOGFILE" "$LOGFILE.1"
    chmod 600 "$LOGFILE.1"
  fi
  touch "$LOGFILE"
  chmod 600 "$LOGFILE"
}

# Diagnostic record for a streamed dictation; like transcribe's, it holds no transcript.
log_stream_attempt() {
  prepare_log
  jq --null-input --compact-output --arg timestamp "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
    --arg outcome "$1" --arg model "$assemblyai_model" \
    '{timestamp:$timestamp,backend:"assemblyai",outcome:$outcome,model:$model}' >> "$LOGFILE"
}

transcribe() (
  # Isolate cleanup from the caller's clipboard trap. Response bodies are temporary,
  # private, and never logged; only bounded diagnostic fields survive.
  umask 077
  local recording="$1"
  local logging_start=$(date +%s%N)
  local request_dir
  request_dir=$(mktemp --directory "$RUNTIME_DIR/xhisper-request.XXXXXX") || return 1
  trap 'rm -rf -- "$request_dir"' EXIT
  trap 'exit 1' TERM INT
  local attempt="${request_dir##*.}" timestamp
  timestamp=$(date --utc +%Y-%m-%dT%H:%M:%SZ)
  local audio_bytes duration
  audio_bytes=$(stat --format=%s "$recording")
  duration=$(get_duration "$recording")

  # Use large model for longer recordings, turbo for short ones
  local is_long_recording=$(echo "$duration > $long_recording_threshold" | bc -l)
  local model=$([[ $is_long_recording -eq 1 ]] && echo "whisper-large-v3" || echo "whisper-large-v3-turbo")
  local PROMPT; PROMPT=$(build_prompt)

  local http_status curl_exit transcription="" outcome api_code="" error=""
  local curl_output curl_times=""
  local request_start=$(date +%s%N) request_ms
  curl_output=$(curl --silent --show-error --request POST \
    "https://api.groq.com/openai/v1/audio/transcriptions" \
    --header "Authorization: Bearer $GROQ_API_KEY" \
    --header "Content-Type: multipart/form-data" \
    --form "file=@$recording" \
    --form "model=$model" \
    --form-string "prompt=$PROMPT" \
    --output "$request_dir/response" \
    --write-out '%{http_code}\n%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_pretransfer}\t%{time_posttransfer}\t%{time_starttransfer}\t%{time_total}' \
    2>"$request_dir/error")
  curl_exit=$?
  request_ms=$(( ($(date +%s%N) - request_start) / 1000000 ))
  http_status=${curl_output%%$'\n'*}
  # Older curl lacks time_posttransfer (added in 8.10). Missing/malformed timing
  # fields are null, never a transcription failure or invented server duration.
  [[ "$curl_output" = *$'\n'* ]] && curl_times=${curl_output#*$'\n'}
  if [ "$curl_exit" -ne 0 ]; then
    outcome=transport_error
    error=$(<"$request_dir/error")
  elif [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    outcome=api_error
    api_code=$(jq -r '.error.code // .error.type // "" | strings' "$request_dir/response" 2>/dev/null)
    error=$(jq -r '.error.message // "" | strings' "$request_dir/response" 2>/dev/null)
  elif ! jq --exit-status 'type == "object" and (has("text")) and
      (.text == null or (.text | type == "string"))' "$request_dir/response" >/dev/null 2>&1; then
    outcome=invalid_response
  else
    transcription=$(jq -r '.text // "" | sub("^ "; "")' "$request_dir/response")
    local spoken="${transcription,,}"; spoken="${spoken%.}"
    if [[ -z "${transcription//[[:space:]]/}" ]]; then
      outcome=empty_transcription
    elif [ ${#spoken} -gt 20 ] && [[ "${PROMPT,,}" == *"$spoken"* ]]; then
      outcome=prompt_echo  # on near-silent audio Whisper sometimes returns its prompt
    else
      outcome=success
    fi
  fi
  # Redact the credential even if a remote error unexpectedly echoes it.
  if [ -n "$GROQ_API_KEY" ]; then
    error="${error//"$GROQ_API_KEY"/[REDACTED]}"
    api_code="${api_code//"$GROQ_API_KEY"/[REDACTED]}"
  fi
  local elapsed_ms=$(( ($(date +%s%N) - logging_start) / 1000000 ))
  prepare_log
  jq --null-input --compact-output \
    --arg timestamp "$timestamp" --arg attempt "$attempt" --arg outcome "$outcome" \
    --arg model "$model" --arg http_status "$http_status" \
    --arg api_code "${api_code:0:128}" --arg error "${error:0:512}" \
    --argjson curl_exit "$curl_exit" --argjson elapsed_ms "$elapsed_ms" --argjson request_ms "$request_ms" \
    --argjson audio_seconds "$duration" --argjson audio_bytes "$audio_bytes" \
    --arg curl_times "$curl_times" \
    'def milliseconds: if . == null then null else round end;
     def reached: if . != null and . > 0 then . else null end;
     def interval($end; $start):
       if $end != null and $start != null and $end >= $start
       then ($end - $start | round) else null end;
     ($curl_times | split("\t") | map(
       if test("^[0-9]+(\\.[0-9]+)?$") then (tonumber * 1000) else null end)) as $t |
     {timestamp:$timestamp,attempt:$attempt,outcome:$outcome,model:$model,
      http_status:$http_status,curl_exit:$curl_exit,elapsed_ms:$elapsed_ms,request_ms:$request_ms,
      audio_seconds:$audio_seconds,audio_bytes:$audio_bytes,
      api_code:$api_code,error:$error,
      request_timing:{
        dns_ms:($t[0] | milliseconds),
        tcp_connect_ms:interval(($t[1] | reached); $t[0]),
        tls_ms:interval(($t[2] | reached); ($t[1] | reached)),
        transfer_setup_ms:interval(($t[3] | reached); ($t[2] | reached)),
        upload_ms:interval(($t[4] | reached); ($t[3] | reached)),
        upstream_wait_ms:interval(($t[5] | reached); ($t[4] | reached)),
        download_ms:interval($t[6]; ($t[5] | reached)),
        upload_complete_ms:($t[4] | reached | milliseconds),
        first_byte_ms:($t[5] | reached | milliseconds),
        total_ms:($t[6] | milliseconds)
      }}' >> "$LOGFILE"
  [ "$outcome" = success ] || return 1
  printf '%s\n' "$(apply_replacements "$transcription")"
)

# The selected text (PRIMARY selection): what --learn teaches when no WORD is given.
selected_text() {
  { [ -n "$WAYLAND_DISPLAY" ] && timeout 0.3 wl-paste --primary --no-newline 2>/dev/null; } ||
    timeout 0.3 xclip -o -selection primary 2>/dev/null
}

# Second press of a --learn dictation: compare what Whisper heard with the word.
# The word is already in WORDS_FILE (so it's in the prompt); if Whisper still heard
# something else that isn't a dictionary word, save "heard -> word" as a fix.
finish_learn() {
  local word heard heard_clean msg
  word=$(cat "$LEARN_FILE"); rm -f "$LEARN_FILE"
  heard="$1"
  heard_clean="${heard%"${heard##*[![:space:].,!?;:]}"}"   # drop trailing punctuation
  heard_clean="${heard_clean#"${heard_clean%%[![:space:]]*}"}"
  if [ -z "$heard_clean" ] || [ "${heard_clean,,}" = "${word,,}" ]; then
    msg="Learned \"$word\""
  elif [[ "$heard_clean" =~ ^[[:alnum:]\ \'-]{2,40}$ ]] && [ "$(wc -w <<< "$heard_clean")" -le 4 ]; then
    local w common=0
    for w in $heard_clean; do is_dictionary_word "$w" && common=1; done
    if [ "$common" -eq 0 ] && ! grep -qiF -- "$heard_clean"$'\t' "$REPLACEMENTS_FILE" 2>/dev/null; then
      printf '%s\t%s\n' "$heard_clean" "$word" >> "$REPLACEMENTS_FILE"
      msg="Learned \"$word\" (will fix \"$heard_clean\")"
    else
      msg="Learned \"$word\" (heard \"$heard_clean\": real words, so no auto-fix)"
    fi
  else
    msg="Learned \"$word\" (heard \"$heard_clean\")"
  fi
  echo "=== learn: taught a word ===" >> "$LOGFILE"  # no transcript text in the log
  notify "$msg" 4000
}

# Main

# Never leave a saved clipboard copy behind, whatever path the script exits by.
trap '[ -n "$CLIP_FILE" ] && rm -f "$CLIP_FILE"' EXIT

# Wait until min-latency ms have passed since this run started (the stop key press),
# so fast paths don't feel different from slow ones.
pad_to_min_latency() {
  local elapsed=$(( ($(date +%s%N) - T0) / 1000000 )) wait_ms
  wait_ms=$(( ${min_latency:-0} - elapsed ))
  [ "$wait_ms" -gt 0 ] && sleep "$(( wait_ms / 1000 )).$(printf '%03d' $(( wait_ms % 1000 )))"
  mark pad
}

# ms since the previous mark; appends "name=Nms" to TIMING
TIMING=""; T_LAST=$T0
mark() {
  local now
  if [ -n "${EPOCHREALTIME:-}" ]; then now=${EPOCHREALTIME/./}000
  else now=$(date +%s%N); fi
  TIMING+="$1=$(( (now - T_LAST) / 1000000 ))ms "
  T_LAST=$now
}

REC_PID_FILE="$RUNTIME_DIR/xhisper-rec.pid"
STREAM_TEXT="$RUNTIME_DIR/xhisper-stream.txt"  # xhisper-stream's transcript

# Words for AssemblyAI's keyterms_prompt (max 100): the same list as the Whisper prompt.
keyterms_json() {
  local IFS=$'\n'
  build_prompt | sed 's/, /\n/g' | jq -Rsc 'split("\n") | map(select(length > 0 and length <= 50)) | .[:100]'
}

# A recording is running: stop it and transcribe
if REC_PID=$(read_pid "$REC_PID_FILE") && { pid_is "$REC_PID" pw-record || pid_is "$REC_PID" xhisper-stream; }; then
  mark startup
  LEARNING=0; [ -s "$LEARN_FILE" ] && LEARNING=1
  CLIP_SAVED=0; TRANSCRIPTION=""; STREAMED=0
  if pid_is "$REC_PID" xhisper-stream; then
    # Streaming: AssemblyAI has been transcribing all along; ask for the last turn.
    kill -USR1 "$REC_PID"
    indicator_hide
    mark stop
    if [ "$insert_mode" = "paste" ] && [ "$LEARNING" -eq 0 ]; then
      focus_query
      mark focus
      clip_save
      mark clipboard-save
      CLIP_SAVED=1
    fi
    for _ in {1..600}; do pid_is "$REC_PID" xhisper-stream || break; sleep 0.005; done  # up to 3 s
    rm -f "$REC_PID_FILE"
    if [ -f "$STREAM_TEXT" ]; then
      STREAMED=1
      TRANSCRIPTION=$(cat "$STREAM_TEXT"); rm -f "$STREAM_TEXT"
      TRANSCRIPTION=$(apply_replacements "$TRANSCRIPTION")
      mark stream-wait
      log_stream_attempt "$([ -n "$TRANSCRIPTION" ] && echo success || echo empty_transcription)"
      if [ -z "$TRANSCRIPTION" ]; then
        notify "No speech detected"
        rm -f "$RECORDING" "$LEARN_FILE"
        exit 0
      fi
    else
      log_stream_attempt stream_failed
      mark stream-failed
    fi
  else
    kill "$REC_PID"
    # pw-record finalizes the WAV header on exit; wait for that (up to 0.5 s).
    for _ in {1..100}; do pid_is "$REC_PID" pw-record || break; sleep 0.005; done
    rm -f "$REC_PID_FILE"
    indicator_hide
    mark stop
  fi

  if [ "$STREAMED" -eq 0 ]; then
    # Upload right away; check for silence and save the clipboard while it runs.
    TRANSCRIPT_FILE=$(mktemp "$RUNTIME_DIR/xhisper-transcript.XXXXXX")
    transcribe "$RECORDING" > "$TRANSCRIPT_FILE" &
    TRANSCRIBE_PID=$!
    mark transcribe-start

    if is_silent "$RECORDING"; then
      kill "$TRANSCRIBE_PID" 2>/dev/null
      notify "No sound detected"
      rm -f "$RECORDING" "$TRANSCRIPT_FILE" "$LEARN_FILE"
      exit 0
    fi
    mark silence
    if [ "$insert_mode" = "paste" ] && [ "$LEARNING" -eq 0 ] && [ "$CLIP_SAVED" -eq 0 ]; then
      focus_query
      mark focus
      clip_save
      mark clipboard-save
    fi

    wait "$TRANSCRIBE_PID"
    TRANSCRIPTION=$(cat "$TRANSCRIPT_FILE"); rm -f "$TRANSCRIPT_FILE"
    mark transcribe-wait
  fi
  if [ -z "$TRANSCRIPTION" ] || [ "$TRANSCRIPTION" = "null" ]; then
    notify "Transcription failed (see xhisper --log)" 4000
    rm -f "$RECORDING" "$LEARN_FILE"
    exit 1
  fi
  if [ "$LEARNING" -eq 1 ]; then  # teaching a word: nothing is pasted
    finish_learn "$TRANSCRIPTION"
    rm -f "$RECORDING"
    exit 0
  fi
  # A space after each dictation, so the next one doesn't run into it.
  [ "$trailing_space" = on ] && [[ "$TRANSCRIPTION" != *[[:space:]] ]] && TRANSCRIPTION+=" "

  if [ "$insert_mode" = "paste" ] && clip_stage "$TRANSCRIPTION"; then
    mark clipboard
    pad_to_min_latency
    paste_staged
    mark paste+restore
  else
    pad_to_min_latency
    paste "$TRANSCRIPTION"
    mark type
  fi
  echo "Timing: ${TIMING}total=$(( ($(date +%s%N) - T0) / 1000000 ))ms (${#TRANSCRIPTION} chars)" >> "$LOGFILE"

  rm -f "$RECORDING"
  refresh_vocab
else
  # No recording running, so start
  rm -f "$LEARN_FILE"
  if [ "$LEARN" -eq 1 ]; then
    # Teach a word: take it from the argument or the selection, add it to the
    # vocabulary now, then record you saying it (stop with either hotkey).
    word="${LEARN_WORD:-$(selected_text)}"
    word="${word#"${word%%[![:space:]]*}"}"; word="${word%"${word##*[![:space:]]}"}"
    if [ -z "$word" ] || [ ${#word} -gt 40 ] || [[ "$word" == *$'\n'* ]]; then
      notify "Select a word (or short name) to teach, then press the learn key" 4000
      exit 1
    fi
    mkdir -p "$CONFIG_DIR"
    grep -qixF -- "$word" "$WORDS_FILE" 2>/dev/null || echo "$word" >> "$WORDS_FILE"
    printf '%s' "$word" > "$LEARN_FILE"
    notify "Say \"$word\", then press the key again" 3000
  fi
  indicator_show
  if [ "$backend" = assemblyai ] && command -v "$XHISPER_STREAM" >/dev/null 2>&1; then
    # Stream to AssemblyAI while recording (also saves $RECORDING for a Groq fallback).
    rm -f "$STREAM_TEXT"
    prepare_log
    export ASSEMBLYAI_API_KEY XHISPER_ASSEMBLYAI_API_KEY YTKB_ASSEMBLYAI_API_KEY
    XHISPER_KEYTERMS=$(keyterms_json 2>/dev/null) \
      "$XHISPER_STREAM" --wav "$RECORDING" --text "$STREAM_TEXT" --model "$assemblyai_model" \
      2>> "$LOGFILE" &
  else
    pw-record --channels=1 --rate=16000 "$RECORDING" &
  fi
  echo $! > "$REC_PID_FILE"
  wait $!
fi
