# xhisper */ˈzɪspər/*

Push-to-dictate for Linux. Press a key, talk, press it again: your words appear at
the cursor in whatever app has focus.

- **Fast:** text appears about 0.4–0.5 s after you stop, transcribed by Groq's
  `whisper-large-v3-turbo` (free tier available).
- **Pastes, doesn't type:** the whole transcription lands in one paste, then your
  previous clipboard is put back.
- **On-screen indicator:** a small red level meter at the bottom of the screen while
  you record (GNOME Shell extension). Nothing is ever typed into your app except
  your words.
- **Works in terminals:** sends Ctrl+Shift+V to terminals and Ctrl+V everywhere
  else, automatically.

Fork of [imaginalnika/xhisper](https://github.com/imaginalnika/xhisper).

## Install

### 1. Dependencies

```sh
# Arch
sudo pacman -S pipewire jq curl ffmpeg gcc wl-clipboard xclip libnotify
# Debian / Ubuntu
sudo apt install pipewire-bin jq curl ffmpeg gcc wl-clipboard xclip libnotify-bin
# Fedora
sudo dnf install pipewire-utils jq curl ffmpeg gcc wl-clipboard xclip libnotify
```

`xclip` is needed even on Wayland: the Wayland clipboard tools fail while an X11
(XWayland) app such as Warp has focus, and xhisper falls back to X11 then. Building
the `xhisperclip` helper needs the libX11 headers (`libx11-dev` on Debian/Ubuntu,
`libX11-devel` on Fedora; included with `libx11` on Arch).

### 2. Access to `/dev/uinput`

xhisper sends the paste keystroke through a virtual keyboard:

```sh
sudo usermod -aG input $USER
```

Log out and back in, then check that `groups` lists `input`.

### 3. Groq API key

Create one at [https://console.groq.com/keys](https://console.groq.com/keys) and add it
to `~/.env`:

```sh
GROQ_API_KEY=gsk_...
```

### 4. Build and install

```sh
git clone https://github.com/ElijahLynn/xhisper.git
cd xhisper && make && sudo make install
```

### 5. Recording indicator (GNOME)

```sh
ln -sfn "$PWD/extension" ~/.local/share/gnome-shell/extensions/xhisper-indicator@elijahlynn.net
```

Log out and back in once so GNOME Shell finds it, then:

```sh
gnome-extensions enable xhisper-indicator@elijahlynn.net
```

The extension also tells xhisper which app has focus, which is how it picks the
right paste key. Details: [extension/README.md](extension/README.md).

### 6. Bind a key

Caps Lock is the hotkey: press it to start dictating, press it again to stop. On GNOME:

```sh
name=xhisper; binding=Caps_Lock; action=/usr/local/bin/xhisper
media_keys=org.gnome.settings-daemon.plugins.media-keys
kbd_path=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$name/
gsettings set $media_keys custom-keybindings \
  "$(gsettings get $media_keys custom-keybindings | sed -e "s>'\]>','$kbd_path']>" -e "s>@as \[\]>['$kbd_path']>")"
gsettings set $media_keys.custom-keybinding:$kbd_path name "$name"
gsettings set $media_keys.custom-keybinding:$kbd_path binding "$binding"
gsettings set $media_keys.custom-keybinding:$kbd_path command "$action"
```

Tip: if Caps Lock is ever ON when you aren't dictating (say, you pressed it while a
system prompt was open), press **Shift+Caps Lock** once to put it back in step.

Other setups:

| Tool | Binding |
|---|---|
| sway / i3 | `bindsym $mod+d exec xhisper` |
| Hyprland | `bind = $mainMod, D, exec, xhisper` |
| sxhkd | `super + d` → `xhisper` |

## Use

1. Press your key: recording starts and the red meter appears.
2. Talk.
3. Press it again: the transcription is pasted at your cursor.

Silent recordings are ignored with a "No sound detected" notification. Failed
transcriptions show "Transcription failed".

```sh
xhisper --log   # show diagnostics, per-step timing, and warnings
```

Each transcription attempt writes a JSON diagnostic record with a UTC start time,
attempt ID, outcome, model, audio duration/size, elapsed and request time, curl
exit code, HTTP status, and bounded API/transport error details. Outcomes distinguish transport
errors, API errors, invalid responses, empty transcriptions, and success. New
records contain no transcript text, audio, or authorization header. API error
messages are limited to 512 characters and the configured API key is redacted.
Temporary response files are private and removed when the attempt exits.

`request_timing` adds numeric curl phases in milliseconds: DNS, TCP connection,
TLS, transfer setup, upload, upstream wait after upload, and response download.
`upload_complete_ms`, `first_byte_ms`, and `total_ms` are cumulative curl offsets,
not additional phases. The existing `request_ms` includes curl process overhead.
Upstream wait includes network/edge/provider waiting, not pure Groq compute;
upload timing can include HTTP setup/100-Continue delays. Missing, unfinished,
or inconsistent intervals are `null`, not zero or a failed transcription.
Measured durations round to the nearest millisecond, so a very fast measured
phase can be zero. Upload completion means the last byte was sent by libcurl,
not that the remote server acknowledged receipt.
Upload-completion timing requires curl 8.10 or later; older versions retain the
other measurements. Only the named timing values are captured, never a full
curl metadata dump, headers, or request body.

The `Timing:` line separates `silence`, `focus`, and `clipboard-save` instead of
combining them. These overlap the transcription request and must not be added to
request time. Stage marks use Bash's built-in clock when available to avoid
launching a process per mark, with `date` as the older-Bash fallback.
The normal 450ms pacing floor and 40ms Wayland focus delay are unchanged.
The log is owner-only and rotates at approximately 1 MiB, retaining one previous
generation (`/tmp/xhisper.log.1`). Existing legacy entries may still contain
transcript text until rotated out. Failed audio is not retained.

Run `make check` for isolated diagnostic regression tests (no API key, network,
or clipboard access). `make perf` is the separate offline application gate;
`make perf-live` explicitly benchmarks live Groq requests.

**Non-QWERTY layouts:** set up a key that switches your input to QWERTY, then bind
`xhisper --rightalt` (or `--leftalt`, `--leftctrl`, `--rightctrl`, `--leftshift`,
`--rightshift`, `--super`) instead of plain `xhisper`. It presses that key before
and after inserting text. This only matters for `insert-mode : type`.

## Configure

Optional. Copy the defaults and edit:

```sh
mkdir -p ~/.config/xhisper && cp default_xhisperrc ~/.config/xhisper/xhisperrc
```

| Setting | Default | What it does |
|---|---|---|
| `insert-mode` | `paste` | `paste`: insert all at once via the clipboard, then restore it. `type`: send one key per character (slower; no clipboard use) |
| `paste-key` | `auto` | `auto`: Ctrl+Shift+V in terminals, Ctrl+V elsewhere. Or force `ctrl+v` / `ctrl+shift+v` |
| `min-latency` | `450` | Text never appears sooner than this many ms after the stop key press, so every app feels the same. `0` disables it |
| `indicator-color` | `red` | `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `white` |
| `indicator-style` | `meter` | `meter` (animated level bars) or `orb` (pulsing orb) |
| `transcription-prompt` | *(empty)* | Optional context words for Whisper. Short is best: a long prompt can be echoed back instead of transcribed |
| `long-recording-threshold` | `1000` | Recordings longer than this many seconds use `whisper-large-v3` instead of turbo |
| `silence-threshold` | `-50` | Peak volume in dB below which a recording counts as silent |
| `type-key-gap` | `2000` | `type` mode: microseconds between keys. Raise it if an app drops keys |
| `non-ascii-initial-delay` / `non-ascii-default-delay` | `0.15` / `0.025` | `type` mode: seconds to wait after pasting a non-ASCII character |

### Clipboard behavior (paste mode)

- Your clipboard is saved before the paste and restored right after, whatever it
  held (text, image, anything). If it was empty, it's cleared again.
- The transcription is copied with the "sensitive" hint, so clipboard-history tools
  that honor it (Strata, KDE Klipper, ...) don't record dictations. On the X11 path
  the bundled `xhisperclip` helper sets the hint, since `xclip` can't; if it's
  missing, xhisper falls back to `xclip` and dictations into X11 apps reach history.
- Every clipboard call is time-limited, so a clipboard owner that never answers
  can't hang xhisper.
- The Wayland clipboard tools time out in X11 (XWayland) windows, and in some
  Wayland apps too (Warp, even in its Wayland mode). The indicator extension tells
  xhisper whether the focused window is X11, so those go straight to the X11
  clipboard. Other apps where the Wayland tools time out twice in a row are learned
  in `~/.cache/xhisper/x11-apps` and use X11 straight away from then on (a single
  timeout is just a hiccup). Delete a line there to make xhisper re-check an app.

## Troubleshooting

- **Text is typed instead of pasted.** Check `xhisper --log` for "typing instead":
  the clipboard couldn't be set. Install both `wl-clipboard` and `xclip`.
- **Nothing appears in a terminal.** The terminal needs Ctrl+Shift+V. Make sure the
  indicator extension is enabled (`gnome-extensions info
  xhisper-indicator@elijahlynn.net` shows `ACTIVE`) so `paste-key : auto` can see the
  focused app, or set `paste-key : ctrl+shift+v`.
- **No red meter.** The log says "indicator unavailable": enable the extension (step
  5) and log out and back in if you just installed it.
- **Keys dropped in `type` mode.** Raise `type-key-gap`, or use `insert-mode : paste`.

## How it works

`xhisper` is a bash script: the first run starts `pw-record` (its PID goes in
`/tmp/xhisper-rec.pid`; processes are checked through `/proc`, not `pgrep`, which
costs ~50 ms per call on a busy desktop), the second stops it,
uploads the WAV to Groq (while the silence check and clipboard save run in
parallel), and pastes the result. `xhispertoold` is a small daemon that owns a
uinput virtual keyboard; `xhispertool` sends it commands (`paste`, `pasteshift`,
`type`, `backspace`). The GNOME extension draws the indicator and reports the
focused window over D-Bus.

## Performance

Goal: every dictation feels the same and lands within **0.5 s** of the stop key
press, in any app. `min-latency` (450 ms) pads the faster path so a GUI app and a
terminal feel identical.

Earlier live measurements (median of 5 runs each, real Groq transcription):

| Path | Median | What differs |
|---|---|---|
| GUI app (Wayland clipboard) | ~480 ms | `wl-copy` + 40 ms for keyboard focus to return |
| X11 app such as Warp (`xclip`) | ~472 ms | `xclip`, no focus wait; padded up to the floor |

Where the time goes before padding: startup ~8 ms, stopping the recorder ~20 ms,
upload + Groq transcription ~300 ms (upload itself is only ~10–25 ms; the silence
check, focus lookup and clipboard save run in parallel), clipboard ~10–90 ms. Groq
was the fastest provider tested; DeepInfra and Cloudflare Workers AI were 2–15×
slower. Compressing audio before upload doesn't help.

### Performance gate

`make perf` runs the real application script with synthetic audio, an immediate
mock API response, and pacing disabled. It runs 20 samples per path and checks
separate median/p95 limits from `tests/perf-budget.json`, never regenerating them
from current-code results. It needs no Groq key and never sources `~/.env`.
The limits are provisional noise estimates from old-code samples, not a portable
latency guarantee. An independent validation has exceeded these pilot limits even
with correct delivery; do not bypass a failure or interpret it as proof of a code
regression without examining the retained samples.

- **Native Wayland:** a disposable headless GNOME Shell with its own profile,
  runtime directory, socket, and session bus. Xwayland is disabled and any X11
  clipboard fallback is rejected. The real script saves/stages/restores a
  synthetic clipboard, and a virtual keyboard sends Ctrl+V into a disposable
  GTK editor. Every sample must contain the exact expected text and restore the
  fixture. The production uinput daemon is replaced at its key-dispatch seam.
- **X11:** real `xhisperclip`/`xclip` against private Xvfb, with clipboard
  restoration and paste-dispatch checks. It does not verify editor delivery.

The timed metric ends at key dispatch, not GTK delivery. Both tests keep the
desktop clipboard untouched. Additional test dependencies include GNOME Shell,
Python GObject introspection with GTK4, `espeak-ng`, Xvfb, `dbus-run-session`,
and the application's normal tools. Test compositor versions are listed in
`tests/wayland-session.sh`.

```sh
make perf     # run it
make perf-live # five live requests per path, normal 450ms pacing
make test-wayland # 20 real GTK pastes at the existing 40ms delay
make hooks    # once per clone: run it before every commit that touches the code
```

`make perf-live` reports request latency and invocation-to-paste dispatch
separately, including every sample and each median/p95. Request time includes
network/upload/provider latency, not pure Groq compute. Never subtract it from
the total: clipboard saving overlaps the request. The 500ms live target is
informational and cannot block a commit; API or correctness failures still fail
the benchmark. Only synthetic speech is submitted.

It also reports each request phase and local stage, with per-phase median/p95
and a count of available measurements in the retained JSON. Successful live
runs retain both result files in the printed private temporary directory;
unavailable phases are excluded from statistics rather than counted as zero.

`tests/calibrate-perf.py` compares pinned commit
`d8e555176abd46f9791ad631f7d72223acdda74e` with the working script in alternating
order, two rounds of 20 samples per version. Raw evidence is stored in
`tests/perf-calibration-{wayland,x11}.json`. Limits use the 99th percentile of
10,000 seeded, baseline-only bootstrap batches of 20 (nearest-rank p95).
This small pilot does not model long-term system load or compositor jitter.

For explicit delay experiments, run the probe through
`bash tests/wayland-session.sh python3 tests/paste-delay.py --delays 0 10 20 40 --runs 10 --output /tmp/xhisper-paste.json`.
Any lost paste fails the probe. It records the interval from `wl-copy` return to
virtual-key enqueue: D-Bus adds latency, so 0ms sleep is not immediate production
dispatch and cannot justify removing the 40ms focus-return delay.

The pre-commit hook runs `make check` and the offline gate for code/test changes.
Failures preserve structured evidence in the printed temporary directory.

### Next steps to make it feel local

1. **Stream while speaking:** send finished phrases at pauses during recording, so
   only the last phrase is pending when you stop. The only way to hide Groq's
   ~250 ms processing time. Groq has no streaming API, so this means phrase
   chunking.
2. **Persistent daemon:** keep xhisper running and have the key signal it. Startup is
   already ~8 ms, so the main gain is making item 1 easier to build.
3. **Warm HTTPS connection:** reuse one connection to Groq from the daemon (saves
   ~30 ms; only worth it with item 2).
4. **Insert text without the clipboard:** e.g. commit text directly through the GNOME
   extension or an input method. Removes the ~160 ms Wayland clipboard step in GUI
   apps and never touches your clipboard.

## License

[MIT](LICENSE)
