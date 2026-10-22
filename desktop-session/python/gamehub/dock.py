"""A GNOME-style dock for the labwc desktop.

Pinned apps and running windows share one icon per app. Dots under an icon
count its open windows and take the icon's dominant colour; the app with
the focused window gets a tint of that colour behind its icon. Windows come
from the compositor through wlr-foreign-toplevel-management on a second
Wayland connection next to GTK's own.
"""

import copy
import json
import math
import shlex
import struct
import subprocess
import sys
import time

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, Gio, GLib, Gtk, GtkLayerShell  # noqa: E402

from pywayland.client import Display  # noqa: E402

from gamehub_protocols.wayland import WlSeat  # noqa: E402
from gamehub_protocols.wlr_foreign_toplevel_management_unstable_v1 import (  # noqa: E402
    ZwlrForeignToplevelManagerV1,
)

from . import theme  # noqa: E402

ICON_SIZE = 40
MAX_DOTS = 4
LAUNCH_FEEDBACK_S = 6

DEFAULT_PINNED = theme.SHARE / "dock/pinned.json"
USER_PINNED = theme.OUT / "dock.json"
APP_GRID_COMMAND = "/usr/local/bin/desktop-launcher.sh"

# zwlr_foreign_toplevel_handle_v1.state
STATE_MINIMIZED = 1
STATE_ACTIVATED = 2


class Window:
    def __init__(self, handle, serial):
        self.handle = handle
        self.serial = serial
        self.title = ""
        self.app_id = ""
        self.minimized = False
        self.activated = False
        self.ready = False
        self.last_focus = 0.0


def accept_new_objects(display):
    """Let events carry objects the compositor creates.

    pywayland 0.4 raises NotImplementedError for new_id event arguments,
    and zwlr_foreign_toplevel_manager_v1.toplevel is one. libwayland has
    already made the proxy; wrap it like a bound global.
    """
    from pywayland.protocol_core.message import Message
    from pywayland.scanner.argument import ArgumentType

    original = Message.c_to_arguments

    def c_to_arguments(self, args_ptr):
        if all(a.argument_type != ArgumentType.NewId for a in self.arguments):
            return original(self, args_ptr)
        args = []
        for i, argument in enumerate(self.arguments):
            if argument.argument_type == ArgumentType.NewId:
                args.append(argument.interface.proxy_class(args_ptr[i].o, display))
            else:
                single = copy.copy(self)
                object.__setattr__(single, "arguments", [argument])
                args += original(single, args_ptr + i)
        return args

    Message.c_to_arguments = c_to_arguments


class Toplevels:
    """Tracks the compositor's windows and forwards requests about them."""

    def __init__(self, on_change):
        self.on_change = on_change
        self.windows = []
        self.seat = None
        self.manager = None
        self._serial = 0

        self.display = Display()
        self.display.connect()
        accept_new_objects(self.display)
        registry = self.display.get_registry()
        registry.dispatcher["global"] = self._global
        self.display.roundtrip()
        if self.manager is None:
            raise RuntimeError("the compositor does not offer zwlr_foreign_toplevel_manager_v1")
        self.manager.dispatcher["toplevel"] = self._toplevel
        self.display.roundtrip()
        GLib.io_add_watch(self.display.get_fd(), GLib.PRIORITY_DEFAULT,
                          GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self._readable)

    def _global(self, registry, name, interface, version):
        if interface == ZwlrForeignToplevelManagerV1.name:
            self.manager = registry.bind(name, ZwlrForeignToplevelManagerV1, min(version, 3))
        elif interface == WlSeat.name and self.seat is None:
            self.seat = registry.bind(name, WlSeat, 1)

    def _toplevel(self, manager, handle):
        self._serial += 1
        win = Window(handle, self._serial)
        self.windows.append(win)
        handle.dispatcher["title"] = lambda _h, title: setattr(win, "title", title)
        handle.dispatcher["app_id"] = lambda _h, app_id: setattr(win, "app_id", app_id)
        handle.dispatcher["state"] = lambda _h, states: self._state(win, states)
        handle.dispatcher["done"] = lambda _h: self._done(win)
        handle.dispatcher["closed"] = lambda _h: self._closed(win)

    def _state(self, win, states):
        if isinstance(states, (bytes, bytearray)):
            states = struct.unpack("=%dI" % (len(states) // 4), states)
        states = set(states)
        win.minimized = STATE_MINIMIZED in states
        activated = STATE_ACTIVATED in states
        if activated and not win.activated:
            win.last_focus = time.monotonic()
        win.activated = activated

    def _done(self, win):
        win.ready = True
        self.on_change()

    def _closed(self, win):
        if win in self.windows:
            self.windows.remove(win)
        win.handle.destroy()
        self.on_change()

    def _readable(self, _fd, condition):
        if condition & (GLib.IO_HUP | GLib.IO_ERR):
            Gtk.main_quit()
            return False
        self.display.dispatch(block=True)
        return True

    def _flush(self):
        self.display.flush()

    def activate(self, win):
        if win.minimized:
            win.handle.unset_minimized()
        win.handle.activate(self.seat)
        self._flush()

    def minimize(self, win):
        win.handle.set_minimized()
        self._flush()

    def close(self, win):
        win.handle.close()
        self._flush()


class App:
    def __init__(self, key, name, gicon, info=None, command=None, pinned=False):
        self.key = key
        self.name = name
        self.gicon = gicon
        self.info = info
        self.command = command
        self.pinned = pinned
        self.windows = []
        self.launched_at = 0.0

    @property
    def focused(self):
        return any(w.activated for w in self.windows)

    @property
    def launching(self):
        return not self.windows and time.monotonic() - self.launched_at < LAUNCH_FEEDBACK_S

    def launch(self):
        self.launched_at = time.monotonic()
        if self.command:
            subprocess.Popen(shlex.split(self.command), stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        elif self.info is not None:
            ctx = Gdk.Display.get_default().get_app_launch_context()
            self.info.launch([], ctx)


class AppIndex:
    """Maps Wayland app_ids and X11 classes to desktop entries."""

    def __init__(self):
        self.by_key = {}
        for info in Gio.AppInfo.get_all():
            if not isinstance(info, Gio.DesktopAppInfo):
                continue
            desktop_id = info.get_id() or ""
            stem = desktop_id[:-8] if desktop_id.endswith(".desktop") else desktop_id
            keys = [stem, stem.split(".")[-1], info.get_startup_wm_class() or ""]
            executable = info.get_executable() or ""
            keys.append(executable.rsplit("/", 1)[-1])
            for key in keys:
                key = key.lower()
                if key and (key not in self.by_key or not info.get_nodisplay()):
                    self.by_key.setdefault(key, info)

    def find(self, app_id):
        app_id = (app_id or "").lower()
        for key in (app_id, app_id.split(".")[-1]):
            if key in self.by_key:
                return self.by_key[key]
        return None


def load_pinned():
    for path in (USER_PINNED, DEFAULT_PINNED):
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            continue
    return []


def save_pinned(entries):
    USER_PINNED.parent.mkdir(parents=True, exist_ok=True)
    USER_PINNED.write_text(json.dumps(entries, indent=2) + "\n")


class AppButton(Gtk.Button):
    def __init__(self, dock, app):
        super().__init__()
        self.dock = dock
        self.app = app
        self.colour = None
        self.get_style_context().add_class("app")
        self.set_relief(Gtk.ReliefStyle.NONE)
        self.set_can_focus(False)
        self.set_tooltip_text(app.name)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.image = Gtk.Image()
        box.pack_start(self.image, False, False, 0)
        self.dots = Gtk.DrawingArea()
        self.dots.set_size_request(ICON_SIZE, 5)
        self.dots.connect("draw", self._draw_dots)
        box.pack_start(self.dots, False, False, 0)
        self.add(box)

        self.css = Gtk.CssProvider()
        self.get_style_context().add_provider(self.css, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
        self.connect("clicked", lambda _b: dock.on_click(self.app))
        self.connect("button-press-event", self._press)
        self.load_icon()

    def load_icon(self):
        icon_theme = Gtk.IconTheme.get_default()
        scale = self.get_scale_factor()
        pixbuf = None
        if self.app.gicon is not None:
            info = icon_theme.lookup_by_gicon_for_scale(
                self.app.gicon, ICON_SIZE, scale, Gtk.IconLookupFlags.FORCE_SIZE)
            if info is not None:
                try:
                    pixbuf = info.load_icon()
                except GLib.Error:
                    pixbuf = None
        if pixbuf is None:
            pixbuf = icon_theme.load_icon_for_scale(
                "application-x-executable", ICON_SIZE, scale, Gtk.IconLookupFlags.FORCE_SIZE)
        surface = Gdk.cairo_surface_create_from_pixbuf(pixbuf, scale, None)
        self.image.set_from_surface(surface)
        self.colour = theme.dominant_colour(pixbuf, self.dock.accent)
        self.update()

    def update(self):
        r, g, b = (round(c * 255) for c in self.colour)
        focused = self.app.focused
        css = "button.app:hover { background-color: rgba(%d, %d, %d, 0.13); }\n" % (r, g, b)
        if focused:
            css += ("button.app { background-color: rgba(%d, %d, %d, 0.2);"
                    " box-shadow: inset 0 0 0 1px rgba(%d, %d, %d, 0.32); }\n"
                    "button.app:hover { background-color: rgba(%d, %d, %d, 0.26); }\n"
                    % (r, g, b, r, g, b, r, g, b))
        self.css.load_from_data(css.encode())
        if self.app.windows:
            titles = [w.title or self.app.name for w in self.app.windows]
            self.set_tooltip_text(self.app.name if len(titles) == 1 and titles[0] == self.app.name
                                  else self.app.name + "\n" + "\n".join("• " + t for t in titles))
        else:
            self.set_tooltip_text(self.app.name)
        self.dots.queue_draw()

    def _draw_dots(self, area, cr):
        count = min(len(self.app.windows), MAX_DOTS)
        alpha = 1.0 if self.app.focused else 0.8
        if not count:
            if not self.app.launching:
                return False
            count, alpha = 1, 0.35 + 0.3 * abs(math.sin(time.monotonic() * 3))
        width = area.get_allocated_width()
        height = area.get_allocated_height()
        d, gap = 5, 3
        if self.app.focused and count == 1:
            # A short bar marks the focused app's only window
            bar = 14
            x = (width - bar) / 2
            cr.set_source_rgba(*self.colour, alpha)
            cr.arc(x + d / 2, height / 2, d / 2, math.pi / 2, 3 * math.pi / 2)
            cr.arc(x + bar - d / 2, height / 2, d / 2, 3 * math.pi / 2, math.pi / 2)
            cr.close_path()
            cr.fill()
            return False
        total = count * d + (count - 1) * gap
        x = (width - total) / 2 + d / 2
        cr.set_source_rgba(*self.colour, alpha)
        for i in range(count):
            cr.arc(x + i * (d + gap), height / 2, d / 2, 0, 2 * math.pi)
            cr.fill()
        return False

    def _press(self, _widget, event):
        if event.type != Gdk.EventType.BUTTON_PRESS:
            return False
        if event.button == 2:
            self.dock.launch(self.app)
            return True
        if event.button == 3:
            self.dock.show_menu(self, event)
            return True
        return False


class Dock:
    def __init__(self):
        self.accent = theme.load_state()["accent"]
        self.index = AppIndex()
        self.pinned = load_pinned()
        self.apps = {}
        self.buttons = {}
        self._refresh_queued = False

        self.window = Gtk.Window()
        self.window.get_style_context().add_class("gamehub-dock")
        self.window.set_title("GameHub Dock")
        GtkLayerShell.init_for_window(self.window)
        GtkLayerShell.set_namespace(self.window, "gamehub-dock")
        GtkLayerShell.set_layer(self.window, GtkLayerShell.Layer.TOP)
        GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.BOTTOM, True)
        GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.BOTTOM, 8)
        GtkLayerShell.auto_exclusive_zone_enable(self.window)
        visual = self.window.get_screen().get_rgba_visual()
        if visual is not None:
            self.window.set_visual(visual)
        self.window.set_app_paintable(True)

        self.box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        self.box.get_style_context().add_class("dock")
        self.window.add(self.box)

        self.separator = Gtk.Box()
        self.separator.get_style_context().add_class("separator")
        self.grid_button = self._grid_button()

        self.css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), self.css, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        self._load_css()
        self._monitors = []
        for path, callback in ((theme.OUTPUTS["widgets.css"], self._theme_changed),
                               (USER_PINNED, self._pinned_changed)):
            monitor = Gio.File.new_for_path(str(path)).monitor_file(Gio.FileMonitorFlags.NONE, None)
            monitor.connect("changed", callback)
            self._monitors.append(monitor)
        Gtk.IconTheme.get_default().connect("changed", lambda _t: self._reload_icons())

        self.toplevels = Toplevels(self.queue_refresh)
        self.refresh()
        self.window.show_all()

    # Building

    def _grid_button(self):
        button = Gtk.Button()
        button.get_style_context().add_class("app")
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_can_focus(False)
        button.set_tooltip_text("Show Applications")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        image = Gtk.Image.new_from_icon_name("view-app-grid-symbolic", Gtk.IconSize.INVALID)
        image.set_pixel_size(ICON_SIZE - 12)
        image.set_size_request(ICON_SIZE, ICON_SIZE)
        box.pack_start(image, False, False, 0)
        spacer = Gtk.Box()
        spacer.set_size_request(ICON_SIZE, 5)
        box.pack_start(spacer, False, False, 0)
        button.add(box)
        button.connect("clicked", lambda _b: subprocess.Popen(
            [APP_GRID_COMMAND], start_new_session=True))
        return button

    def _app_for_entry(self, entry):
        desktop_id = entry.get("desktop", "")
        try:
            info = Gio.DesktopAppInfo.new(desktop_id) if desktop_id else None
        except TypeError:
            info = None
        name = entry.get("name") or (info.get_display_name() if info else desktop_id)
        icon = entry.get("icon")
        gicon = Gio.ThemedIcon.new(icon) if icon else (info.get_icon() if info else None)
        return App("pin:" + desktop_id, name, gicon, info=info,
                   command=entry.get("command"), pinned=True)

    def _app_for_window(self, win):
        info = self.index.find(win.app_id)
        if info is not None:
            key = "app:" + info.get_id()
            if key not in self.apps:
                self.apps[key] = App(key, info.get_display_name(), info.get_icon(), info=info)
            return self.apps[key]
        key = "window:" + (win.app_id or "unknown")
        if key not in self.apps:
            name = win.app_id or win.title or "Window"
            gicon = Gio.ThemedIcon.new_from_names(
                [win.app_id.lower(), "application-x-executable"]) if win.app_id else None
            self.apps[key] = App(key, name, gicon)
        return self.apps[key]

    def queue_refresh(self):
        if not self._refresh_queued:
            self._refresh_queued = True
            GLib.idle_add(self.refresh)

    def refresh(self):
        self._refresh_queued = False
        pinned_apps = []
        match = {}
        for entry in self.pinned:
            key = "pin:" + entry.get("desktop", "")
            app = self.apps.get(key) or self._app_for_entry(entry)
            self.apps[key] = app
            pinned_apps.append(app)
            for name in entry.get("match", []):
                match[name.lower()] = app
            if app.info is not None:
                desktop_id = app.info.get_id() or ""
                match.setdefault(desktop_id[:-8].lower(), app)
                wm_class = app.info.get_startup_wm_class()
                if wm_class:
                    match.setdefault(wm_class.lower(), app)

        for app in self.apps.values():
            app.windows = []
        running = []
        for win in sorted(self.toplevels.windows, key=lambda w: w.serial):
            if not win.ready:
                continue
            app_id = win.app_id.lower()
            app = match.get(app_id) or match.get(app_id.split(".")[-1])
            if app is None:
                found = self.index.find(win.app_id)
                if found is not None:
                    app = match.get(found.get_id()[:-8].lower())
            if app is None:
                app = self._app_for_window(win)
                if app not in running:
                    running.append(app)
            app.windows.append(win)

        order = pinned_apps + running
        for key in [k for k, a in self.apps.items() if a not in order]:
            del self.apps[key]
            button = self.buttons.pop(key, None)
            if button is not None:
                button.destroy()

        children = []
        for app in order:
            button = self.buttons.get(app.key)
            if button is None:
                button = AppButton(self, app)
                self.buttons[app.key] = button
            button.update()
            children.append(button)
        children += [self.separator, self.grid_button]

        current = self.box.get_children()
        if current != children:
            for child in current:
                self.box.remove(child)
            for child in children:
                self.box.pack_start(child, False, False, 0)
            self.box.show_all()
        return False

    # Actions

    def launch(self, app):
        app.launch()
        button = self.buttons.get(app.key)
        if button is not None:
            GLib.timeout_add(80, self._pulse, button, app)

    def _pulse(self, button, app):
        button.dots.queue_draw()
        return app.launching

    def on_click(self, app):
        wins = app.windows
        if not wins:
            self.launch(app)
            return
        focused = [w for w in wins if w.activated]
        if not focused:
            target = max(wins, key=lambda w: (w.last_focus, w.serial))
            self.toplevels.activate(target)
        elif len(wins) == 1:
            self.toplevels.minimize(wins[0])
        else:
            following = wins[(wins.index(focused[0]) + 1) % len(wins)]
            self.toplevels.activate(following)

    def show_menu(self, button, event):
        app = button.app
        menu = Gtk.Menu()
        menu.get_style_context().add_class("dock-menu")

        def item(label, callback):
            entry = Gtk.MenuItem(label=label)
            entry.connect("activate", lambda _i: callback())
            menu.append(entry)

        if len(app.windows) > 1:
            for win in app.windows:
                title = win.title or app.name
                if len(title) > 48:
                    title = title[:47] + "…"
                item(title, lambda w=win: self.toplevels.activate(w))
            menu.append(Gtk.SeparatorMenuItem())
        if app.info is not None or app.command:
            item("New Window" if app.windows else "Open", lambda: self.launch(app))
        if app.info is not None:
            if app.pinned:
                item("Remove from Dock", lambda: self.unpin(app))
            else:
                item("Pin to Dock", lambda: self.pin(app))
        if app.windows:
            menu.append(Gtk.SeparatorMenuItem())
            count = len(app.windows)
            item("Close" if count == 1 else f"Close {count} Windows",
                 lambda: [self.toplevels.close(w) for w in list(app.windows)])
        menu.show_all()
        menu.attach_to_widget(button, None)
        menu.popup_at_widget(button, Gdk.Gravity.NORTH, Gdk.Gravity.SOUTH, event)

    def pin(self, app):
        entry = {"desktop": app.info.get_id()}
        self.pinned.append(entry)
        save_pinned(self.pinned)
        self.queue_refresh()

    def unpin(self, app):
        desktop_id = app.key[len("pin:"):]
        self.pinned = [e for e in self.pinned if e.get("desktop") != desktop_id]
        save_pinned(self.pinned)
        self.queue_refresh()

    # Theme changes

    def _load_css(self):
        try:
            self.css.load_from_path(str(theme.OUTPUTS["widgets.css"]))
        except GLib.Error as err:
            print("gamehub-dock: " + err.message, file=sys.stderr)

    def _theme_changed(self, _monitor, _file, _other, event):
        if event in (Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.CREATED):
            self._load_css()
            self.accent = theme.load_state()["accent"]
            # The accent also recoloured the GameHub icon theme's folders
            if not Gtk.IconTheme.get_default().rescan_if_needed():
                self._reload_icons()

    def _pinned_changed(self, _monitor, _file, _other, event):
        if event in (Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.CREATED,
                     Gio.FileMonitorEvent.DELETED):
            pinned = load_pinned()
            if pinned != self.pinned:
                self.pinned = pinned
                self.queue_refresh()

    def _reload_icons(self):
        for button in self.buttons.values():
            button.load_icon()


def main():
    GLib.set_prgname("gamehub-dock")
    Dock()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
