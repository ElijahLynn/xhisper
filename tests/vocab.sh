#!/bin/bash
# Vocabulary tests: xhisper-vocab's word picking, and xhisper.sh's prompt building,
# learned fixes and --learn bookkeeping. Offline: no Groq, no audio, no clipboard.
#
# usage: tests/vocab.sh   (or: make test-vocab)

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
check() {  # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: [$2]"; echo "     got:  [$3]"; fails=$((fails + 1)); fi
}

# --- xhisper-vocab --------------------------------------------------------------
mkdir -p "$W/transcripts/p" "$W/projects/Telnyx-bridge" "$W/cache"
now=$(date -u +%Y-%m-%dT%H:%M:%S)
msg() { jq -cn --arg t "$1" --arg ts "$now" '{type:"user",timestamp:$ts,message:{content:$t}}'; }
{
  msg "Deploy the Hetzner box and ping Supabase"           # Hetzner, Supabase: 2 messages each
  msg "Hetzner is cheaper; Supabase auth is fine"
  msg "questoin questoin questoin about the deploy"         # typo, one message only
  msg "SELECT id FROM users WHERE KEY = 1"                  # SQL / all caps
  msg "branch please-corp-5f7b5c98 and commit e29b1c0"      # IDs
  msg "it isn't working, the laptop and sandbox are fine"   # contraction, compounds
  msg "Check https://github.com/Foo/bar and src/Thing.ts"   # URL, path
} > "$W/transcripts/p/s.jsonl"
XDG_CACHE_HOME="$W/cache" XHISPER_VOCAB_TRANSCRIPTS="$W/transcripts/*/*.jsonl" \
  XHISPER_VOCAB_PROJECTS="$W/projects" \
  python3 -I "$REPO/xhisper-vocab" || { echo "FAIL xhisper-vocab crashed"; exit 1; }
vocab=$(sort "$W/cache/xhisper/vocab" | tr '\n' ' ')
check "vocab: typed twice, unusual; folder-name word" "Hetzner Supabase Telnyx " "$vocab"

# --- xhisper.sh functions ---------------------------------------------------------
RUNTIME_DIR="$W"
# Load only the vocabulary functions (sourcing the whole script would run it).
source <(sed -n '/^# --- Vocabulary ---/,/^transcribe() (/p' "$REPO/xhisper.sh" | sed '$d')
LOGFILE="$W/log"; notify() { :; }
source <(sed -n '/^finish_learn() {/,/^}/p' "$REPO/xhisper.sh")
WORDS_FILE="$W/words"; REPLACEMENTS_FILE="$W/replacements"; VOCAB_FILE="$W/vocab"
LEARN_FILE="$W/learn"; auto_vocab=on

transcription_prompt="Claude, Warp"
printf 'Hetzner\nclaude\nSupabase\n' > "$VOCAB_FILE"
printf 'XWayland\nTelnyx\n' > "$WORDS_FILE"
check "prompt: manual, taught newest first, vocab, no duplicates" \
  "Claude, Warp, Telnyx, XWayland, Hetzner, Supabase" "$(build_prompt)"
auto_vocab=off
check "prompt: auto-vocab off" "Claude, Warp, Telnyx, XWayland" "$(build_prompt)"
auto_vocab=on
PROMPT_BUDGET=30
check "prompt: cut to the budget" "Claude, Warp, Telnyx, XWayland" "$(build_prompt)"
PROMPT_BUDGET=600

printf 'xWeiland\tXWayland\nWeiland\tWayland\n' > "$REPLACEMENTS_FILE"
check "fix: whole words, any case, next to punctuation" \
  "The XWayland window broke the Wayland clipboard. Wayland!" \
  "$(apply_replacements "The xweiland window broke the Weiland clipboard. weiland!")"
check "fix: not inside other words" "Weilands Weilandx" "$(apply_replacements "Weilands Weilandx")"

: > "$REPLACEMENTS_FILE"
printf 'Wayland' > "$LEARN_FILE"; finish_learn "Wayland."
check "learn: heard right, no fix saved" "" "$(cat "$REPLACEMENTS_FILE")"
printf 'Wayland' > "$LEARN_FILE"; finish_learn "Weiland."
check "learn: non-word mishearing saved as a fix" "Weiland	Wayland" "$(cat "$REPLACEMENTS_FILE")"
printf 'Claude' > "$LEARN_FILE"; finish_learn "Clock."
check "learn: real-word mishearing never saved" "Weiland	Wayland" "$(cat "$REPLACEMENTS_FILE")"
check "learn: pending word cleared" "no" "$([ -e "$LEARN_FILE" ] && echo yes || echo no)"

[ "$fails" -eq 0 ] && echo "vocab: PASS" || { echo "vocab: $fails FAILED"; exit 1; }
