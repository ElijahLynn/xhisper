# xhisper-indicator (GNOME Shell extension)

An on-screen recording indicator for xhisper on GNOME (Wayland or X11). While you
record, a small animated level meter floats at the bottom center of the primary
monitor, like groq-flow's macOS indicator. Nothing is typed into the focused app,
and the overlay never takes keyboard focus or pointer input.

Without the extension there is no indicator; xhisper logs "indicator unavailable" to /tmp/xhisper.log.

## Install

Requires GNOME Shell 45 or newer (tested on 51).

```sh
# Option A: install a copy
gnome-extensions pack --force extension -o /tmp \
  && gnome-extensions install --force /tmp/xhisper-indicator@elijahlynn.net.shell-extension.zip

# Option B: symlink for development
ln -sfn "$PWD/extension" ~/.local/share/gnome-shell/extensions/xhisper-indicator@elijahlynn.net
```

Then log out and back in once so GNOME Shell discovers the extension (on Wayland
the shell can't be restarted in place), and enable it:

```sh
gnome-extensions enable xhisper-indicator@elijahlynn.net
```

## Configure

In `~/.config/xhisper/xhisperrc`:

```
indicator-color : red      # red, orange, yellow, green, blue, purple, pink, white
indicator-style : meter    # meter (level bars) or orb (pulsing orb)
```

Unknown colors fall back to red, and unknown styles fall back to meter.

## D-Bus interface

The extension exports `io.github.elijahlynn.XhisperIndicator` at
`/io/github/elijahlynn/XhisperIndicator` on gnome-shell's own bus name
(`org.gnome.Shell`):

```sh
gdbus call --session --dest org.gnome.Shell --object-path /io/github/elijahlynn/XhisperIndicator \
  --method io.github.elijahlynn.XhisperIndicator.Show red meter
gdbus call --session --dest org.gnome.Shell --object-path /io/github/elijahlynn/XhisperIndicator \
  --method io.github.elijahlynn.XhisperIndicator.Hide
```

`Show` while already shown switches to the new color or style. `Hide` stops the
animation and removes the overlay.

`FocusedWindow()` returns `(s wm_class, s app_id, s client)` for the focused
window, so xhisper can pick a paste key per app (terminals paste with
Ctrl+Shift+V) and a clipboard tool (`client` is `x11` for XWayland windows, where
the Wayland clipboard tools fail, else `wayland`). On Wayland only the compositor
can see this. All strings are empty when nothing has focus, including while the
overview is open:

```sh
gdbus call --session --dest org.gnome.Shell --object-path /io/github/elijahlynn/XhisperIndicator \
  --method io.github.elijahlynn.XhisperIndicator.FocusedWindow
# ('org.gnome.Console', 'org.gnome.Console.desktop', 'wayland')
```

`app_id` is the desktop file ID. If the window doesn't match a desktop file,
GNOME returns a placeholder like `window:2`, so match on `wm_class` first.

## Development

GJS caches extension modules, so after editing `extension.js`, disabling and
re-enabling the extension doesn't load the new code. Test in a nested shell instead:

```sh
dbus-run-session -- gnome-shell --devkit --wayland
```

Run it with its own `XDG_CONFIG_HOME` and `XDG_RUNTIME_DIR` exported *before*
`dbus-run-session`. Otherwise the nested session's dconf-service writes to your real
settings, and enabling extensions there overwrites your desktop's `enabled-extensions`.
