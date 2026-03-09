/*
 * SPDX-License-Identifier: GPL-3.0
 * SPDX-FileCopyrightText: 2026 elementary, Inc. (https://elementary.io)
 */

[DBus (name = "org.freedesktop.DBus")]
private interface FreedesktopDBus : Object {
    [DBus (name = "NameOwnerChanged")]
    public abstract signal void name_owner_changed (string name, string old_owner, string new_owner);

    [DBus (name = "ListNames")]
    public abstract async string[] list_names () throws GLib.Error;
}

[DBus (name = "org.freedesktop.DBus.Properties")]
private interface FreedesktopProperties : Object {
    [DBus (name = "PropertiesChanged")]
    public abstract signal void properties_changed (
        string iface,
        GLib.HashTable<string, GLib.Variant> changed_properties,
        string[] invalidated_properties
    );

    [DBus (name = "GetAll")]
    public abstract async GLib.HashTable<string, GLib.Variant> get_all (string iface) throws GLib.Error;

    [DBus (name = "Get")]
    public abstract async GLib.Variant get (string iface, string property) throws GLib.Error;
}

[DBus (name = "org.mpris.MediaPlayer2.Player")]
private interface MprisPlayer : Object {
    [DBus (name = "PlayPause")]
    public abstract async void play_pause () throws GLib.Error;

    [DBus (name = "Next")]
    public abstract async void next () throws GLib.Error;

    [DBus (name = "Previous")]
    public abstract async void previous () throws GLib.Error;

    [DBus (name = "Seek")]
    public abstract async void seek (int64 offset) throws GLib.Error;
}

[DBus (name = "org.mpris.MediaPlayer2")]
private interface MprisRoot : Object {
    [DBus (name = "Raise")]
    public abstract async void raise () throws GLib.Error;
}

public class Dock.MediaMonitor : Object {
    private class PlayerState : Object {
        public string bus_name { get; construct; }
        public FreedesktopProperties properties { get; construct; }
        public MprisPlayer player { get; construct; }
        public MprisRoot root { get; construct; }

        public string playback_status { get; set; default = "Stopped"; }
        public string? title { get; set; default = null; }
        public string? artist { get; set; default = null; }
        public string? art_url { get; set; default = null; }
        public string? track_id { get; set; default = null; }
        public string? desktop_entry { get; set; default = null; }
        public bool can_raise { get; set; default = false; }
        public bool can_play { get; set; default = false; }
        public bool can_pause { get; set; default = false; }
        public bool can_go_next { get; set; default = false; }
        public bool can_go_previous { get; set; default = false; }
        public bool can_seek { get; set; default = false; }
        public int64 position_us { get; set; default = 0; }
        public int64 length_us { get; set; default = 0; }
        public bool has_position { get; set; default = false; }
        public bool position_refresh_in_flight { get; set; default = false; }

        public PlayerState (string bus_name, FreedesktopProperties properties, MprisPlayer player, MprisRoot root) {
            Object (bus_name: bus_name, properties: properties, player: player, root: root);
        }
    }

    private const string MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
    private const string MPRIS_PATH = "/org/mpris/MediaPlayer2";
    private const string MPRIS_ROOT_IFACE = "org.mpris.MediaPlayer2";
    private const string MPRIS_PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";

    public signal void changed ();

    public bool has_player {
        get {
            return active_player != null;
        }
    }

    public string? title { get; private set; default = null; }
    public string? artist { get; private set; default = null; }
    public string? art_url { get; private set; default = null; }
    public bool is_playing { get; private set; default = false; }
    public bool can_play_pause { get; private set; default = false; }
    public bool can_go_next { get; private set; default = false; }
    public bool can_go_previous { get; private set; default = false; }
    public bool can_seek { get; private set; default = false; }
    public int64 position_us { get; private set; default = 0; }
    public int64 length_us { get; private set; default = 0; }

    private FreedesktopDBus? bus_proxy;
    private GLib.HashTable<string, PlayerState> players;
    private string? active_player;
    private uint position_tick_id = 0;
    private int64 position_tick_last_us = 0;

    construct {
        players = new GLib.HashTable<string, PlayerState> (str_hash, str_equal);
    }

    public void load () {
        connect_to_dbus.begin ();
    }

    public void play_pause () {
        if (active_player == null || !(active_player in players)) {
            return;
        }

        unowned var player = players[active_player].player;
        player.play_pause.begin ((obj, res) => {
            try {
                player.play_pause.end (res);
            } catch (Error e) {
                warning ("Failed to toggle playback: %s", e.message);
            }
        });
    }

    public void next () {
        if (active_player == null || !(active_player in players)) {
            return;
        }

        var bus_name = active_player;
        unowned var player = players[bus_name].player;
        player.next.begin ((obj, res) => {
            try {
                player.next.end (res);
                if (bus_name != null && bus_name in players) {
                    unowned var state = players[bus_name];
                    state.position_us = 0;
                    state.has_position = true;
                    publish_player (state);
                }
            } catch (Error e) {
                warning ("Failed to skip to next track: %s", e.message);
            }
        });
    }

    public void previous () {
        if (active_player == null || !(active_player in players)) {
            return;
        }

        var bus_name = active_player;
        unowned var player = players[bus_name].player;
        player.previous.begin ((obj, res) => {
            try {
                player.previous.end (res);
                if (bus_name != null && bus_name in players) {
                    unowned var state = players[bus_name];
                    state.position_us = 0;
                    state.has_position = true;
                    publish_player (state);
                }
            } catch (Error e) {
                warning ("Failed to go to previous track: %s", e.message);
            }
        });
    }

    public void seek_to (int64 target_position_us) {
        if (active_player == null || !(active_player in players)) {
            return;
        }

        unowned var state = players[active_player];
        if (!state.can_seek || state.length_us <= 0) {
            return;
        }

        var clamped_target = clamp_position (target_position_us, state.length_us);
        var offset = clamped_target - state.position_us;
        if (Math.fabs ((double) offset) < 100000.0) {
            return;
        }

        unowned var player = state.player;
        player.seek.begin (offset, (obj, res) => {
            try {
                player.seek.end (res);
                state.position_us = clamped_target;
                state.has_position = true;
                publish_player (state);
            } catch (Error e) {
                warning ("Failed to seek: %s", e.message);
            }
        });
    }

    public void activate_player_app () {
        if (active_player == null || !(active_player in players)) {
            return;
        }

        unowned var state = players[active_player];
        var desktop_id = resolve_desktop_id (state);
        if (focus_existing_player_window (state)) {
            return;
        }

        if (state.can_raise) {
            state.root.raise.begin ((obj, res) => {
                try {
                    state.root.raise.end (res);
                } catch (Error e) {
                    debug ("Couldn't raise player %s: %s", state.bus_name, e.message);
                    launch_player_from_desktop_id (desktop_id, state);
                }
            });
            return;
        }

        launch_player_from_desktop_id (desktop_id, state);
    }

    public void toggle_player_app_visibility () {
        if (active_player == null || !(active_player in players)) {
            return;
        }

        unowned var state = players[active_player];
        if (hide_player_windows (state)) {
            return;
        }

        activate_player_app ();
    }

    private async void connect_to_dbus () {
        if (bus_proxy != null) {
            return;
        }

        try {
            bus_proxy = yield Bus.get_proxy<FreedesktopDBus> (
                SESSION,
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus"
            );
            bus_proxy.name_owner_changed.connect (on_name_owner_changed);
            yield sync_players ();
        } catch (Error e) {
            warning ("Failed to initialize media monitor: %s", e.message);
        }
    }

    private async void sync_players () requires (bus_proxy != null) {
        string[] names;
        try {
            names = yield bus_proxy.list_names ();
        } catch (Error e) {
            warning ("Failed to list DBus names: %s", e.message);
            return;
        }

        foreach (var name in names) {
            if (is_mpris_player (name)) {
                add_player.begin (name);
            }
        }
    }

    private void on_name_owner_changed (string name, string old_owner, string new_owner) {
        if (!is_mpris_player (name)) {
            return;
        }

        if (new_owner == null || new_owner == "") {
            remove_player (name);
        } else {
            add_player.begin (name);
        }
    }

    private static bool is_mpris_player (string name) {
        return name.has_prefix (MPRIS_PREFIX);
    }

    private async void add_player (string bus_name) {
        if (bus_name in players) {
            return;
        }

        try {
            var properties = yield Bus.get_proxy<FreedesktopProperties> (SESSION, bus_name, MPRIS_PATH);
            var player = yield Bus.get_proxy<MprisPlayer> (SESSION, bus_name, MPRIS_PATH);
            var root = yield Bus.get_proxy<MprisRoot> (SESSION, bus_name, MPRIS_PATH);

            var state = new PlayerState (bus_name, properties, player, root);
            players[bus_name] = state;

            properties.properties_changed.connect ((iface, changed_properties, invalidated_properties) => {
                if (iface == MPRIS_PLAYER_IFACE) {
                    update_player_state (state, changed_properties, invalidated_properties);
                    ensure_player_position (state);
                    refresh_active_player ();
                    return;
                }

                if (iface == MPRIS_ROOT_IFACE) {
                    update_root_state (state, changed_properties, invalidated_properties);
                }
            });

            var player_props = yield properties.get_all (MPRIS_PLAYER_IFACE);
            update_player_state (state, player_props, {});

            var root_props = yield properties.get_all (MPRIS_ROOT_IFACE);
            update_root_state (state, root_props, {});

            ensure_player_position (state);
            refresh_active_player ();
        } catch (Error e) {
            warning ("Failed to track MPRIS player %s: %s", bus_name, e.message);
        }
    }

    private void remove_player (string bus_name) {
        if (!(bus_name in players)) {
            return;
        }

        players.remove (bus_name);
        if (active_player == bus_name) {
            active_player = null;
        }

        refresh_active_player ();
    }

    private static void update_player_state (
        PlayerState state,
        GLib.HashTable<string, GLib.Variant> changed_properties,
        string[] invalidated_properties
    ) {
        if ("PlaybackStatus" in changed_properties) {
            state.playback_status = (string) changed_properties["PlaybackStatus"];
        } else if ("PlaybackStatus" in invalidated_properties) {
            state.playback_status = "Stopped";
        }

        if ("CanPlay" in changed_properties) {
            state.can_play = (bool) changed_properties["CanPlay"];
        } else if ("CanPlay" in invalidated_properties) {
            state.can_play = false;
        }

        if ("CanPause" in changed_properties) {
            state.can_pause = (bool) changed_properties["CanPause"];
        } else if ("CanPause" in invalidated_properties) {
            state.can_pause = false;
        }

        if ("CanGoNext" in changed_properties) {
            state.can_go_next = (bool) changed_properties["CanGoNext"];
        } else if ("CanGoNext" in invalidated_properties) {
            state.can_go_next = false;
        }

        if ("CanGoPrevious" in changed_properties) {
            state.can_go_previous = (bool) changed_properties["CanGoPrevious"];
        } else if ("CanGoPrevious" in invalidated_properties) {
            state.can_go_previous = false;
        }

        if ("CanSeek" in changed_properties) {
            state.can_seek = (bool) changed_properties["CanSeek"];
        } else if ("CanSeek" in invalidated_properties) {
            state.can_seek = false;
        }

        if ("Position" in changed_properties) {
            state.position_us = (int64) changed_properties["Position"];
            state.has_position = true;
        } else if ("Position" in invalidated_properties) {
            state.position_us = 0;
            state.has_position = false;
        }

        if ("Metadata" in changed_properties) {
            var previous_track_id = state.track_id;
            parse_metadata (state, changed_properties["Metadata"]);
            if (state.track_id != previous_track_id && !("Position" in changed_properties)) {
                // On track switch many players don't include Position in this update.
                // Reset optimistically and mark as unknown so we can query it explicitly.
                state.position_us = 0;
                state.has_position = false;
            }
            state.position_us = clamp_position (state.position_us, state.length_us);
        } else if ("Metadata" in invalidated_properties) {
            state.title = null;
            state.artist = null;
            state.art_url = null;
            state.track_id = null;
            state.length_us = 0;
            state.position_us = 0;
            state.has_position = false;
        }
    }

    private static void parse_metadata (PlayerState state, GLib.Variant metadata) {
        state.title = lookup_string (metadata, "xesam:title");
        state.artist = lookup_first_string (metadata, "xesam:artist");
        state.art_url = lookup_string (metadata, "mpris:artUrl");
        state.track_id = lookup_track_id (metadata);
        state.length_us = lookup_int64 (metadata, "mpris:length");
    }

    private static void update_root_state (
        PlayerState state,
        GLib.HashTable<string, GLib.Variant> changed_properties,
        string[] invalidated_properties
    ) {
        if ("DesktopEntry" in changed_properties) {
            state.desktop_entry = normalize_desktop_id ((string) changed_properties["DesktopEntry"]);
        } else if ("DesktopEntry" in invalidated_properties) {
            state.desktop_entry = null;
        }

        if ("CanRaise" in changed_properties) {
            state.can_raise = (bool) changed_properties["CanRaise"];
        } else if ("CanRaise" in invalidated_properties) {
            state.can_raise = false;
        }
    }

    private static string? normalize_desktop_id (string? desktop_entry) {
        if (desktop_entry == null) {
            return null;
        }

        var trimmed = desktop_entry.strip ();
        if (trimmed == "") {
            return null;
        }

        return trimmed.has_suffix (".desktop") ? trimmed : "%s.desktop".printf (trimmed);
    }

    private static string? derive_desktop_id_from_bus_name (string bus_name) {
        if (!bus_name.has_prefix (MPRIS_PREFIX)) {
            return null;
        }

        var candidate = bus_name.substring (MPRIS_PREFIX.length);
        if (candidate == null || candidate == "") {
            return null;
        }

        var instance_index = candidate.index_of (".instance");
        if (instance_index > 0) {
            candidate = candidate[0:instance_index];
        }

        return normalize_desktop_id (candidate);
    }

    private static AppInfo? find_app_info (string desktop_id) {
        foreach (var app_info in AppInfo.get_all ()) {
            if (app_info.get_id () == desktop_id) {
                return app_info;
            }
        }

        return null;
    }

    private static string? resolve_desktop_id (PlayerState state) {
        return state.desktop_entry ?? derive_desktop_id_from_bus_name (state.bus_name);
    }

    private static string normalize_identifier_for_match (string? value) {
        if (value == null) {
            return "";
        }

        var normalized = value.strip ().down ();
        if (normalized.has_suffix (".desktop")) {
            normalized = normalized[0:normalized.length - 8];
        }

        return normalized;
    }

    private static bool matches_identifier (Window window, string identifier) {
        if (identifier == "") {
            return false;
        }

        var app_id = normalize_identifier_for_match (window.app_id);
        var sandboxed_app_id = normalize_identifier_for_match (window.sandboxed_app_id);
        var wm_class = normalize_identifier_for_match (window.wm_class);

        return app_id == identifier ||
            sandboxed_app_id == identifier ||
            wm_class == identifier ||
            app_id.contains (identifier) ||
            sandboxed_app_id.contains (identifier) ||
            wm_class.contains (identifier);
    }

    private static GLib.GenericArray<Window> get_windows_for_state (PlayerState state) {
        var matching_windows = new GLib.GenericArray<Window> ();
        var desktop_identifier = normalize_identifier_for_match (resolve_desktop_id (state));
        var bus_identifier = normalize_identifier_for_match (derive_desktop_id_from_bus_name (state.bus_name));

        foreach (var window in WindowSystem.get_default ().windows) {
            if (matches_identifier (window, desktop_identifier) ||
                matches_identifier (window, bus_identifier)) {
                matching_windows.add (window);
            }
        }

        return matching_windows;
    }

    private static bool focus_existing_player_window (PlayerState state) {
        var window_system = WindowSystem.get_default ();
        var desktop_integration = window_system.desktop_integration;
        if (desktop_integration == null) {
            return false;
        }

        var windows = get_windows_for_state (state);
        if (windows.length == 0) {
            return false;
        }

        Window? preferred_window = null;
        foreach (var window in windows) {
            if (window.has_focus) {
                return true;
            }

            if (preferred_window == null || (preferred_window.is_hidden && !window.is_hidden)) {
                preferred_window = window;
            }
        }

        if (preferred_window == null) {
            preferred_window = windows[0];
        }

        desktop_integration.focus_window.begin (preferred_window.uid);
        return true;
    }

    private static bool hide_player_windows (PlayerState state) {
        var desktop_integration = WindowSystem.get_default ().desktop_integration;
        if (desktop_integration == null) {
            return false;
        }

        var windows = get_windows_for_state (state);
        if (windows.length == 0) {
            return false;
        }

        Window? focused_visible = null;
        Window? visible_target = null;
        foreach (var window in windows) {
            if (window.is_hidden) {
                continue;
            }

            if (visible_target == null) {
                visible_target = window;
            }

            if (window.has_focus) {
                focused_visible = window;
                break;
            }
        }

        if (visible_target == null) {
            // Already hidden.
            return false;
        }

        if (focused_visible != null) {
            return GalaDBus.minimize_current_window ();
        }

        desktop_integration.focus_window.begin (visible_target.uid, (obj, res) => {
            try {
                desktop_integration.focus_window.end (res);
            } catch (Error e) {
                debug ("Couldn't focus player window before minimizing: %s", e.message);
                return;
            }

            Timeout.add (90, () => {
                GalaDBus.minimize_current_window ();
                return Source.REMOVE;
            });
        });

        return true;
    }

    private static void launch_player_from_desktop_id (string? desktop_id, PlayerState state) {
        if (desktop_id == null) {
            debug ("Couldn't resolve desktop entry for %s", state.bus_name);
            return;
        }

        var app_info = find_app_info (desktop_id);
        if (app_info == null) {
            debug ("Couldn't find AppInfo for %s", desktop_id);
            return;
        }

        var display = Gdk.Display.get_default ();
        if (display == null) {
            return;
        }

        try {
            var context = display.get_app_launch_context ();
            app_info.launch (null, context);
        } catch (Error e) {
            warning ("Failed to open player app %s: %s", desktop_id, e.message);
        }
    }

    private static string? lookup_string (GLib.Variant dict, string key) {
        var value = dict.lookup_value (key, null);
        if (value == null || !value.is_of_type (VariantType.STRING)) {
            return null;
        }

        return value.get_string ();
    }

    private static string? lookup_first_string (GLib.Variant dict, string key) {
        var value = dict.lookup_value (key, new VariantType ("as"));
        if (value == null) {
            return null;
        }

        var strv = value.get_strv ();
        if (strv.length == 0) {
            return null;
        }

        return strv[0];
    }

    private static int64 lookup_int64 (GLib.Variant dict, string key) {
        var value = dict.lookup_value (key, null);
        if (value == null) {
            return 0;
        }

        if (value.is_of_type (VariantType.INT64)) {
            return value.get_int64 ();
        }

        if (value.is_of_type (VariantType.UINT64)) {
            return (int64) value.get_uint64 ();
        }

        return 0;
    }

    private static string? lookup_track_id (GLib.Variant dict) {
        var value = dict.lookup_value ("mpris:trackid", null);
        if (value == null) {
            return null;
        }

        if (value.is_of_type (VariantType.STRING) ||
            value.is_of_type (new VariantType ("o"))) {
            return value.get_string ();
        }

        return null;
    }

    private void refresh_active_player () {
        PlayerState? chosen = null;

        if (active_player != null && active_player in players) {
            var current = players[active_player];
            // Keep controlling the same player while it is actively playing/paused.
            if (current.playback_status == "Playing" ||
                current.playback_status == "Paused") {
                chosen = current;
            }
        }

        if (chosen == null) {
            foreach (var player in players.get_values ()) {
                if (player.playback_status == "Playing") {
                    chosen = player;
                    break;
                }
            }
        }

        if (chosen == null) {
            foreach (var player in players.get_values ()) {
                if (player.playback_status == "Paused") {
                    chosen = player;
                    break;
                }
            }
        }

        // If there is no Playing/Paused player, hide the widget.
        publish_player (chosen);
    }

    private void ensure_player_position (PlayerState state) {
        if (!state.can_seek || state.length_us <= 0 || state.has_position || state.position_refresh_in_flight) {
            return;
        }

        state.position_refresh_in_flight = true;
        refresh_player_position.begin (state);
    }

    private async void refresh_player_position (PlayerState state) {
        try {
            var value = yield state.properties.get (MPRIS_PLAYER_IFACE, "Position");

            if (value.is_of_type (VariantType.VARIANT)) {
                value = value.get_variant ();
            }

            var position = parse_position_variant (value);
            if (position >= 0) {
                state.position_us = clamp_position (position, state.length_us);
                state.has_position = true;
            }
        } catch (Error e) {
            debug ("Couldn't refresh MPRIS position for %s: %s", state.bus_name, e.message);
        } finally {
            state.position_refresh_in_flight = false;
        }

        if (!(state.bus_name in players)) {
            return;
        }

        if (active_player == state.bus_name) {
            publish_player (state);
        }
    }

    private static int64 parse_position_variant (GLib.Variant value) {
        if (value.is_of_type (VariantType.INT64)) {
            return value.get_int64 ();
        }

        if (value.is_of_type (VariantType.UINT64)) {
            return (int64) value.get_uint64 ();
        }

        if (value.is_of_type (VariantType.INT32)) {
            return (int64) value.get_int32 ();
        }

        if (value.is_of_type (VariantType.UINT32)) {
            return (int64) value.get_uint32 ();
        }

        return -1;
    }

    private void publish_player (PlayerState? player) {
        if (player == null) {
            active_player = null;
            title = null;
            artist = null;
            art_url = null;
            is_playing = false;
            can_play_pause = false;
            can_go_next = false;
            can_go_previous = false;
            can_seek = false;
            position_us = 0;
            length_us = 0;
            stop_position_tick ();
            changed ();
            return;
        }

        active_player = player.bus_name;
        title = player.title;
        artist = player.artist;
        art_url = player.art_url;
        is_playing = player.playback_status == "Playing";
        // Some players don't expose CanPlay/CanPause consistently; allow toggling
        // as long as the player isn't fully stopped.
        can_play_pause = player.can_play || player.can_pause || player.playback_status != "Stopped";
        can_go_next = player.can_go_next;
        can_go_previous = player.can_go_previous;
        can_seek = player.can_seek && player.length_us > 0;
        length_us = player.length_us;
        position_us = clamp_position (player.position_us, player.length_us);
        player.position_us = position_us;
        update_position_tick ();
        changed ();
    }

    private static int64 clamp_position (int64 position, int64 length) {
        if (position < 0) {
            return 0;
        }

        if (length > 0 && position > length) {
            return length;
        }

        return position;
    }

    private void update_position_tick () {
        if (active_player == null || !(active_player in players) || !is_playing || !can_seek || length_us <= 0) {
            stop_position_tick ();
            return;
        }

        unowned var state = players[active_player];
        if (!state.has_position) {
            ensure_player_position (state);
            stop_position_tick ();
            return;
        }

        if (position_tick_id > 0) {
            return;
        }

        position_tick_last_us = get_monotonic_time ();
        position_tick_id = Timeout.add (250, () => {
            if (active_player == null || !(active_player in players) || !is_playing || !can_seek || length_us <= 0) {
                stop_position_tick ();
                return Source.REMOVE;
            }

            unowned var tick_state = players[active_player];
            if (!tick_state.has_position) {
                ensure_player_position (tick_state);
                stop_position_tick ();
                return Source.REMOVE;
            }

            var now_us = get_monotonic_time ();
            var delta_us = now_us - position_tick_last_us;
            position_tick_last_us = now_us;

            if (delta_us > 0) {
                tick_state.position_us = clamp_position (tick_state.position_us + delta_us, tick_state.length_us);
                position_us = tick_state.position_us;
                changed ();
            }

            return Source.CONTINUE;
        });
    }

    private void stop_position_tick () {
        if (position_tick_id == 0) {
            return;
        }

        Source.remove (position_tick_id);
        position_tick_id = 0;
        position_tick_last_us = 0;
    }
}
