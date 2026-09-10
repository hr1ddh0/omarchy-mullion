# Omarchy macOS Windows

macOS-style window handling for [Omarchy](https://omarchy.org): traffic-light
title bars, drag-to-move, edge resize, and a minimize that you can actually
find again.

![traffic lights](assets/titlebar.png)

## What you get

- **Traffic lights on every window** — red closes, yellow minimizes, green
  zooms. Left-aligned, with the glyphs appearing on hover, like macOS.
- **Drag the title bar** to move a window; **double-click** it to zoom.
- **Drag any edge or corner** to resize, with no modifier key held.
- **Minimize that is visible** — minimized windows become clickable chips in
  the bar instead of vanishing. Click a chip to bring the window back.
- **Floating windows** by default, centered on open, remembering their size.
- **Follows your theme** — the title bar and the focused-window glow are tinted
  from the active Omarchy theme's colors, and retrack when you switch themes.

## Install

```bash
git clone https://github.com/<you>/omarchy-macos-windows.git
cd omarchy-macos-windows
./install.sh
```

The installer builds the title-bar plugin against your exact Hyprland build,
installs the minimize widget, patches `~/.config/hypr/hyprland.lua` (keeping a
timestamped backup), and reloads.

## Requirements

- Omarchy 4.x with the Quickshell shell (Quickshell >= 0.3.0)
- Hyprland in **Lua** configuration mode
- `g++`, `git`, `pkg-config` for building the title-bar plugin

## Keys

| Key | Action |
| --- | --- |
| `SUPER + M` | Minimize the focused window to the shelf |
| `SUPER + T` | Tile the focused window (float is the default here) |
| `SUPER + W` | Close the focused window |

## After a Hyprland update

Hyprland plugins are compiled against one exact Hyprland build, so an update
that bumps Hyprland makes the title bars stop appearing. Nothing else breaks
and login is never blocked. Get them back with:

```bash
rebuild-hyprbars
```

## A note on `hyprctl dispatch`

Omarchy configures Hyprland in Lua, so `hyprctl dispatch` takes a Lua
expression. The old form fails **silently** — a button wired that way looks
fine and does nothing:

```bash
hyprctl dispatch fullscreen 1                                   # no-op
hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })'   # works
```

## Uninstall

```bash
./uninstall.sh
```

Minimized windows are restored to your current workspace first.

## Built on

This project is the integration layer. The heavy lifting belongs to:

- **[hyprbars](https://github.com/hyprwm/hyprland-plugins)** by Vaxry
  (BSD-3-Clause) — draws the title bars. Built from the commit that
  `hyprpm.toml` pins to your Hyprland version.
- **[omarchy-minimize](https://github.com/gardnmi/omarchy-minimize)** by Mike
  Gardner (MIT) — the bar chips for minimized windows. Installed as a
  dependency, not vendored.

Neither is redistributed here; the installer fetches both from their own
sources.

## License

MIT — see [LICENSE](LICENSE).
