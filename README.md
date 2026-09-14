# Mullion

Window controls for [Omarchy](https://omarchy.org), in the style you choose (macOS traffic lights or Windows 11 caption
buttons), with drag-to-edge
snapping, split screen, edge resize, and a minimize you can actually find
again.

![traffic lights](assets/titlebar.png)

## What you get

- **Traffic lights on every window**: red closes, yellow minimizes, green
  zooms, carrying macOS's own marks: ✕, −, and the diagonal expand arrows that
  replaced the old "+" in Yosemite. Left-aligned and 12px, like macOS.
- **Drag the title bar** to move a window; **double-click** it to zoom.
- **Drag any edge or corner** to resize, with no modifier key held.
- **Minimize that is visible**: minimized windows become clickable chips in
  the bar instead of vanishing. Click a chip to bring the window back.
- **Split screen on the arrow keys**, the same ones Windows uses. `SUPER + ←`
  takes the left half; follow it with `SUPER + ↑` and the window becomes the
  top-left quarter, so four apps tile one workspace with two presses each.
  Geometry comes from the real monitor and the bar's reserved area, so halves
  meet with no gap at any resolution, scale, or bar position.
- **Drag to an edge to snap it**, with a live translucent preview of where the
  window will land. Windows calls this Aero Snap. Edges give halves, the top
  edge fills the screen, and corners give quarters, so four windows tile a
  workspace by dragging alone. The preview rectangle is computed by the same
  code that performs the snap, so it can never show you the wrong target.
- **Magnetic dragging**: a dragged window also sticks to screen edges and to
  other windows as it gets close, so things line up without pixel-hunting.
- **Floating windows** by default, centered on open, remembering their size.
- **Follows your theme**: the title bar and the focused-window glow are tinted
  from the active Omarchy theme's colors, and retrack when you switch themes.

## Install

```bash
omarchy plugin add https://github.com/hr1ddh0/omarchy-mullion.git --enable
```

That adds the bar widget. `omarchy plugin add` never runs code from a plugin
(by design), so the widget lands showing a **setup** icon. Click it once and it
installs the rest in a visible terminal: the title-bar plugin built against
your exact Hyprland, the snapping helpers, and the Hyprland config.

Prefer to do it by hand, or not use the marketplace at all:

```bash
git clone https://github.com/hr1ddh0/omarchy-mullion.git
cd omarchy-mullion
./install.sh
```

Either way `install.sh` is the same script, it keeps a timestamped backup of
`hyprland.lua`, and it leaves an existing settings file alone so an upgrade
never discards your tuning.

## What this installs, and what it touches

This is a bar widget that sets up a window-management layer, so it changes more
than a bar widget usually does. All of it is listed here, and none of it happens
when you add the plugin: `omarchy plugin add` only clones files. Everything
below runs when **you** click the setup icon or run `./install.sh`, in a visible
terminal.

**No sudo or pkexec is required, and it never asks for a password.** Everything lands in your
own home directory.

| What | Where | Why |
| --- | --- | --- |
| Builds **hyprbars** from source | `~/.local/share/hyprland/plugins/hyprbars.so` | Hyprland draws no title bars; this is the only way to get them. Cloned from [hyprwm/hyprland-plugins](https://github.com/hyprwm/hyprland-plugins) at an exact commit pinned in `rebuild-hyprbars` for your Hyprland version, checked against the digests in `patches/SOURCES.sha256`, then compiled locally. Nothing unpinned is ever built. |
| Applies 4 local patches to that source | build directory only | Centres the button glyphs, gives them room, mirrors one, and hooks title-bar drags. All four must apply or the build stops; see [Supply chain](#supply-chain). |
| Five commands | `~/.local/bin/` | `mullion-set`, `mullion-snap`, `mullion-drag-snap`, `rebuild-hyprbars`, `use-system-titlebars` |
| One Hyprland config file | `~/.config/hypr/mullion.lua` | The window rules, bindings and title-bar setup |
| Two lines in `hyprland.lua` | `~/.config/hypr/hyprland.lua` | Loads the above. A timestamped backup is written first. |
| A block in the theme template | `~/.config/omarchy/themed/hyprland.lua.tpl` | So borders and the title bar follow your theme |
| Settings | `~/.config/omarchy/mullion.conf` | Left alone if it already exists |
| Installs **omarchy-minimize** | `~/.config/omarchy/plugins/` | Minimised windows become bar chips. A separate plugin by Mike Gardner, not vendored, fetched at the exact commit pinned in `install.sh` and validated by Omarchy's own plugin validator before it is enabled. |
| Changes GTK's window-button layout | `gsettings` + `~/.config/gtk-{3,4}.0/settings.ini` | Otherwise GNOME apps draw a second close button beside the title bar's. Reversible from the settings panel. |
| Sets "use system title bar" | Chromium/Chrome/Brave/Edge/Vivaldi/Firefox profiles | Same reason. Backs each file up, refuses while the browser is running, reversible. |

`./uninstall.sh` reverses all of it, restores the window buttons it hid, and
leaves your settings file in place.

## Supply chain

This plugin fetches code from the internet and compiles it, so what it will and
will not run is worth stating exactly.

**Everything fetched is pinned.** Two things are downloaded, each at an exact
commit written into this repository, never at a branch:

| Input | Pinned to | Anchored by |
| --- | --- | --- |
| `hyprwm/hyprland-plugins` (hyprbars) | `7644cec`, in `bin/rebuild-hyprbars` | Must be the commit upstream's `v0.56.0` tag points at, or the build stops |
| `gardnmi/omarchy-minimize` | `5c29836`, in `install.sh` | Must pass Omarchy's `omarchy-plugin-validate` and declare the expected plugin id |

**The compiled source is attested.** `patches/SOURCES.sha256` records a SHA-256
for every file the build touches, twice: as upstream ships it, and again after
Mullion's four patches are applied. `rebuild-hyprbars` checks both. The commit
fixes what is fetched, the first set of digests proves the fetch was not
tampered with, the patches are deterministic text substitutions, and the second
set proves the exact bytes handed to the compiler are the ones this release was
reviewed with. Regenerate them with `./patches/verify-pins regenerate <commit>`.

**Patches fail closed.** All four must apply. They used to be skipped with a
note when upstream drifted, which made sense when the source floated; against a
pinned commit a mismatch means the tree is not what we think it is, so the build
stops instead. Nothing is replaced when it does: your existing title bars keep
working, and `hyprland.lua` loads the plugin inside a `pcall`, so a failed or
missing build can never block login.

**The build environment is controlled.** The compiler runs under `env -i` with
a fixed search path, so an inherited `CXXFLAGS`, `LD_PRELOAD` or
`PKG_CONFIG_PATH` cannot reach into the compile or redirect which Hyprland
headers are used.

**The result is recorded.** A Hyprland plugin is compiled here, against this
machine's Hyprland, so no publisher can hand you a digest for the binary you end
up with. Instead every input that determined it is written to
`~/.local/share/mullion/build-record.json`: both commits, the release tag, the
compiler version, the header version, and the SHA-256 of the `.so` that was
installed.

**Executables are not resolved from `$PATH`.** These helpers run from the
compositor, from a bar widget and from an installer, none of which control the
environment they inherit. Every external command is resolved to an absolute path
in a root-owned, non-world-writable system directory; Mullion's own commands are
required to be owned by you and not symlinks. The Hyprland bindings and the
`hyprbars` hooks call these by absolute path too.

**Writes are descriptor-safe and atomic.** Every file this plugin creates or
edits, including other applications' settings, is written through a directory
descriptor whose ownership was verified and then held, opened without following
links, and put in place with a rename. A component swapped for a symlink
between the check and the write cannot redirect it, and no reader ever sees a
half-written config. Anything derived from a user argument, an environment
variable or a settings file is validated before it becomes part of a path or a
dispatched command.

One interaction worth knowing: `omarchy plugin update` fast-forwards a plugin to
its remote's latest commit, so running it on `io.github.gardnmi.window-shelf`
moves that dependency off the pin recorded here. Re-running `./install.sh` does
not undo that; remove the plugin first if you want the pin back.

## Settings

Click the Mullion icon in the bar. Everything is live: a change applies as you
make it, no restart.

| | |
| --- | --- |
| **Window controls** | macOS traffic lights, Windows 11 caption buttons, or none |
| **Title bar** | button size, bar height, glyphs always visible or on hover |
| **Window** | corner rounding, border width, open floating, drop shadow |
| **Snapping** | drag-to-edge on/off, edge sensitivity |
| **Other applications** | hide the window buttons they draw themselves |

Snapping, split screen and edge-resize behave identically whichever window
style you pick; only the controls, title alignment and shadow change.

The panel is built entirely from the shell's theme tokens, so it restyles
itself when you change Omarchy themes and follows your font size without being
configured.

It is a plain file underneath, so the terminal works too:

```bash
mullion-set rounding=14 shadow=false
mullion-set window_style=windows
mullion-set --list
```

Both write `~/.config/omarchy/mullion.conf`, which the Hyprland config and the
snap helper read directly, so the panel and the file cannot drift apart.

## Browsers and apps that draw their own buttons

Chromium-family browsers, GTK/GNOME apps and Firefox all draw their own window
frame by default, so alongside this plugin's controls you get a second,
redundant close button. `use-system-titlebars` turns that off across all three
families, and the **Other applications** toggle drives it either way.

The GTK setting is a shared one, so it covers every header-bar app at once, 
including ones neither of us thought to name.

It refuses to touch a profile whose browser is running, because Chromium
rewrites its preferences on exit and would silently undo the change:

```bash
use-system-titlebars           # hide them
use-system-titlebars --revert  # hand them back
use-system-titlebars --check   # report only
```

## Requirements

- Omarchy 4.x with the Quickshell shell (Quickshell >= 0.3.0)
- Hyprland in **Lua** configuration mode
- `g++`, `git`, `pkg-config` for building the title-bar plugin

## Keys

| Key | Action |
| --- | --- |
| `SUPER + ←/→/↑/↓` | Snap to that half; press twice across axes for a quarter |
| `SUPER + \` | Snap to the full screen |
| `SUPER + SHIFT + \` | Center the window |
| `SUPER + SHIFT + CTRL + ←/→/↑/↓` | Move focus between windows |
| `SUPER + M` | Minimize the focused window to the shelf |
| `SUPER + T` | Tile the focused window (float is the default here) |
| `SUPER + W` | Close the focused window |

## After a Hyprland update

Hyprland plugins are compiled against one exact Hyprland build, so an update
that bumps Hyprland makes the title bars stop appearing. Nothing else breaks and
login is never blocked; the bar icon switches to its rebuild state.

Each Mullion release pins the exact hyprland-plugins commit that pairs with the
Hyprland versions it supports (currently 0.56.0 to 0.56.2), records a digest for
every source file it compiles, and never builds anything else. So after a
Hyprland update:

```bash
omarchy plugin update hriddho.mullion   # picks up the pin for the new Hyprland
rebuild-hyprbars
```

If this release has no pin for your Hyprland yet, `rebuild-hyprbars` says so
and stops rather than building unreviewed code.
## A note on `hyprctl dispatch`

Omarchy configures Hyprland in Lua, so `hyprctl dispatch` takes a Lua
expression. The old form fails **silently**: a button wired that way looks
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

## Patches to hyprbars

Four build-time patches, applied to the pinned source before it is compiled.
All four must apply: see [Supply chain](#supply-chain) for why a mismatch stops
the build rather than being skipped.

hyprbars draws each coloured dot into a box it rounds to whole pixels, but
positions the glyph from the same arithmetic *without* rounding. At a
macOS-sized 12px dot that lands the glyph about a pixel left of centre, which
is plainly visible.

`patches/center-button-icons.py` centres the glyph inside the very same rounded
box the circle is drawn into.

`patches/drag-snap-hooks.py` calls `mullion-drag-snap` when hyprbars starts and
ends a title-bar drag, which is the only way to know about the drag people
actually perform.

`patches/mirror-button-icons.py` adds an optional `mirror` field to
`add_button`. macOS runs the green button's arrows on the NW-SE diagonal;
Nerd Font's `arrow-expand` runs NE-SW, no installed font carries the mirrored
twin, and Pango markup is unavailable so it cannot be composed. The patch draws
the glyph with its U coordinates swapped, producing exactly the missing icon.
It defaults to off, so buttons that don't ask for it are untouched.

`patches/icon-render-room.py` fixes two more: the glyph was drawn at
`size * 0.62`, leaving 7px on a macOS-sized dot (small enough that thin
strokes vanish), and the text was laid out with `maxWidth` equal to the dot,
truncating anything wider. It raises the scale slightly and lets the layout use
the room it needs.

## Staying clear of the bar

hyprbars always reserves its height **above** a window (`info.reserved` is
hardcoded), so a window placed flush with the top of the usable area slides its
title bar underneath the Omarchy bar. Hyprland offers no rule that clamps this.

Every snap therefore reserves the title bar's height, reading it live from
`plugin:hyprbars:bar_height` so it stays correct if you restyle the bar, and a
freely dragged window is nudged back down on release. Window and title bar
together fill the region exactly, with nothing tucked behind the bar.

## How drag-snapping works

Hyprland exposes no drag events, so drags are picked up from two places:

- **Dragging the title bar**: hyprbars listens to pointer events itself and
  moves the window directly, so no Hyprland binding ever sees that drag.
  `patches/drag-snap-hooks.py` calls out from the two points hyprbars already
  knows about, where it begins and ends a drag.
- **`SUPER` + drag**: bound on press and release. Both bindings are
  **non-consuming**, so Omarchy's own move binding still runs and dragging
  behaves exactly as it did before.

While the button is held, a watcher follows the cursor over Hyprland's command
socket, 0.064 ms a read, so 60 Hz costs nothing, and only for as long as you
are actually dragging. A drag shorter than 24 px is ignored, so a plain
`SUPER`+click near an edge never rearranges anything.

Every frame is arithmetic and one socket read: **0.076 ms**, against a 16.7 ms
budget at 60 Hz. The geometry is imported from `mullion-snap` rather than shelled
out to, so one source of truth is kept without paying 23 ms of interpreter
start per region change, and the overlay call is fire-and-forget rather than
waiting 21 ms on a reply. Overlay updates are floored at 50 ms apart so a fast
sweep across corners cannot spawn a burst of IPC processes, with a trailing
send guaranteeing the final region is the one drawn.

A drag snaps to the edge you dropped on, exactly. Composition into quarters
belongs to the arrow keys, where a second direction refines the first.

## What the bar widget does

The title bars are drawn by a **compiled** Hyprland plugin, which is tied to
the exact Hyprland build it was compiled against. An update that bumps
Hyprland makes the bars silently stop appearing. Nothing errors; they are just
gone, and the reason is not obvious.

The Mullion widget watches for exactly that. It stays hidden while everything
works, and shows a single glyph with a one-click fix when it doesn't.

## Built on

This project is the integration layer. The heavy lifting belongs to:

- **[hyprbars](https://github.com/hyprwm/hyprland-plugins)** by Vaxry
  (BSD-3-Clause), which draws the title bars. Built from the commit that
  `hyprpm.toml` pins to your Hyprland version.
- **[omarchy-minimize](https://github.com/gardnmi/omarchy-minimize)** by Mike
  Gardner (MIT), which provides the bar chips for minimized windows. Installed as a
  dependency, not vendored.

Neither is redistributed here; the installer fetches both from their own
sources, each at an exact pinned commit. See [Supply chain](#supply-chain).

## License

MIT. See [LICENSE](LICENSE).
