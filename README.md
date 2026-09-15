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
own home directory. To make the title bar follow your theme it re-renders the current theme's
templates in Omarchy's headless mode, which changes no wallpaper, restarts nothing and writes no
system-wide browser policy.

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

This plugin fetches code from the internet, compiles a native Hyprland plugin,
and edits your compositor and application configuration, so what it will and
will not do is worth stating exactly.

### Fetched inputs are pinned and verified file by file

| Input | Pinned to | Verified by |
| --- | --- | --- |
| `hyprwm/hyprland-plugins` (hyprbars) | `7644cec`, in `bin/rebuild-hyprbars` | `patches/SOURCES.sha256`: every file in the source directory, `Makefile` included, before and after patching |
| `gardnmi/omarchy-minimize` | `5c29836`, in `install.sh` | `deps/omarchy-minimize.sha256`: every file of the plugin, plus Omarchy's own `omarchy-git-url-check` and `omarchy-plugin-validate` |

git runs with no user or system configuration (no URL rewrites, credential
helpers, filters or fsmonitor), https only, hooks disabled, replace refs
ignored, and every received object checked, and only ever on a repository the
script has just cloned itself. A changed byte, a missing file, an added file,
a link or a subdirectory stops the install. The pinned hyprbars commit must
also be what upstream's `v0.56.0` tag names; that is a consistency check, and
the commit plus the digests are what actually protect the build.

omarchy-minimize is installed without its git metadata, so `omarchy plugin
update` skips it and cannot move it off the reviewed version. An existing copy
is verified by its files, never by asking git, before anything else changes;
one that does not match is only replaced after you confirm, and your copy is
kept aside. The bar widget re-checks it on every health probe.

### The build is controlled and its result is recorded

- The installed Hyprland headers must be the same Hyprland commit that is
  running, or the build stops (an upgrade without a re-login would otherwise
  build for the wrong Hyprland).
- All four patches must apply; a mismatch stops the build rather than being
  skipped. Nothing is replaced when a build stops, and `hyprland.lua` loads the
  plugin inside a `pcall`, so a failed build can never block login.
- The compiler runs under `env -i` with `PATH=/usr/bin`, with nothing in
  `/usr/local/include` to shadow the packaged headers, and with upstream's
  `--no-gnu-unique`, so Hyprland can truly unload an old build. The result must
  have no GNU-unique symbols and no embedded library search path.
- A plugin compiled against your own Hyprland cannot come with a publisher's
  digest, so every input that determined it is written to
  `~/.local/share/mullion/build-record.json`: both commits, the header commit,
  the exact `gcc`, `binutils`, `hyprland` and library package versions, the
  build flags, the libraries it links, and the SHA-256 and inode of the
  installed `.so`. The digest is re-checked immediately before Hyprland loads
  it.
- The bar widget re-checks all of this on every probe: that the file on disk
  still matches the record, and that the image Hyprland actually has mapped
  (from `/proc`) is that very file rather than an older or replaced one. A
  mismatch is shown as a warning with a one-click rebuild.

The toolchain itself is your distribution's packaged compiler. It cannot be
pinned on a rolling distribution, and it has to match your installed Hyprland
anyway, so it is attested by recording exact package versions instead.

### Nothing is taken from the environment

These scripts run from the compositor, a bar widget and an installer, none of
which control the environment they inherit.

- The shell scripts start with `bash -p` and then re-execute themselves under
  `env -i` with an allowlisted, value-checked environment, unless their real
  environment (read from `/proc`) already is exactly that. Exported shell
  functions, `BASH_ENV`, `LD_PRELOAD`, `TMPDIR`, module search paths and
  everything else never reach Omarchy's tools, git, make or the compiler.
- The Python helpers start with `python3 -I`, and build every child's
  environment from the same allowlist.
- Executables are taken only from `/usr/bin`, and only when root owns both the
  directory and the file and nobody else can write to it.
- The home directory is read from the password database; `OMARCHY_PATH` is
  fixed to the packaged `/usr/share/omarchy`; the runtime directory must be
  `/run/user/<uid>` with mode 0700.
- An installed helper loads only the installed copy of its safety library, a
  checkout only its own, each required to be a regular file owned by you.
- The Hyprland bindings, title-bar buttons and compiled drag hooks call by
  absolute path; the drag hooks look your home directory up from the password
  database rather than trusting `$HOME`. The bar widget starts every process
  with a cleared, allowlisted environment and passes arguments as an array,
  shell-quoting each one for Omarchy's terminal launcher.

### Writes are descriptor-safe and atomic

Every config file, command, library, record and plugin file Mullion creates,
edits, renames or removes, including other applications' settings, goes
through `bin/mullionlib.py`. A path is walked from `/` one component at a
time: symlinks are resolved by the library itself so each link's owner is
checked (yours and root's are followed, anyone else's is refused, and a link
target containing `..` is refused), every directory is opened with
`O_NOFOLLOW` relative to its verified parent, its owner and permissions
checked, and its descriptor held. Files are written to a fresh `O_EXCL`
temporary beside the target and renamed into place, keeping the existing
file's permissions, with the original kept the first time a file is changed.
Directories are created, renamed and removed through the same descriptors,
recursively and without ever following a link. System defaults are read only
through directories and files root owns. Mullion's own library is executed
from bytes read and verified through a descriptor, never from a bytecode cache.

`hyprland.lua` is edited by whole uncommented lines and exact blocks only, and
every file the installer will edit is checked before it changes anything, so
it cannot stop half-applied; any write that fails stops the install. Settings
keys and values are checked against a schema, and window addresses, workspace
names, plugin ids and paths are validated before they reach a dispatch, a
config file or a command.

### What stays outside Mullion's control

Stated so nothing here is overclaimed:

- `git clone` writes by path, into a private `0700` staging directory that
  Mullion created through a verified descriptor and that nobody else can
  enter; the result is verified file by file before it is moved into place.
- The reload-once marker in `mullion.lua` is written by a shell redirect, into
  the owner-only `/run/user/<uid>` directory.
- Omarchy's floating-terminal launcher, which the bar widget uses so you can
  watch the install, runs with the session's environment; the widget hands it
  an allowlisted environment and a quoted absolute `bash -p` command, and
  Mullion's scripts clean their own environment before doing anything.
- At login, `hyprland.lua` loads the plugin file from your home directory
  without hashing it; the bar widget verifies it against the build record
  afterwards.
- omarchy-minimize is third-party code, pinned and reviewed; upstream, its
  widget calls `hyprctl` by name.

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
- `g++`, `make`, `git`, `pkg-config`, `readelf` from the Arch packages in `/usr/bin` for building the title-bar plugin

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
and stops rather than building unreviewed code. After `omarchy plugin update`,
the bar icon asks you to finish the update, which re-runs `install.sh` so the
new pins and digests are installed.
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
