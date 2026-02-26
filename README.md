# Dock (elementary OS) - Now Playing Edition

[English](README.md) | [Espanol](README.es.md)

Fast app launcher and window switcher for Pantheon, with an integrated **Now Playing** widget in the dock.

## What This Project Is

This repository contains the elementary OS (Pantheon) dock, buildable from source, with a **Now Playing** implementation that lets you:

- See album art, title, and artist for currently playing media.
- Control `previous`, `play/pause`, and `next` directly from the dock.
- Use two visual modes: `Normal` (full card) and `Minimal` (cover-only with controls in tooltip).

The widget uses MPRIS, so it works with compatible players (for example Spotify, Rhythmbox, and others).

## Screenshots

### Normal Mode

![Now Playing normal mode](docs/images/normal-mode.png)

### Minimal Mode

![Now Playing minimal mode](docs/images/minimal-mode.png)

## Requirements

For elementary OS/Ubuntu builds:

- `meson`
- `ninja-build`
- `valac`
- `libgtk-4-dev`
- `libadwaita-1-dev`
- `libgranite-7-dev`
- `libsoup-3.0-dev`
- `libx11-dev`
- `libwayland-dev`

Install dependencies:

```bash
sudo apt update
sudo apt install -y \
  meson ninja-build valac \
  libgtk-4-dev libadwaita-1-dev libgranite-7-dev \
  libsoup-3.0-dev libx11-dev libwayland-dev
```

## Step-By-Step Installation (Recommended, User-Local)

### 1. Clone the repository

```bash
git clone https://github.com/elementary/dock.git
cd dock
```

If you already cloned it:

```bash
git pull
```

### 2. Configure build directory

```bash
meson setup build --prefix=/usr
```

If `build` already exists:

```bash
meson setup build --reconfigure --prefix=/usr
```

### 3. Build

```bash
ninja -C build
```

### 4. Install this build only for your user (recommended)

This avoids touching system binaries and keeps an automatic backup:

```bash
set -euo pipefail
mkdir -p "$HOME/.local/bin" "$HOME/.local/bin/backups"

if [ -f "$HOME/.local/bin/io.elementary.dock" ]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$HOME/.local/bin/io.elementary.dock" \
    "$HOME/.local/bin/backups/io.elementary.dock.$ts"
fi

install -m 0755 build/src/io.elementary.dock "$HOME/.local/bin/io.elementary.dock"
```

### 5. Restart the dock

```bash
pkill -f '^io.elementary.dock$' || true
```

The process should auto-start again.

### 6. Verify that your local binary is being used

```bash
which io.elementary.dock
```

Expected output:

```text
/home/your-user/.local/bin/io.elementary.dock
```

## Global Installation (Optional)

If you want to install system-wide:

```bash
sudo ninja -C build install
pkill -f '^io.elementary.dock$' || true
```

Note: this overwrites the package-installed binary and may be reverted by system updates.

## Using Now Playing

### Normal Mode

- Shown as a full card in the dock.
- Album-art background with dark overlay for text readability.
- Inline controls (`previous`, `play/pause`, `next`).

### Minimal Mode

- Shows only square cover art at icon size.
- Hover opens tooltip with track info and controls.
- To enable or disable it: right click on Now Playing and toggle `Minimal Mode`.

### Behavior

- If no compatible media player is active, Now Playing hides itself.
- If the player closes, the item disappears automatically.

## Restore Original Dock

### Option A: remove local override

```bash
rm -f "$HOME/.local/bin/io.elementary.dock"
pkill -f '^io.elementary.dock$' || true
```

### Option B: restore latest local backup

```bash
latest_backup="$(ls -1t "$HOME/.local/bin/backups"/io.elementary.dock.* 2>/dev/null | head -n1)"
if [ -n "${latest_backup:-}" ]; then
  cp -a "$latest_backup" "$HOME/.local/bin/io.elementary.dock"
  pkill -f '^io.elementary.dock$' || true
fi
```

## Development

Build after changes:

```bash
ninja -C build
```

Run tests (if your environment includes them):

```bash
ninja -C build test
```

Lint (same as CI):

```bash
io.elementary.vala-lint -d .
```

## Relevant Project Structure

- `src/MediaSystem/NowPlayingItem.vala`: Now Playing UI and behavior.
- `src/MediaSystem/MediaMonitor.vala`: MPRIS integration and playback state.
- `src/ItemManager.vala`: item integration in dock layout.
- `data/Application.css`: dock and widget styles.
- `data/dock.gschema.xml`: settings keys (includes minimal mode).

## License

Distributed under **GPL-3.0**. See [LICENSE](LICENSE).
