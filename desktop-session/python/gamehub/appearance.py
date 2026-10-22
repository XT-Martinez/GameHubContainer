"""Appearance settings: wallpaper and accent colour.

The accent can follow the wallpaper (its most prominent colour), or be one
of the wallpaper's colours, a preset or a custom pick. Changes apply at
once by running gamehub-theme in the background.
"""

import math
import shutil
import sys
from pathlib import Path

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk  # noqa: E402
import cairo  # noqa: E402

from . import theme  # noqa: E402

THUMB_W, THUMB_H = 176, 99


def thumbnail(path):
    """Centre-cropped 16:9 thumbnail."""
    try:
        pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(path), THUMB_W * 2, -1, True)
    except GLib.Error:
        return None
    w, h = pixbuf.get_width(), pixbuf.get_height()
    scale = max(THUMB_W / w, THUMB_H / h)
    scaled = pixbuf.scale_simple(max(THUMB_W, round(w * scale)), max(THUMB_H, round(h * scale)),
                                 GdkPixbuf.InterpType.BILINEAR)
    x = (scaled.get_width() - THUMB_W) // 2
    y = (scaled.get_height() - THUMB_H) // 2
    return scaled.new_subpixbuf(x, y, THUMB_W, THUMB_H)


def rounded(pixbuf, radius=9):
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, THUMB_W, THUMB_H)
    cr = cairo.Context(surface)
    cr.new_sub_path()
    for cx, cy, a in ((THUMB_W - radius, radius, -90), (THUMB_W - radius, THUMB_H - radius, 0),
                      (radius, THUMB_H - radius, 90), (radius, radius, 180)):
        cr.arc(cx, cy, radius, math.radians(a), math.radians(a + 90))
    cr.close_path()
    cr.clip()
    Gdk.cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
    cr.paint()
    return surface


class Appearance(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Appearance")
        self.set_default_size(820, 620)
        self.get_style_context().add_class("appearance")
        self.state = theme.load_state()
        self.applying = False
        self.pending = None

        css = Gtk.CssProvider()
        try:
            css.load_from_path(str(theme.OUTPUTS["widgets.css"]))
        except GLib.Error:
            pass
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        self.css = css
        monitor = Gio.File.new_for_path(str(theme.OUTPUTS["widgets.css"])).monitor_file(
            Gio.FileMonitorFlags.NONE, None)
        monitor.connect("changed", self._css_changed)
        self._monitor = monitor

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.add(scroll)
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        for side in ("top", "bottom", "start", "end"):
            getattr(page, "set_margin_" + side)(28)
        scroll.add(page)

        page.pack_start(self._heading("Wallpaper"), False, False, 0)
        self.walls = Gtk.FlowBox()
        self.walls.set_selection_mode(Gtk.SelectionMode.NONE)
        self.walls.set_max_children_per_line(6)
        self.walls.set_column_spacing(6)
        self.walls.set_row_spacing(6)
        self.walls.set_homogeneous(True)
        page.pack_start(self.walls, False, False, 0)
        add = Gtk.Button(label="Add Wallpaper…")
        add.set_halign(Gtk.Align.START)
        add.connect("clicked", self._add_wallpaper)
        page.pack_start(add, False, False, 4)

        page.pack_start(self._heading("Accent colour", top=22), False, False, 0)
        auto_row = Gtk.Box(spacing=12)
        auto_label = Gtk.Label(label="Match the wallpaper", xalign=0)
        self.auto = Gtk.Switch()
        self.auto.set_active(self.state.get("auto_accent", False))
        self.auto.connect("notify::active", self._auto_toggled)
        auto_row.pack_start(auto_label, False, False, 0)
        auto_row.pack_end(self.auto, False, False, 0)
        page.pack_start(auto_row, False, False, 6)

        page.pack_start(self._caption("From the wallpaper"), False, False, 0)
        self.wall_swatches = Gtk.Box(spacing=8)
        page.pack_start(self.wall_swatches, False, False, 0)

        page.pack_start(self._caption("Presets", top=10), False, False, 0)
        presets = Gtk.Box(spacing=8)
        self.swatch_buttons = []
        for name, colour in theme.PRESETS:
            presets.pack_start(self._swatch(colour, name), False, False, 0)
        self.custom = Gtk.ColorButton()
        self.custom.set_title("Custom accent colour")
        self.custom.set_tooltip_text("Custom colour")
        self.custom.connect("color-set", self._custom_set)
        presets.pack_start(self.custom, False, False, 6)
        page.pack_start(presets, False, False, 0)

        self._fill_wallpapers()
        self._fill_wall_swatches()
        self._mark_selection()

    # Building

    def _heading(self, text, top=0):
        label = Gtk.Label(label=text, xalign=0)
        label.get_style_context().add_class("heading")
        label.set_margin_top(top)
        return label

    def _caption(self, text, top=0):
        label = Gtk.Label(label=text, xalign=0)
        label.get_style_context().add_class("caption")
        label.set_margin_top(top)
        return label

    def _swatch(self, colour, tooltip):
        button = Gtk.Button()
        button.get_style_context().add_class("swatch")
        button.set_tooltip_text(tooltip)
        button.set_valign(Gtk.Align.CENTER)
        provider = Gtk.CssProvider()
        provider.load_from_data(("button.swatch { background: %s; }" % colour).encode())
        button.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1)
        button.colour = colour
        button.connect("clicked", lambda _b: self.set_accent(colour))
        self.swatch_buttons.append(button)
        return button

    def _fill_wallpapers(self):
        for child in self.walls.get_children():
            child.destroy()
        self.wall_buttons = []
        for path in theme.wallpapers():
            pixbuf = thumbnail(path)
            if pixbuf is None:
                continue
            button = Gtk.Button()
            button.get_style_context().add_class("wallpaper")
            button.set_tooltip_text(path.stem.replace("-", " ").replace("_", " ").title())
            button.add(Gtk.Image.new_from_surface(rounded(pixbuf)))
            button.path = str(path)
            button.connect("clicked", lambda b: self.set_wallpaper(b.path))
            self.walls.add(button)
            self.wall_buttons.append(button)
        self.walls.show_all()

    def _fill_wall_swatches(self):
        for child in self.wall_swatches.get_children():
            self.swatch_buttons.remove(child)
            child.destroy()
        self.suggested = theme.wallpaper_swatches(self.state["wallpaper"])
        for colour in self.suggested:
            self.wall_swatches.pack_start(self._swatch(colour, colour), False, False, 0)
        self.wall_swatches.show_all()

    def _mark_selection(self):
        for button in self.wall_buttons:
            ctx = button.get_style_context()
            (ctx.add_class if button.path == self.state["wallpaper"] else ctx.remove_class)("selected")
        accent = self.state["accent"]
        for button in self.swatch_buttons:
            ctx = button.get_style_context()
            (ctx.add_class if button.colour == accent else ctx.remove_class)("selected")
        rgba = Gdk.RGBA()
        rgba.parse(accent)
        self.custom.set_rgba(rgba)

    # Changes

    def set_wallpaper(self, path):
        if path == self.state["wallpaper"]:
            return
        self.state["wallpaper"] = path
        self._fill_wall_swatches()
        if self.state.get("auto_accent") and self.suggested:
            self.state["accent"] = self.suggested[0]
        self._commit(wallpaper=True)

    def set_accent(self, colour, auto=False):
        self.state["accent"] = colour
        self.state["auto_accent"] = auto
        if self.auto.get_active() != auto:
            self.auto.handler_block_by_func(self._auto_toggled)
            self.auto.set_active(auto)
            self.auto.handler_unblock_by_func(self._auto_toggled)
        self._commit()

    def _auto_toggled(self, switch, _param):
        self.state["auto_accent"] = switch.get_active()
        if switch.get_active() and self.suggested:
            self.state["accent"] = self.suggested[0]
        self._commit()

    def _custom_set(self, button):
        rgba = button.get_rgba()
        self.set_accent(theme.rgb_to_hex((rgba.red, rgba.green, rgba.blue)))

    def _add_wallpaper(self, _button):
        dialog = Gtk.FileChooserNative.new("Add Wallpaper", self, Gtk.FileChooserAction.OPEN,
                                           "_Add", "_Cancel")
        images = Gtk.FileFilter()
        images.set_name("Images")
        for pattern in ("*.png", "*.jpg", "*.jpeg", "*.webp", "*.svg"):
            images.add_pattern(pattern)
            images.add_pattern(pattern.upper())
        dialog.add_filter(images)
        if dialog.run() == Gtk.ResponseType.ACCEPT:
            source = Path(dialog.get_filename())
            theme.USER_WALLPAPERS.mkdir(parents=True, exist_ok=True)
            target = theme.USER_WALLPAPERS / source.name
            if source.resolve() != target.resolve():
                shutil.copy2(source, target)
            self._fill_wallpapers()
            self.set_wallpaper(str(target))
        dialog.destroy()

    def _commit(self, wallpaper=False):
        self._mark_selection()
        theme.save_state(self.state)
        # Coalesce quick clicks: one gamehub-theme run at a time
        self.pending = (self.pending or False) or wallpaper
        if not self.applying:
            self._run_pending()

    def _run_pending(self):
        if self.pending is None:
            self.applying = False
            return
        wallpaper, self.pending = self.pending, None
        self.applying = True
        argv = ["/usr/local/bin/gamehub-theme", "set"]
        if wallpaper:
            argv += ["--wallpaper", self.state["wallpaper"]]
        proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE)
        proc.wait_async(None, lambda p, res: (p.wait_finish(res), self._run_pending()))

    def _css_changed(self, _monitor, _file, _other, event):
        if event in (Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.CREATED):
            try:
                self.css.load_from_path(str(theme.OUTPUTS["widgets.css"]))
            except GLib.Error:
                pass


def main():
    GLib.set_prgname("gamehub-appearance")
    app = Gtk.Application(application_id="io.gamehub.Appearance")

    def activate(application):
        window = application.get_active_window()
        if window is None:
            window = Appearance(application)
            window.show_all()
        window.present()

    app.connect("activate", activate)
    return app.run(sys.argv[:1])


if __name__ == "__main__":
    sys.exit(main())
