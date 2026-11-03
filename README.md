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
(XWayland) app such as Warp has focus, and xhisper falls back to `xclip` then.

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

Bind `/usr/local/bin/xhisper` to any key. On GNOME, for example Caps Lock:

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

Other setups:

| Tool | Binding |
|---|---|
| sway / i3 | `bindsym $mod+d exec xhisper` |
| Hyprland | `bind = $mainMod, D, exec, xhisper` |
| sxhkd | `super + d` → `xhisper` |
| keyd | `capslock = layer(dictate)`, then `[dictate:C]` with `d = macro(xhisper)` |

## Use

1. Press your key: recording starts and the red meter appears.
2. Talk.
3. Press it again: the transcription is pasted at your cursor.

Silent recordings are ignored with a "No sound detected" notification. Failed
transcriptions show "Transcription failed".

```sh
xhisper --log   # show the log: transcriptions, per-step timing, warnings
```

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
  that honor it don't record dictations. (Not possible through `xclip`, so dictations
  into X11 apps can't carry the hint.)
- Every clipboard call is time-limited, so a clipboard owner that never answers
  can't hang xhisper.
- X11 (XWayland) apps such as Warp make the Wayland clipboard tools time out. The
  first time that happens in an app, xhisper remembers it in
  `~/.cache/xhisper/x11-apps` and uses `xclip` straight away from then on.

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

Each dictation logs a `Timing:` line. Typical numbers (Arch, GNOME 51, paste mode),
measured from the second key press:

| Step | GUI app | Warp (X11) |
|---|---|---|
| Script startup | ~8 ms | ~8 ms |
| Stop recording | ~23 ms | ~23 ms |
| Upload + Groq transcription (silence check, focus lookup and clipboard save run in parallel) | ~300 ms | ~330 ms |
| Clipboard + paste key | ~160 ms (`wl-copy` + 80 ms focus wait) | ~9 ms (`xclip`) |
| **Text appears after** | **~0.47 s** | **~0.37 s** |

Upload itself is only ~10–25 ms; Groq's processing (~200–300 ms) is most of the
wait. Groq was the fastest provider tested; DeepInfra and Cloudflare Workers AI were
2–15× slower for the same audio. Compressing audio before upload doesn't help
(encoding costs more than the upload it saves).

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
