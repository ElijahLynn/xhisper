// xhisper-indicator: on-screen recording indicator for xhisper.
//
// xhisper.sh toggles it over D-Bus on gnome-shell's own session-bus connection:
//   gdbus call --session --dest org.gnome.Shell \
//     --object-path /io/github/elijahlynn/XhisperIndicator \
//     --method io.github.elijahlynn.XhisperIndicator.Show red meter
//   gdbus call ... --method io.github.elijahlynn.XhisperIndicator.Hide
//
// Look and timing follow groq-flow's Hammerspoon indicator (examples/hammerspoon-init.lua):
// "meter" is a row of thin bars whose heights jump every 100ms, "orb" is a breathing
// translucent sphere with a colored lightning bolt. Both sit bottom-center on the primary
// monitor's work area, above windows, and never take focus or pointer input.

import Cairo from 'cairo';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const OBJECT_PATH = '/io/github/elijahlynn/XhisperIndicator';
const IFACE_XML = `
<node>
  <interface name="io.github.elijahlynn.XhisperIndicator">
    <method name="Show">
      <arg type="s" direction="in" name="color"/>
      <arg type="s" direction="in" name="style"/>
    </method>
    <method name="Hide"/>
    <method name="FocusedWindow">
      <arg type="s" direction="out" name="wm_class"/>
      <arg type="s" direction="out" name="app_id"/>
      <arg type="s" direction="out" name="client"/>
    </method>
  </interface>
</node>`;

// groq-flow's color table (red is the Grok bolt, #EE4F35).
const COLORS = {
    red: [0.933, 0.310, 0.208],
    orange: [1.00, 0.58, 0.00],
    yellow: [1.00, 0.80, 0.00],
    green: [0.20, 0.80, 0.35],
    blue: [0.20, 0.52, 1.00],
    purple: [0.70, 0.30, 0.95],
    pink: [1.00, 0.35, 0.70],
    white: [0.95, 0.95, 0.95],
};

const PAD = 36; // px above the bottom of the work area

// Meter geometry (px).
const BARS = 5, BAR_W = 5, GAP = 4, MAX_H = 24, MIN_H = 5;
const METER_INTERVAL_MS = 100;

// Orb geometry and ~2.2s breathe (44 ticks of 50ms).
const ORB_SIZE = 84;
const ORB_INTERVAL_MS = 50;
const ORB_PERIOD_TICKS = 44;
// Lightning bolt outline, normalized 0..1 with y pointing down.
const BOLT = [
    [0.60, 0.00], [0.20, 0.54], [0.44, 0.54],
    [0.34, 1.00], [0.80, 0.44], [0.54, 0.44],
];

function cssColor([r, g, b], alpha) {
    const c = v => Math.round(v * 255);
    return `rgba(${c(r)}, ${c(g)}, ${c(b)}, ${alpha})`;
}

class Indicator {
    constructor() {
        this._actor = null;
        this._timerId = 0;
        this._key = null;
        this._monitorsId = Main.layoutManager.connect('monitors-changed',
            () => this._position());
        this._workareasId = global.display.connect('workareas-changed',
            () => this._position());
    }

    show(color, style) {
        const name = Object.hasOwn(COLORS, color) ? color : 'red';
        const kind = style === 'orb' ? 'orb' : 'meter';
        const key = `${name}/${kind}`;
        if (this._actor && this._key === key)
            return;
        this.hide();
        this._key = key;
        if (kind === 'orb')
            this._buildOrb(COLORS[name]);
        else
            this._buildMeter(COLORS[name]);
        this._actor.name = 'xhisper-indicator';
        // Non-reactive, so it never receives pointer input; no struts, and it stays
        // visible over fullscreen windows.
        Main.layoutManager.addTopChrome(this._actor, {
            affectsStruts: false,
            trackFullscreen: false,
        });
        this._position();
    }

    hide() {
        if (this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = 0;
        }
        if (this._actor) {
            Main.layoutManager.removeChrome(this._actor);
            this._actor.destroy();
            this._actor = null;
        }
        this._key = null;
    }

    destroy() {
        this.hide();
        Main.layoutManager.disconnect(this._monitorsId);
        global.display.disconnect(this._workareasId);
    }

    _position() {
        if (!this._actor)
            return;
        const monitor = Main.layoutManager.primaryIndex;
        if (monitor < 0)
            return;
        const area = Main.layoutManager.getWorkAreaForMonitor(monitor);
        const [w, h] = this._actor.get_size();
        this._actor.set_position(
            Math.round(area.x + (area.width - w) / 2),
            Math.round(area.y + area.height - h - PAD));
    }

    _startTimer(intervalMs, tick) {
        this._timerId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, intervalMs, () => {
            tick();
            return GLib.SOURCE_CONTINUE;
        });
        GLib.Source.set_name_by_id(this._timerId, '[xhisper-indicator] animation');
    }

    _buildMeter(rgb) {
        const width = BARS * BAR_W + (BARS - 1) * GAP;
        const box = new St.Widget({
            reactive: false,
            can_focus: false,
            width,
            height: MAX_H,
        });
        const style = `background-color: ${cssColor(rgb, 0.95)}; border-radius: 2.5px;`;
        const bars = [];
        for (let i = 0; i < BARS; i++) {
            const bar = new St.Widget({
                reactive: false,
                style,
                x: i * (BAR_W + GAP),
                y: MAX_H - MIN_H,
                width: BAR_W,
                height: MIN_H,
            });
            box.add_child(bar);
            bars.push(bar);
        }
        this._actor = box;
        this._startTimer(METER_INTERVAL_MS, () => {
            for (const bar of bars) {
                const h = Math.round(MIN_H + Math.random() * (MAX_H - MIN_H));
                bar.set_position(bar.x, MAX_H - h);
                bar.set_height(h);
            }
        });
    }

    _buildOrb(rgb) {
        const area = new St.DrawingArea({
            reactive: false,
            can_focus: false,
            width: ORB_SIZE,
            height: ORB_SIZE,
        });
        let t = 0;
        area.connect('repaint', () => {
            const cr = area.get_context();
            try {
                drawOrb(cr, rgb, 1 + 0.07 * Math.sin(t * (2 * Math.PI / ORB_PERIOD_TICKS)));
            } finally {
                cr.$dispose();
            }
        });
        this._actor = area;
        this._startTimer(ORB_INTERVAL_MS, () => {
            t = (t + 1) % ORB_PERIOD_TICKS;
            area.queue_repaint();
        });
    }
}

function drawOrb(cr, [r, g, b], s) {
    const c = ORB_SIZE / 2;
    const R = ORB_SIZE * 0.34 * s;

    cr.setOperator(Cairo.Operator.CLEAR);
    cr.paint();
    cr.setOperator(Cairo.Operator.OVER);

    // Translucent white sphere, highlight toward the top-left.
    const hx = c - R * 0.35, hy = c - R * 0.35;
    const sphere = new Cairo.RadialGradient(hx, hy, 0, hx, hy, R * 1.35);
    sphere.addColorStopRGBA(0, 1, 1, 1, 0.78);
    sphere.addColorStopRGBA(1, 0.78, 0.78, 0.78, 0.78);
    cr.arc(c, c, R, 0, 2 * Math.PI);
    cr.setSource(sphere);
    cr.fill();

    // Thin ring hugging the sphere.
    cr.arc(c, c, R + 1, 0, 2 * Math.PI);
    cr.setSourceRGBA(r, g, b, 0.80);
    cr.setLineWidth(2);
    cr.stroke();

    // Glossy specular highlight.
    cr.arc(c - R * 0.34, c - R * 0.36, R * 0.18, 0, 2 * Math.PI);
    cr.setSourceRGBA(1, 1, 1, 0.5);
    cr.fill();

    // The colored lightning bolt.
    const size = R * 1.45;
    BOLT.forEach(([x, y], i) => {
        const px = c + (x - 0.5) * size, py = c + (y - 0.5) * size;
        if (i === 0)
            cr.moveTo(px, py);
        else
            cr.lineTo(px, py);
    });
    cr.closePath();
    cr.setSourceRGBA(r, g, b, 0.82);
    cr.fill();
}

// What xhisper needs to pick a paste key per app (Ctrl+V vs Ctrl+Shift+V in
// terminals) and a clipboard tool (client "x11" for XWayland windows, where the
// Wayland clipboard tools fail, else "wayland"); on Wayland only the compositor
// knows the focused window.
function focusedWindow() {
    const win = global.display.focus_window;
    if (!win)
        return ['', '', ''];
    const wmClass = win.get_wm_class() || win.get_wm_class_instance() || '';
    const appId = Shell.WindowTracker.get_default().get_window_app(win)?.get_id() ?? '';
    const client = win.get_client_type() === Meta.WindowClientType.X11 ? 'x11' : 'wayland';
    return [wmClass, appId, client];
}

export default class XhisperIndicatorExtension extends Extension {
    enable() {
        this._indicator = new Indicator();
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE_XML, {
            Show: (color, style) => this._indicator.show(color, style),
            Hide: () => this._indicator.hide(),
            FocusedWindow: () => focusedWindow(),
        });
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
    }

    disable() {
        this._dbus?.unexport();
        this._dbus = null;
        this._indicator?.destroy();
        this._indicator = null;
    }
}
