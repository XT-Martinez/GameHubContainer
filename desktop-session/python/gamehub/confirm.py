"""A themed yes/no prompt over the whole desktop.

Exits 0 when the user accepts and 10 when they cancel (button, Escape or a
click outside the card), so callers can tell a cancel from a crash.
"""

import argparse
import sys

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, GLib, Gtk, GtkLayerShell  # noqa: E402

from . import theme  # noqa: E402

CANCELLED = 10


def main(argv=None):
    parser = argparse.ArgumentParser(prog="gamehub-confirm")
    parser.add_argument("--title", required=True)
    parser.add_argument("--body", default="")
    parser.add_argument("--icon", default="dialog-question")
    parser.add_argument("--accept", default="OK")
    parser.add_argument("--cancel", default="Cancel")
    args = parser.parse_args(argv)

    GLib.set_prgname("gamehub-confirm")
    result = {"code": CANCELLED}

    def finish(code):
        result["code"] = code
        Gtk.main_quit()

    css = Gtk.CssProvider()
    try:
        css.load_from_path(str(theme.OUTPUTS["widgets.css"]))
    except GLib.Error:
        pass
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_USER)

    window = Gtk.Window()
    window.get_style_context().add_class("gamehub-confirm")
    GtkLayerShell.init_for_window(window)
    GtkLayerShell.set_namespace(window, "gamehub-confirm")
    GtkLayerShell.set_layer(window, GtkLayerShell.Layer.OVERLAY)
    for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                 GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
        GtkLayerShell.set_anchor(window, edge, True)
    GtkLayerShell.set_exclusive_zone(window, -1)
    GtkLayerShell.set_keyboard_mode(window, GtkLayerShell.KeyboardMode.EXCLUSIVE)
    visual = window.get_screen().get_rgba_visual()
    if visual is not None:
        window.set_visual(visual)

    # Clicks on the dimmed backdrop cancel; the card swallows its own clicks
    backdrop = Gtk.EventBox()
    backdrop.set_visible_window(False)
    backdrop.connect("button-release-event", lambda *_: finish(CANCELLED))
    window.add(backdrop)

    card_events = Gtk.EventBox()
    card_events.set_visible_window(False)
    card_events.set_halign(Gtk.Align.CENTER)
    card_events.set_valign(Gtk.Align.CENTER)
    card_events.connect("button-release-event", lambda *_: True)
    backdrop.add(card_events)

    card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
    card.get_style_context().add_class("confirm-card")
    card.set_size_request(400, -1)
    card_events.add(card)

    icon = Gtk.Image.new_from_icon_name(args.icon, Gtk.IconSize.INVALID)
    icon.set_pixel_size(52)
    icon.set_margin_bottom(4)
    card.pack_start(icon, False, False, 0)

    title = Gtk.Label(label=args.title)
    title.get_style_context().add_class("title")
    card.pack_start(title, False, False, 0)

    if args.body:
        body = Gtk.Label(label=args.body)
        body.get_style_context().add_class("body")
        body.set_line_wrap(True)
        body.set_max_width_chars(44)
        body.set_justify(Gtk.Justification.CENTER)
        card.pack_start(body, False, False, 0)

    buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
    buttons.set_homogeneous(True)
    buttons.set_margin_top(14)
    cancel = Gtk.Button(label=args.cancel)
    cancel.connect("clicked", lambda _b: finish(CANCELLED))
    accept = Gtk.Button(label=args.accept)
    accept.get_style_context().add_class("accept")
    accept.connect("clicked", lambda _b: finish(0))
    buttons.pack_start(cancel, True, True, 0)
    buttons.pack_start(accept, True, True, 0)
    card.pack_start(buttons, False, False, 0)

    def key(_w, event):
        if event.keyval == Gdk.KEY_Escape:
            finish(CANCELLED)
            return True
        return False

    window.connect("key-press-event", key)
    window.connect("destroy", lambda _w: Gtk.main_quit())
    window.show_all()
    accept.grab_focus()
    Gtk.main()
    return result["code"]


if __name__ == "__main__":
    sys.exit(main())
