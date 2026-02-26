/*
 * SPDX-License-Identifier: GPL-3.0
 * SPDX-FileCopyrightText: 2025 elementary, Inc. (https://elementary.io)
 */

public abstract class Dock.ContainerItem : BaseItem {
    class construct {
        set_css_name ("icongroup");
    }

    public Gtk.Widget child { get { return container.child; } set { container.child = value; } }

    private Granite.Bin container;

    protected virtual int get_width_for_icon_size (int icon_size) {
        return icon_size;
    }

    construct {
        container = new Granite.Bin ();
        container.add_css_class ("icon-group-bin");
        bind_property ("icon-size", container, "width-request", SYNC_CREATE, (binding, from_value, ref to_value) => {
            to_value.set_int (get_width_for_icon_size (from_value.get_int ()));
            return true;
        });
        bind_property ("icon-size", container, "height-request", SYNC_CREATE);

        overlay.child = container;

        notify["state"].connect (() => {
            if ((state != HIDDEN) && !moving) {
                add_css_class ("running");
            } else if (has_css_class ("running")) {
                remove_css_class ("running");
            }
        });
    }
}
