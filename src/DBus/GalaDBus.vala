/*
 * SPDX-License-Identifier: GPL-3.0
 * SPDX-FileCopyrightText: 2025 elementary, Inc. (https://elementary.io)
 */

[DBus (name = "org.pantheon.gala")]
public interface Dock.GalaDBus : Object {
    public const int ACTION_SHOW_WORKSPACE_VIEW = 1;
    public const int ACTION_MINIMIZE_CURRENT = 3;

    public abstract async void perform_action (int action) throws DBusError, IOError;

    private static GalaDBus? proxy;
    public static async void init () {
        try {
            proxy = yield Bus.get_proxy (SESSION, "org.pantheon.gala", "/org/pantheon/gala");
        } catch (Error e) {
            warning ("Failed to get Gala DBus proxy: %s", e.message);
        }
    }

    public static void open_multitaksing_view () requires (proxy != null) {
        proxy.perform_action.begin (ACTION_SHOW_WORKSPACE_VIEW);
    }

    public static bool minimize_current_window () {
        if (proxy == null) {
            return false;
        }

        proxy.perform_action.begin (ACTION_MINIMIZE_CURRENT);
        return true;
    }
}
