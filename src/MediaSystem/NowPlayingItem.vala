/*
 * SPDX-License-Identifier: GPL-3.0
 * SPDX-FileCopyrightText: 2026 elementary, Inc. (https://elementary.io)
 */

public class Dock.NowPlayingItem : ContainerItem {
    private const string ACTION_GROUP_PREFIX = "now-playing";
    private const string ACTION_PREFIX = ACTION_GROUP_PREFIX + ".";
    private const string MINIMAL_MODE_ACTION = "minimal-mode";
    private const string COVER_ANIMATION_ACTION = "cover-animation";
    private const string SEEK_BAR_ACTION = "seek-bar";

    private const int CONTROLS_WIDTH = 84;
    private const int MINIMAL_TOOLTIP_OFFSET_Y = -8;
    private const int CONTENT_HORIZONTAL_MARGIN = 10;
    private const int CONTENT_SPACING = 8;
    private const int TEXT_WIDTH = CARD_WIDTH - (CONTENT_HORIZONTAL_MARGIN * 2) - CONTROLS_WIDTH - CONTENT_SPACING;

    private class InteractiveTooltipPopover : Gtk.Popover {
        class construct {
            set_css_name ("tooltip");
        }
    }

    private class FixedArtwork : Gtk.Widget {
        private Gdk.Paintable? _paintable;
        private int _fixed_width = CARD_WIDTH;
        private int _fixed_height = Launcher.ICON_SIZE;
        private float _corner_radius = 10f;
        private bool _animate_playback = false;
        private uint _drift_tick_id = 0;
        private double _drift_strength = 0.0;
        private double _drift_x = 0.0;
        private double _drift_y = 0.0;
        private int64 _drift_start_us = 0;

        public Gdk.Paintable? paintable {
            get {
                return _paintable;
            }

            set {
                _paintable = value;
                queue_draw ();
            }
        }

        public int fixed_width {
            get {
                return _fixed_width;
            }

            set {
                if (_fixed_width == value) {
                    return;
                }

                _fixed_width = value;
                queue_resize ();
            }
        }

        public int fixed_height {
            get {
                return _fixed_height;
            }

            set {
                if (_fixed_height == value) {
                    return;
                }

                _fixed_height = value;
                queue_resize ();
            }
        }

        public float corner_radius {
            get {
                return _corner_radius;
            }

            set {
                if (_corner_radius == value) {
                    return;
                }

                _corner_radius = value;
                queue_draw ();
            }
        }

        public bool animate_playback {
            get {
                return _animate_playback;
            }

            set {
                if (_animate_playback == value) {
                    return;
                }

                _animate_playback = value;
                ensure_drift_tick ();
            }
        }

        ~FixedArtwork () {
            stop_drift_tick ();
        }

        public override void measure (
            Gtk.Orientation orientation,
            int for_size,
            out int minimum,
            out int natural,
            out int minimum_baseline,
            out int natural_baseline
        ) {
            if (orientation == Gtk.Orientation.HORIZONTAL) {
                minimum = _fixed_width;
                natural = _fixed_width;
            } else {
                minimum = _fixed_height;
                natural = _fixed_height;
            }

            minimum_baseline = -1;
            natural_baseline = -1;
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            base.snapshot (snapshot);

            var paintable = _paintable;
            if (paintable == null) {
                return;
            }

            var width = get_width ();
            var height = get_height ();
            if (width <= 0 || height <= 0) {
                return;
            }

            Graphene.Rect rect = Graphene.Rect ();
            rect.init (0, 0, width, height);

            Gsk.RoundedRect rounded_rect = Gsk.RoundedRect ();
            rounded_rect.init_from_rect (rect, _corner_radius);

            snapshot.push_rounded_clip (rounded_rect);

            var intrinsic_width = paintable.get_intrinsic_width ();
            var intrinsic_height = paintable.get_intrinsic_height ();

            if (intrinsic_width <= 0 || intrinsic_height <= 0) {
                paintable.snapshot (snapshot, width, height);
                snapshot.pop ();
                return;
            }

            // Keep a small overscan while animating so the artwork can drift without exposing edges.
            var overscan = 1.0 + (0.045 * _drift_strength);
            var scale = double.max ((double) width / intrinsic_width, (double) height / intrinsic_height) * overscan;
            var draw_width = (double) intrinsic_width * scale;
            var draw_height = (double) intrinsic_height * scale;

            var max_shift_x = (draw_width - width) / 2.0;
            var max_shift_y = (draw_height - height) / 2.0;
            var shift_x = max_shift_x * 0.48 * _drift_x;
            var shift_y = max_shift_y * 0.48 * _drift_y;

            Graphene.Point offset = Graphene.Point ();
            offset.init (
                (float) (((width - draw_width) / 2.0) + shift_x),
                (float) (((height - draw_height) / 2.0) + shift_y)
            );

            snapshot.save ();
            snapshot.translate (offset);
            paintable.snapshot (snapshot, draw_width, draw_height);
            snapshot.restore ();

            snapshot.pop ();
        }

        private void ensure_drift_tick () {
            if (_drift_tick_id > 0) {
                return;
            }

            _drift_tick_id = add_tick_callback ((widget, frame_clock) => {
                if (_drift_start_us == 0) {
                    _drift_start_us = frame_clock.get_frame_time ();
                }

                var elapsed = (frame_clock.get_frame_time () - _drift_start_us) / 1000000.0;
                var target_strength = _animate_playback ? 1.0 : 0.0;
                _drift_strength += (target_strength - _drift_strength) * 0.05;

                _drift_x = Math.sin (elapsed * 0.28);
                _drift_y = Math.cos (elapsed * 0.19) * 0.55;

                if (!_animate_playback && _drift_strength <= 0.01) {
                    _drift_strength = 0.0;
                    _drift_x = 0.0;
                    _drift_y = 0.0;
                    _drift_tick_id = 0;
                    queue_draw ();
                    return Source.REMOVE;
                }

                queue_draw ();
                return Source.CONTINUE;
            });
        }

        private void stop_drift_tick () {
            if (_drift_tick_id == 0) {
                return;
            }

            remove_tick_callback (_drift_tick_id);
            _drift_tick_id = 0;
        }
    }

    private class MarqueeLabel : Gtk.Box {
        private Gtk.Label text_label;

        public string text {
            get {
                return text_label.label;
            }

            set {
                text_label.label = value;
            }
        }

        public MarqueeLabel () {
            Object ();
        }

        construct {
            orientation = HORIZONTAL;
            overflow = HIDDEN;

            text_label = new Gtk.Label ("") {
                xalign = 0,
                wrap = false,
                ellipsize = Pango.EllipsizeMode.END,
                single_line_mode = true,
                hexpand = true
            };

            append (text_label);
        }

        public void add_text_class (string css_class) {
            text_label.add_css_class (css_class);
        }
    }

    public const int CARD_WIDTH = 220;
    public const int CARD_OUTER_WIDTH = CARD_WIDTH + Launcher.PADDING * 2;

    public signal void playback_appeared ();
    public signal void mode_changed ();

    public bool minimal_mode { get; set; default = false; }
    public bool cover_animation { get; set; default = true; }
    public bool seek_bar { get; set; default = true; }

    public MediaMonitor monitor { private get; construct; }

    public bool has_player {
        get {
            return monitor.has_player;
        }
    }

    private FixedArtwork cover;
    private MarqueeLabel title_label;
    private MarqueeLabel artist_label;
    private Gtk.Widget dim_overlay;
    private Gtk.Widget content_overlay;

    private Gtk.Button previous_button;
    private Gtk.Button play_pause_button;
    private Gtk.Button next_button;
    private Gtk.Button tooltip_previous_button;
    private Gtk.Button tooltip_play_pause_button;
    private Gtk.Button tooltip_next_button;
    private Gtk.Box tooltip_controls;
    private Gtk.Label tooltip_title_label;
    private Gtk.Label tooltip_artist_label;
    private Gtk.Scale seek_scale;
    private Gtk.Scale tooltip_seek_scale;
    private Gtk.Popover minimal_hover_popover;
    private bool minimal_hovering_item = false;
    private bool minimal_hovering_popover = false;
    private bool minimal_hover_blocked = false;
    private uint minimal_popdown_timeout_id = 0;
    private bool seek_ui_updating = false;
    private bool user_seeking = false;
    private uint seek_commit_timeout_id = 0;
    private double pending_seek_fraction = 0.0;

    private bool visible_in_dock = false;
    private string? current_art_url = null;
    private uint artwork_request_serial = 0;
    private uint artwork_refresh_tick_id = 0;

    private static Soup.Session soup_session;
    private Gdk.Paintable fallback_artwork;

    public NowPlayingItem () {
        var media_monitor = new MediaMonitor ();
        Object (
            monitor: media_monitor,
            disallow_dnd: true,
            group: Group.LAUNCHER
        );
    }

    protected override int get_width_for_icon_size (int icon_size) {
        return minimal_mode ? icon_size : CARD_WIDTH;
    }

    public int get_dock_width () {
        return minimal_mode ? ItemManager.get_launcher_size () : CARD_OUTER_WIDTH;
    }

    construct {
        if (soup_session == null) {
            soup_session = new Soup.Session ();
        }

        add_css_class ("now-playing-item");

        cover = new FixedArtwork () {
            hexpand = true,
            vexpand = false
        };
        bind_property ("icon-size", cover, "fixed-height", SYNC_CREATE);
        cover.add_css_class ("now-playing-artwork");
        fallback_artwork = Gtk.IconTheme.get_for_display (Gdk.Display.get_default ()).lookup_icon (
            "audio-x-generic-symbolic",
            null,
            48,
            1,
            Gtk.TextDirection.LTR,
            (Gtk.IconLookupFlags) 0
        );
        cover.paintable = fallback_artwork;

        var overlay = new Gtk.Overlay () {
            child = cover
        };

        dim_overlay = new Gtk.Box (HORIZONTAL, 0);
        dim_overlay.add_css_class ("now-playing-dim");
        overlay.add_overlay (dim_overlay);

        title_label = new MarqueeLabel ();
        title_label.add_text_class ("now-playing-title");

        artist_label = new MarqueeLabel ();
        artist_label.add_text_class ("now-playing-artist");

        var text_box = new Gtk.Box (VERTICAL, 1) {
            hexpand = false,
            halign = START
        };
        text_box.add_css_class ("now-playing-textbox");
        text_box.width_request = TEXT_WIDTH;
        title_label.width_request = TEXT_WIDTH;
        artist_label.width_request = TEXT_WIDTH;
        text_box.append (title_label);
        text_box.append (artist_label);

        previous_button = new Gtk.Button.from_icon_name ("media-skip-backward-symbolic");
        previous_button.tooltip_text = _("Previous");
        previous_button.add_css_class ("flat");
        previous_button.clicked.connect (monitor.previous);

        play_pause_button = new Gtk.Button.from_icon_name ("media-playback-start-symbolic");
        play_pause_button.add_css_class ("flat");
        play_pause_button.clicked.connect (monitor.play_pause);

        next_button = new Gtk.Button.from_icon_name ("media-skip-forward-symbolic");
        next_button.tooltip_text = _("Next");
        next_button.add_css_class ("flat");
        next_button.clicked.connect (monitor.next);

        var controls = new Gtk.Box (HORIZONTAL, 6) {
            halign = END,
            valign = CENTER,
            homogeneous = true
        };
        controls.width_request = CONTROLS_WIDTH;
        controls.add_css_class ("now-playing-controls");
        controls.append (previous_button);
        controls.append (play_pause_button);
        controls.append (next_button);

        text_box.margin_end = CONTROLS_WIDTH + CONTENT_SPACING;
        text_box.valign = CENTER;

        content_overlay = new Gtk.Overlay () {
            margin_start = CONTENT_HORIZONTAL_MARGIN,
            margin_end = CONTENT_HORIZONTAL_MARGIN,
            margin_top = 4,
            margin_bottom = 4
        };
        content_overlay.add_css_class ("now-playing-content");
        ((Gtk.Overlay) content_overlay).child = text_box;
        ((Gtk.Overlay) content_overlay).add_overlay (controls);
        overlay.add_overlay (content_overlay);

        seek_scale = new Gtk.Scale.with_range (HORIZONTAL, 0, 1, 0.001) {
            draw_value = false,
            hexpand = true,
            halign = FILL,
            valign = END,
            can_focus = false,
            margin_start = CONTENT_HORIZONTAL_MARGIN,
            margin_end = CONTENT_HORIZONTAL_MARGIN,
            margin_bottom = 1
        };
        seek_scale.add_css_class ("now-playing-seek");
        seek_scale.value_changed.connect (() => on_seek_value_changed (seek_scale));
        overlay.add_overlay (seek_scale);

        child = overlay;

        var tooltip_box = new Gtk.Box (VERTICAL, 4) {
            margin_start = 10,
            margin_end = 10,
            margin_top = 8,
            margin_bottom = 8
        };
        tooltip_box.add_css_class ("now-playing-tooltip");

        tooltip_title_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = false,
            ellipsize = END,
            single_line_mode = true,
            width_request = TEXT_WIDTH,
            hexpand = true
        };
        tooltip_title_label.add_css_class ("now-playing-tooltip-title");

        tooltip_artist_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = false,
            ellipsize = END,
            single_line_mode = true,
            width_request = TEXT_WIDTH,
            hexpand = true
        };
        tooltip_artist_label.add_css_class ("now-playing-tooltip-artist");

        var tooltip_text_box = new Gtk.Box (VERTICAL, 1) {
            hexpand = true,
            halign = START,
            valign = CENTER
        };
        tooltip_text_box.width_request = TEXT_WIDTH;
        tooltip_text_box.append (tooltip_title_label);
        tooltip_text_box.append (tooltip_artist_label);

        tooltip_previous_button = new Gtk.Button.from_icon_name ("media-skip-backward-symbolic");
        tooltip_previous_button.tooltip_text = _("Previous");
        tooltip_previous_button.add_css_class ("flat");
        tooltip_previous_button.clicked.connect (monitor.previous);

        tooltip_play_pause_button = new Gtk.Button.from_icon_name ("media-playback-start-symbolic");
        tooltip_play_pause_button.add_css_class ("flat");
        tooltip_play_pause_button.clicked.connect (monitor.play_pause);

        tooltip_next_button = new Gtk.Button.from_icon_name ("media-skip-forward-symbolic");
        tooltip_next_button.tooltip_text = _("Next");
        tooltip_next_button.add_css_class ("flat");
        tooltip_next_button.clicked.connect (monitor.next);

        tooltip_controls = new Gtk.Box (HORIZONTAL, 6) {
            halign = END,
            valign = CENTER,
            homogeneous = true
        };
        tooltip_controls.width_request = CONTROLS_WIDTH;
        tooltip_controls.add_css_class ("now-playing-controls");
        tooltip_controls.append (tooltip_previous_button);
        tooltip_controls.append (tooltip_play_pause_button);
        tooltip_controls.append (tooltip_next_button);

        var tooltip_header = new Gtk.Box (HORIZONTAL, CONTENT_SPACING) {
            hexpand = true,
            width_request = CARD_WIDTH
        };
        tooltip_header.append (tooltip_text_box);
        tooltip_header.append (tooltip_controls);

        tooltip_seek_scale = new Gtk.Scale.with_range (HORIZONTAL, 0, 1, 0.001) {
            draw_value = false,
            hexpand = true,
            width_request = CARD_WIDTH,
            can_focus = false
        };
        tooltip_seek_scale.add_css_class ("now-playing-seek");
        tooltip_seek_scale.value_changed.connect (() => on_seek_value_changed (tooltip_seek_scale));

        tooltip_box.append (tooltip_header);
        tooltip_box.append (tooltip_seek_scale);

        minimal_hover_popover = new InteractiveTooltipPopover () {
            autohide = false,
            position = TOP,
            has_arrow = false,
            child = tooltip_box
        };
        minimal_hover_popover.set_offset (0, MINIMAL_TOOLTIP_OFFSET_Y);
        minimal_hover_popover.set_parent (this);

        var minimal_item_motion = new Gtk.EventControllerMotion ();
        add_controller (minimal_item_motion);
        minimal_item_motion.enter.connect (() => {
            if (!minimal_mode || minimal_hover_blocked) {
                return;
            }

            minimal_hovering_item = true;
            show_minimal_hover_popover ();
        });
        minimal_item_motion.leave.connect (() => {
            if (!minimal_mode) {
                return;
            }

            minimal_hovering_item = false;
            schedule_minimal_popdown ();
        });

        var minimal_popover_motion = new Gtk.EventControllerMotion ();
        ((Gtk.Widget) minimal_hover_popover).add_controller (minimal_popover_motion);
        minimal_popover_motion.enter.connect (() => {
            minimal_hovering_popover = true;
            cancel_minimal_popdown ();
        });
        minimal_popover_motion.leave.connect (() => {
            minimal_hovering_popover = false;
            schedule_minimal_popdown ();
        });

        var action_group = new SimpleActionGroup ();
        action_group.add_action (new PropertyAction (MINIMAL_MODE_ACTION, this, "minimal-mode"));
        action_group.add_action (new PropertyAction (COVER_ANIMATION_ACTION, this, "cover-animation"));
        action_group.add_action (new PropertyAction (SEEK_BAR_ACTION, this, "seek-bar"));
        insert_action_group (ACTION_GROUP_PREFIX, action_group);

        var menu = new Menu ();
        menu.append (_("Minimal Mode"), ACTION_PREFIX + MINIMAL_MODE_ACTION);
        menu.append (_("Cover Animation"), ACTION_PREFIX + COVER_ANIMATION_ACTION);
        menu.append (_("Seek Bar"), ACTION_PREFIX + SEEK_BAR_ACTION);
        popover_menu = new Gtk.PopoverMenu.from_model (menu) {
            autohide = true,
            position = TOP
        };
        popover_menu.set_offset (0, -1);
        popover_menu.set_parent (this);
        popover_menu.closed.connect (() => {
            minimal_hover_blocked = false;
        });

        gesture_click.button = 0;
        gesture_click.released.connect (on_click_released);

        if (dock_settings.settings_schema.has_key ("now-playing-minimal-mode")) {
            dock_settings.bind ("now-playing-minimal-mode", this, "minimal-mode", DEFAULT);
        }
        if (dock_settings.settings_schema.has_key ("now-playing-cover-animation")) {
            dock_settings.bind ("now-playing-cover-animation", this, "cover-animation", DEFAULT);
        }
        if (dock_settings.settings_schema.has_key ("now-playing-seek-bar")) {
            dock_settings.bind ("now-playing-seek-bar", this, "seek-bar", DEFAULT);
        }
        notify["minimal-mode"].connect (apply_mode);
        notify["cover-animation"].connect (update_cover_animation);
        notify["seek-bar"].connect (update_seek_bar_state);
        apply_mode ();

        monitor.changed.connect (sync_from_monitor);
    }

    ~NowPlayingItem () {
        cancel_minimal_popdown ();
        cancel_seek_commit ();
        cancel_artwork_refresh ();
        minimal_hover_popover.unparent ();
        minimal_hover_popover.dispose ();
        popover_menu.unparent ();
        popover_menu.dispose ();
    }

    public void load () {
        monitor.load ();
    }

    public override void cleanup () {
        // Keep this item alive so it can re-appear without creating a new monitor.
    }

    private void on_click_released (int n_press, double x, double y) {
        switch (gesture_click.get_current_button ()) {
            case Gdk.BUTTON_PRIMARY:
                if (clicked_interactive_widget (x, y)) {
                    break;
                }

                if (n_press == 1) {
                    monitor.toggle_player_app_visibility ();
                }
                break;
            case Gdk.BUTTON_MIDDLE:
                monitor.play_pause ();
                break;
            case Gdk.BUTTON_SECONDARY:
                minimal_hover_blocked = true;
                minimal_hovering_item = false;
                minimal_hovering_popover = false;
                cancel_minimal_popdown ();
                minimal_hover_popover.popdown ();
                popover_menu.popup ();
                popover_tooltip.popdown ();
                break;
        }
    }

    private bool clicked_interactive_widget (double x, double y) {
        Gtk.Widget? target = pick (x, y, Gtk.PickFlags.DEFAULT);
        while (target != null && target != this) {
            if (target is Gtk.Button || target is Gtk.Scale) {
                return true;
            }

            target = target.get_parent ();
        }

        return false;
    }

    private void apply_mode () {
        if (minimal_mode) {
            add_css_class ("minimal");
            cover.fixed_width = icon_size;
            cover.corner_radius = 6f;
            dim_overlay.visible = false;
            content_overlay.visible = false;
            tooltip_controls.visible = true;
            tooltip_text = null;
            popover_tooltip.popdown ();
        } else {
            remove_css_class ("minimal");
            cover.fixed_width = CARD_WIDTH;
            cover.corner_radius = 10f;
            dim_overlay.visible = true;
            content_overlay.visible = true;
            tooltip_controls.visible = false;
            minimal_hover_popover.popdown ();
            if (monitor.has_player) {
                tooltip_text = "%s\n%s".printf (tooltip_title_label.label, tooltip_artist_label.label);
            }
        }

        update_cover_animation ();
        update_seek_bar_state ();

        // Refresh width-request binding transform on ContainerItem.
        notify_property ("icon-size");
        queue_resize ();
        mode_changed ();
    }

    private void show_minimal_hover_popover () {
        if (minimal_hover_blocked || popover_menu.visible) {
            return;
        }

        cancel_minimal_popdown ();
        minimal_hover_popover.popup ();
    }

    private void schedule_minimal_popdown () {
        cancel_minimal_popdown ();

        minimal_popdown_timeout_id = Timeout.add (120, () => {
            minimal_popdown_timeout_id = 0;

            if (!minimal_hovering_item && !minimal_hovering_popover) {
                minimal_hover_popover.popdown ();
            }

            return Source.REMOVE;
        });
    }

    private void cancel_minimal_popdown () {
        if (minimal_popdown_timeout_id > 0) {
            Source.remove (minimal_popdown_timeout_id);
            minimal_popdown_timeout_id = 0;
        }
    }

    private void on_seek_value_changed (Gtk.Scale source) {
        if (seek_ui_updating || !seek_bar) {
            return;
        }

        user_seeking = true;
        pending_seek_fraction = source.get_value ();

        seek_ui_updating = true;
        if (source == seek_scale) {
            tooltip_seek_scale.set_value (pending_seek_fraction);
        } else {
            seek_scale.set_value (pending_seek_fraction);
        }
        seek_ui_updating = false;

        schedule_seek_commit ();
    }

    private void schedule_seek_commit () {
        cancel_seek_commit ();

        seek_commit_timeout_id = Timeout.add (140, () => {
            seek_commit_timeout_id = 0;

            if (seek_bar && monitor.can_seek && monitor.length_us > 0) {
                var target = (int64) ((double) monitor.length_us * pending_seek_fraction);
                monitor.seek_to (target);
            }

            user_seeking = false;
            update_seek_bar_state ();
            return Source.REMOVE;
        });
    }

    private void cancel_seek_commit () {
        if (seek_commit_timeout_id == 0) {
            return;
        }

        Source.remove (seek_commit_timeout_id);
        seek_commit_timeout_id = 0;
    }

    private void sync_from_monitor () {
        if (!monitor.has_player) {
            update_cover_animation ();
            user_seeking = false;
            cancel_seek_commit ();
            cancel_artwork_refresh ();
            tooltip_text = null;
            if (visible_in_dock) {
                visible_in_dock = false;
                minimal_hover_popover.popdown ();
                removed ();
            }

            return;
        }

        var title = monitor.title ?? _("Nothing Playing");
        var artist = monitor.artist ?? _("Unknown Artist");

        title_label.text = title;
        artist_label.text = artist;
        tooltip_title_label.label = title;
        tooltip_artist_label.label = artist;

        if (!minimal_mode) {
            tooltip_text = "%s\n%s".printf (title, artist);
        } else {
            tooltip_text = null;
        }

        var play_pause_icon = monitor.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
        if (monitor.is_playing) {
            play_pause_button.icon_name = play_pause_icon;
            play_pause_button.tooltip_text = _("Pause");
            tooltip_play_pause_button.icon_name = play_pause_icon;
            tooltip_play_pause_button.tooltip_text = _("Pause");
        } else {
            play_pause_button.icon_name = play_pause_icon;
            play_pause_button.tooltip_text = _("Play");
            tooltip_play_pause_button.icon_name = play_pause_icon;
            tooltip_play_pause_button.tooltip_text = _("Play");
        }

        play_pause_button.sensitive = monitor.can_play_pause;
        previous_button.sensitive = monitor.can_go_previous;
        next_button.sensitive = monitor.can_go_next;
        tooltip_play_pause_button.sensitive = monitor.can_play_pause;
        tooltip_previous_button.sensitive = monitor.can_go_previous;
        tooltip_next_button.sensitive = monitor.can_go_next;
        update_cover_animation ();
        update_seek_bar_state ();

        set_artwork (monitor.art_url);

        if (!visible_in_dock) {
            visible_in_dock = true;
            playback_appeared ();
            schedule_artwork_refresh ();
        }
    }

    private void update_cover_animation () {
        cover.animate_playback = !minimal_mode && cover_animation && monitor.is_playing;
    }

    private void update_seek_bar_state () {
        var show_inline_seek = !minimal_mode && seek_bar;
        seek_scale.visible = show_inline_seek;
        tooltip_seek_scale.visible = minimal_mode && seek_bar;

        var can_seek_now = seek_bar && monitor.can_seek && monitor.length_us > 0;
        seek_scale.sensitive = can_seek_now && !minimal_mode;
        tooltip_seek_scale.sensitive = can_seek_now && minimal_mode;

        // Keep text and controls optically centered when the inline seek bar is hidden.
        if (show_inline_seek) {
            content_overlay.margin_top = 2;
            content_overlay.margin_bottom = 8;
        } else {
            content_overlay.margin_top = 4;
            content_overlay.margin_bottom = 4;
        }

        if (user_seeking || monitor.length_us <= 0) {
            return;
        }

        var fraction = ((double) monitor.position_us / (double) monitor.length_us);
        if (fraction < 0.0) {
            fraction = 0.0;
        } else if (fraction > 1.0) {
            fraction = 1.0;
        }

        seek_ui_updating = true;
        seek_scale.set_value (fraction);
        tooltip_seek_scale.set_value (fraction);
        seek_ui_updating = false;
    }

    private void set_artwork (string? art_url) {
        if (art_url == current_art_url) {
            // On first appearance/reappearance the widget can briefly keep a stale snapshot
            // until the next pointer-driven redraw. Force a frame refresh in that case.
            schedule_artwork_refresh ();
            return;
        }

        current_art_url = art_url;
        artwork_request_serial++;

        Gdk.Paintable? paintable = null;

        if (art_url != null && art_url != "") {
            try {
                if (art_url.has_prefix ("file://")) {
                    paintable = Gdk.Texture.from_file (File.new_for_uri (art_url));
                } else if (art_url.has_prefix ("/")) {
                    paintable = Gdk.Texture.from_file (File.new_for_path (art_url));
                } else if (art_url.has_prefix ("https://") || art_url.has_prefix ("http://")) {
                    load_remote_artwork.begin (art_url, artwork_request_serial);
                    return;
                }
            } catch (Error e) {
                debug ("Couldn't load artwork '%s': %s", art_url, e.message);
            }
        }

        if (paintable != null) {
            cover.paintable = paintable;
            schedule_artwork_refresh ();
            return;
        }

        cover.paintable = fallback_artwork;
        schedule_artwork_refresh ();
    }

    private async void load_remote_artwork (string art_url, uint request_serial) {
        try {
            var message = new Soup.Message ("GET", art_url);
            var bytes = yield soup_session.send_and_read_async (message, Priority.DEFAULT, null);

            if (request_serial != artwork_request_serial || art_url != current_art_url) {
                return;
            }

            var texture = Gdk.Texture.from_bytes (bytes);
            cover.paintable = texture;
            schedule_artwork_refresh ();
        } catch (Error e) {
            if (request_serial != artwork_request_serial || art_url != current_art_url) {
                return;
            }

            debug ("Couldn't download artwork '%s': %s", art_url, e.message);
            cover.paintable = fallback_artwork;
            schedule_artwork_refresh ();
        }
    }

    private void schedule_artwork_refresh () {
        if (artwork_refresh_tick_id != 0) {
            return;
        }

        artwork_refresh_tick_id = add_tick_callback ((widget, frame_clock) => {
            artwork_refresh_tick_id = 0;
            cover.queue_resize ();
            cover.queue_draw ();
            dim_overlay.queue_draw ();
            queue_draw ();
            return Source.REMOVE;
        });
    }

    private void cancel_artwork_refresh () {
        if (artwork_refresh_tick_id == 0) {
            return;
        }

        remove_tick_callback (artwork_refresh_tick_id);
        artwork_refresh_tick_id = 0;
    }
}
