# Cupertino

macOS-style windows for [Omarchy](https://omarchy.org) — traffic-light title
bars, drag to move, edge resize, half-screen snapping, and a minimize you can
actually find again.

![traffic lights](assets/titlebar.png)

## What you get

- **Traffic lights on every window** — red closes, yellow minimizes, green
  zooms. Left-aligned, with the glyphs appearing on hover, like macOS.
- **Drag the title bar** to move a window; **double-click** it to zoom.
- **Drag any edge or corner** to resize, with no modifier key held.
- **Minimize that is visible** — minimized windows become clickable chips in
  the bar instead of vanishing. Click a chip to bring the window back.
- **Split screen on the arrow keys**, the same ones Windows uses. `SUPER + ←`
  takes the left half; follow it with `SUPER + ↑` and the window becomes the
  top-left quarter, so four apps tile one workspace with two presses each.
  Geometry comes from the real monitor and the bar's reserved area, so halves
  meet with no gap at any resolution, scale, or bar position.
- **Drag to an edge to snap it**, with a live translucent preview of where the
  window will land — what Windows calls Aero Snap. Edges give halves, the top
  edge fills the screen, and corners give quarters, so four windows tile a
  workspace by dragging alone. The preview rectangle is computed by the same
  code that performs the snap, so it can never show you the wrong target.
- **Magnetic dragging** — a dragged window also sticks to screen edges and to
  other windows as it gets close, so things line up without pixel-hunting.
- **Floating windows** by default, centered on open, remembering their size.
- **Follows your theme** — the title bar and the focused-window glow are tinted
  from the active Omarchy theme's colors, and retrack when you switch themes.

## Install

```bash
git clone https://github.com/<you>/omarchy-cupertino.git
cd omarchy-cupertino
./install.sh
```

The bar widget half can also be installed straight from the marketplace:

```bash
omarchy plugin add https://github.com/<you>/omarchy-cupertino.git --enable
```

That gives you the health widget, which will then offer to run `install.sh`
for the title bars themselves.

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
| `SUPER + ←/→/↑/↓` | Snap to that half — press twice across axes for a quarter |
| `SUPER + \` | Snap to the full screen |
| `SUPER + SHIFT + \` | Center the window |
| `SUPER + SHIFT + CTRL + ←/→/↑/↓` | Move focus between windows |
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

## A patch to hyprbars

hyprbars draws each coloured dot into a box it rounds to whole pixels, but
positions the glyph from the same arithmetic *without* rounding. At a
macOS-sized 12px dot that lands the glyph about a pixel left of centre, which
is plainly visible.

`patches/center-button-icons.py` centres the glyph inside the very same rounded
box the circle is drawn into. `rebuild-hyprbars` applies it at build time, and
skips it with a note (rather than failing) if upstream ever changes that code,
so a future Hyprland release can never leave you without title bars over a
cosmetic fix.

## Staying clear of the bar

hyprbars always reserves its height **above** a window (`info.reserved` is
hardcoded), so a window placed flush with the top of the usable area slides its
title bar underneath the Omarchy bar. Hyprland offers no rule that clamps this.

Every snap therefore reserves the title bar's height, reading it live from
`plugin:hyprbars:bar_height` so it stays correct if you restyle the bar, and a
freely dragged window is nudged back down on release. Window and title bar
together fill the region exactly, with nothing tucked behind the bar.

## How drag-snapping works

Hyprland exposes no drag events, so the press and release of the very same
`SUPER` + left-drag that already moves a window mark the start and end of one.
Both bindings are **non-consuming**, so Omarchy's own move binding still runs
and dragging behaves exactly as it did before.

While the button is held, a watcher follows the cursor over Hyprland's command
socket — about 0.03 ms per read, so 60 Hz costs nothing, and only for as long
as you are actually dragging. It asks the bar widget to draw the preview, and
on release the window is snapped. A drag shorter than 24 px is ignored, so a
plain `SUPER`+click near an edge never rearranges anything.

## What the bar widget does

The title bars are drawn by a **compiled** Hyprland plugin, which is tied to
the exact Hyprland build it was compiled against. An update that bumps
Hyprland makes the bars silently stop appearing — nothing errors, they are just
gone, and the reason is not obvious.

The Cupertino widget watches for exactly that. It stays hidden while everything
works, and shows a single glyph with a one-click fix when it doesn't.

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
