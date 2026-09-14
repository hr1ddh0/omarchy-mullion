#!/bin/bash
# Install macOS-style window handling for Omarchy.
#
# Builds the hyprbars title-bar plugin against your exact Hyprland build,
# installs the window-shelf bar widget for minimize, and writes the Hyprland
# Lua config that wires them into macOS behavior.
#
# Everything fetched is pinned to an exact commit, every executable is resolved
# from a root-owned system directory rather than from $PATH, and every file
# this writes is placed through a verified directory descriptor and an atomic
# rename, so a link planted under one of these paths cannot redirect the write.
set -euo pipefail

# Trust root: this script was started through an absolute shebang, so /usr/bin
# is already trusted by virtue of running at all. Everything else resolves from
# there, and the inherited environment is stripped of anything that could
# redirect an interpreter, a library or a build.
export PATH=/usr/bin:/usr/local/bin:/usr/sbin
unset LD_PRELOAD LD_LIBRARY_PATH PYTHONPATH PYTHONHOME BASH_ENV ENV IFS \
      CXXFLAGS LDFLAGS PKG_CONFIG_PATH 2>/dev/null || true

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

tool() {
  local name=$1 dir path owner mode
  for dir in /usr/bin /usr/local/bin /usr/sbin /usr/local/sbin; do
    path="$dir/$name"
    [[ -f $path && -x $path ]] || continue
    read -r owner mode < <(/usr/bin/stat -Lc '%u %a' "$path" 2>/dev/null) || continue
    [[ $owner == 0 ]] || continue
    (( (8#$mode & 8#022) == 0 )) || continue
    printf '%s\n' "$path"
    return 0
  done
  die "$name was not found in a trusted system directory (/usr/bin, /usr/local/bin, /usr/sbin)."
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/bin/mullionlib.py"
[[ -f $LIB ]] || die "bin/mullionlib.py is missing from this checkout."

PYTHON=$(tool python3)
GIT=$(tool git)
HYPRCTL=$(tool hyprctl)
OMARCHY=$(tool omarchy)
OMARCHY_SHELL=$(tool omarchy-shell)

[[ -d $HOME/.config/hypr ]] || die "~/.config/hypr not found. This targets Omarchy."
tool g++ >/dev/null || die "g++ not found. Install base-devel."

# mullionlib does every file placement: verified directory descriptor, no
# following links, atomic rename. Wrapped so the call sites stay readable.
mfs() { "$PYTHON" "$LIB" "$@"; }

# The minimize widget Mullion depends on, pinned. `omarchy plugin add` clones a
# repository's default branch as it stands today, which is exactly the
# unreviewable input this avoids: the commit below is the one this release was
# tested against, and the installer refuses anything else.
MINIMIZE_URL="https://github.com/gardnmi/omarchy-minimize.git"
MINIMIZE_COMMIT="5c29836d0c21e852477874dc73bb85976781dfa7"
MINIMIZE_ID="io.github.gardnmi.window-shelf"

cat <<EOF

Mullion will make these changes, all inside your home directory:

  * build the hyprbars title-bar plugin from hyprwm/hyprland-plugins
    into ~/.local/share/hyprland/plugins/
    (pinned to an exact upstream release commit, with every source file
     checked against a recorded digest before it is compiled)
  * install five commands into ~/.local/bin/
  * write ~/.config/hypr/mullion.lua and add two lines to hyprland.lua
    (a timestamped backup of hyprland.lua is kept)
  * add a block to ~/.config/omarchy/themed/hyprland.lua.tpl
  * create ~/.config/omarchy/mullion.conf if you have none
  * add the omarchy-minimize plugin for minimised-window chips,
    pinned to commit ${MINIMIZE_COMMIT:0:12}
  * hide the close buttons that GTK apps and Chromium-family browsers
    draw themselves (reversible from the settings panel)

No sudo, and nothing outside your home directory.
./uninstall.sh reverses all of it.

EOF

if [[ ${1:-} == "--yes" ]]; then
  echo "Proceeding (--yes)."
elif [[ -t 0 ]]; then
  read -r -p "Continue? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { echo "Nothing was changed."; exit 0; }
else
  echo "Not running interactively, so nothing was changed."
  echo "Run it in a terminal, or pass --yes to agree up front."
  exit 1
fi

STAMP=$(date +%s)

# ---------------------------------------------------------------------------
say "Installing Mullion's commands"
for command in rebuild-hyprbars mullion-snap mullion-drag-snap \
               use-system-titlebars mullion-set; do
  mfs install-file "$HERE/bin/$command" "$HOME/.local/bin" "$command" 755
done
# The shared safety library the commands import, and the patch set plus its
# digest manifest that rebuild-hyprbars checks every build against.
mfs install-file "$HERE/bin/mullionlib.py" "$HOME/.local/share/mullion/lib" mullionlib.py 644
for patch in "$HERE"/patches/*.py; do
  mfs install-file "$patch" "$HOME/.local/share/mullion/patches" "$(basename "$patch")" 644
done
mfs install-file "$HERE/patches/SOURCES.sha256" "$HOME/.local/share/mullion/patches" SOURCES.sha256 644
mfs install-file "$HERE/patches/verify-pins" "$HOME/.local/share/mullion/patches" verify-pins 755

# Default settings, only if the user has none: an upgrade must never discard
# what they have tuned.
if [[ $(mfs install-default "$HERE/config/mullion.conf" "$HOME/.config/omarchy" mullion.conf) == wrote ]]; then
  echo "Wrote default settings to ~/.config/omarchy/mullion.conf"
else
  echo "Keeping your existing ~/.config/omarchy/mullion.conf"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: ~/.local/bin is not on your PATH; the snap keybindings use absolute paths, so they work regardless." ;;
esac

say "Building the hyprbars title-bar plugin"
"$HOME/.local/bin/rebuild-hyprbars"

# ---------------------------------------------------------------------------
say "Installing the bar widget and settings panel"
# Installed from the marketplace, this already runs from inside the plugin
# directory. Cloned and run by hand, it does not, and without this step there
# is no bar icon and no settings panel at all.
PLUGIN_ID=$(mfs json-field "$HERE/manifest.json" id)
PLUGIN_ID=$(mfs check-id "$PLUGIN_ID")
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

if [[ $HERE == "$PLUGIN_DIR" ]]; then
  echo "Already running from the plugin directory."
else
  # A copy that takes only regular files and real directories, so nothing in
  # the source tree can point the destination outside itself.
  copied=$(mfs copy-tree "$HERE" "$PLUGIN_DIR")
  echo "Installed $copied files to $PLUGIN_DIR"
fi
"$OMARCHY_SHELL" shell rescanPlugins >/dev/null 2>&1 || true
sleep 1
"$OMARCHY" plugin enable "$PLUGIN_ID" --section left >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
say "Installing the window-shelf bar widget (minimize)"
if "$OMARCHY" plugin list 2>/dev/null | grep -q "$MINIMIZE_ID"; then
  echo "Already installed."
else
  # Omarchy's own URL check first, so a URL naming a git option or a transport
  # helper is refused before anything is fetched.
  /usr/bin/omarchy-git-url-check "$MINIMIZE_URL" || die "refusing $MINIMIZE_URL"

  STAGE="$PLUGINS_DIR/.mullion-dep.$$"
  rm -rf "$STAGE"
  mkdir -p "$PLUGINS_DIR"
  "$GIT" -c transfer.fsckobjects=true -c fetch.fsckobjects=true \
    clone --quiet --no-checkout -- "$MINIMIZE_URL" "$STAGE" \
    || { rm -rf "$STAGE"; die "could not fetch $MINIMIZE_URL"; }
  "$GIT" -C "$STAGE" checkout --quiet --detach "$MINIMIZE_COMMIT" \
    || { rm -rf "$STAGE"; die "pinned commit $MINIMIZE_COMMIT is not in $MINIMIZE_URL"; }

  GOT=$("$GIT" -C "$STAGE" rev-parse HEAD)
  [[ $GOT == "$MINIMIZE_COMMIT" ]] \
    || { rm -rf "$STAGE"; die "fetched $GOT but expected $MINIMIZE_COMMIT"; }

  # Omarchy's own manifest validation, the same gate `omarchy plugin add` uses.
  /usr/bin/omarchy-plugin-validate "$STAGE" \
    || { rm -rf "$STAGE"; die "the pinned omarchy-minimize failed Omarchy's plugin validation"; }

  # And the pin must actually be the plugin we meant to install.
  GOT_ID=$(mfs json-field "$STAGE/manifest.json" id)
  [[ $GOT_ID == "$MINIMIZE_ID" ]] \
    || { rm -rf "$STAGE"; die "pinned commit declares id '$GOT_ID', expected '$MINIMIZE_ID'"; }

  if [[ -e $PLUGINS_DIR/$GOT_ID || -L $PLUGINS_DIR/$GOT_ID ]]; then
    rm -rf "$STAGE"
    die "$PLUGINS_DIR/$GOT_ID already exists; remove it or install it yourself"
  fi
  mv -T "$STAGE" "$PLUGINS_DIR/$GOT_ID"
  echo "Installed $GOT_ID at ${MINIMIZE_COMMIT:0:12}"
  "$OMARCHY_SHELL" shell rescanPlugins >/dev/null 2>&1 || true
  sleep 1
  "$OMARCHY" plugin enable "$GOT_ID" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
say "Installing the Hyprland config"
mfs install-file "$HERE/config/mullion.lua" "$HOME/.config/hypr" mullion.lua 644

# Adds the two lines if they are absent, keeping a timestamped backup. The two
# edits are checked separately: a config that has one but not the other (a
# partial uninstall, a hand-edit) gets the missing half rather than being
# declared already done.
case "$(mfs patch-hyprland "$HOME/.config/hypr" hyprland.lua "$STAMP")" in
  patched) echo "Patched hyprland.lua (backup written alongside it)." ;;
  *)       echo "hyprland.lua already patched; leaving it alone." ;;
esac

# ---------------------------------------------------------------------------
say "Adding theme-tracked title-bar colors"
TPL_DIR="$HOME/.config/omarchy/themed"
if [[ ! -f $TPL_DIR/hyprland.lua.tpl ]]; then
  # Omarchy's own default, read from a root-owned directory.
  OMARCHY_DEFAULTS="${OMARCHY_PATH:-/usr/share/omarchy}/default/themed"
  [[ -d $OMARCHY_DEFAULTS ]] || die "could not find Omarchy's themed defaults at $OMARCHY_DEFAULTS"
  mfs install-file "$OMARCHY_DEFAULTS/hyprland.lua.tpl" "$TPL_DIR" hyprland.lua.tpl 644
fi
# Appended once, as a single atomic rewrite rather than a shell append that
# would follow a link and could leave a half-written block behind.
mfs append-once "$TPL_DIR" hyprland.lua.tpl hyprbars \
  "$HERE/config/themed-hyprland.lua.tpl.snippet" >/dev/null
"$OMARCHY" theme set "$("$OMARCHY" theme current)" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
say "Checking for browsers that draw their own window buttons"
# A browser drawing its own frame gives you two sets of controls: ours on the
# title bar, and its close button at the right of the tab strip.
"$HOME/.local/bin/use-system-titlebars" || true

say "Reloading Hyprland"
# The plugin's Lua API only appears on the config parse AFTER the one that
# loaded it, so the buttons register on this second pass.
"$HYPRCTL" reload >/dev/null 2>&1 || true
sleep 1
"$HYPRCTL" reload >/dev/null 2>&1 || true
sleep 1
"$HYPRCTL" configerrors || true

# The drag preview talks to an IpcHandler inside the bar widget, and those
# only bind when the shell loads the plugin; a hot rescan is not enough.
say "Restarting the shell so the snap preview registers"
"$OMARCHY" restart shell >/dev/null 2>&1 || true
sleep 4

if "$HYPRCTL" plugin list 2>/dev/null | grep -q hyprbars; then
  say "Done. Traffic lights on every window; minimized windows appear as chips in the bar."
else
  say "Installed, but the title-bar plugin is not loaded yet. Log out and back in."
fi
