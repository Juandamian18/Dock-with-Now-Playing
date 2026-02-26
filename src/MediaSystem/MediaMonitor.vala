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

public class Dock.MediaMonitor : Object {
    private class PlayerState : Object {
        public string bus_name { get; construct; }
        public FreedesktopProperties properties { get; construct; }
        public MprisPlayer player { get; construct; }

        public string playback_status { get; set; default = "Stopped"; }
        public string? title { get; set; default = null; }
        public string? artist { get; set; default = null; }
        public string? art_url { get; set; default = null; }
        public string? track_id { get; set; default = null; }
        public bool can_play { get; set; default = false; }
        public bool can_pause { get; set; default = false; }
        public bool can_go_next { get; set; default = false; }
        public bool can_go_previous { get; set; default = false; }
        public bool can_seek { get; set; default = false; }
        public int64 position_us { get; set; default = 0; }
        public int64 length_us { get; set; default = 0; }

        public PlayerState (string bus_name, FreedesktopProperties properties, MprisPlayer player) {
            Object (bus_name: bus_name, properties: properties, player: player);
        }
    }

    private const string MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
    private const string MPRIS_PATH = "/org/mpris/MediaPlayer2";
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
                publish_player (state);
            } catch (Error e) {
                warning ("Failed to seek: %s", e.message);
            }
        });
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

            var state = new PlayerState (bus_name, properties, player);
            players[bus_name] = state;

            properties.properties_changed.connect ((iface, changed_properties, invalidated_properties) => {
                if (iface != MPRIS_PLAYER_IFACE) {
                    return;
                }

                update_player_state (state, changed_properties, invalidated_properties);
                refresh_active_player ();
            });

            var props = yield properties.get_all (MPRIS_PLAYER_IFACE);
            update_player_state (state, props, {});
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
        } else if ("Position" in invalidated_properties) {
            state.position_us = 0;
        }

        if ("Metadata" in changed_properties) {
            var previous_track_id = state.track_id;
            parse_metadata (state, changed_properties["Metadata"]);
            if (state.track_id != previous_track_id && !("Position" in changed_properties)) {
                state.position_us = 0;
            }
            state.position_us = clamp_position (state.position_us, state.length_us);
        } else if ("Metadata" in invalidated_properties) {
            state.title = null;
            state.artist = null;
            state.art_url = null;
            state.track_id = null;
            state.length_us = 0;
            state.position_us = 0;
        }
    }

    private static void parse_metadata (PlayerState state, GLib.Variant metadata) {
        state.title = lookup_string (metadata, "xesam:title");
        state.artist = lookup_first_string (metadata, "xesam:artist");
        state.art_url = lookup_string (metadata, "mpris:artUrl");
        state.track_id = lookup_track_id (metadata);
        state.length_us = lookup_int64 (metadata, "mpris:length");
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

        if (position_tick_id > 0) {
            return;
        }

        position_tick_last_us = get_monotonic_time ();
        position_tick_id = Timeout.add (250, () => {
            if (active_player == null || !(active_player in players) || !is_playing || !can_seek || length_us <= 0) {
                stop_position_tick ();
                return Source.REMOVE;
            }

            var now_us = get_monotonic_time ();
            var delta_us = now_us - position_tick_last_us;
            position_tick_last_us = now_us;

            if (delta_us > 0) {
                unowned var state = players[active_player];
                state.position_us = clamp_position (state.position_us + delta_us, state.length_us);
                position_us = state.position_us;
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
