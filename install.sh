#!/bin/bash
# Install macOS-style window handling for Omarchy.
#
# Builds the hyprbars title-bar plugin against your exact Hyprland build,
# installs the window-shelf bar widget for minimize, and writes the Hyprland
# Lua config that wires them into macOS behavior.
set -euo pipefail

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -d $HOME/.config/hypr ]] || die "~/.config/hypr not found. This targets Omarchy."
command -v hyprctl >/dev/null || die "hyprctl not found."
command -v g++ >/dev/null || die "g++ not found. Install base-devel."

say "Building the hyprbars title-bar plugin"
mkdir -p "$HOME/.local/bin"
install -m755 "$HERE/bin/rebuild-hyprbars" "$HOME/.local/bin/rebuild-hyprbars"
install -m755 "$HERE/bin/mullion-snap" "$HOME/.local/bin/mullion-snap"
install -m755 "$HERE/bin/mullion-drag-snap" "$HOME/.local/bin/mullion-drag-snap"
install -m755 "$HERE/bin/use-system-titlebars" "$HOME/.local/bin/use-system-titlebars"
install -m755 "$HERE/bin/mullion-set" "$HOME/.local/bin/mullion-set"

# Default settings, only if the user has none: an upgrade must never discard
# what they have tuned.
mkdir -p "$HOME/.config/omarchy"
if [[ ! -f $HOME/.config/omarchy/mullion.conf ]]; then
  cp "$HERE/config/mullion.conf" "$HOME/.config/omarchy/mullion.conf"
  echo "Wrote default settings to ~/.config/omarchy/mullion.conf"
else
  echo "Keeping your existing ~/.config/omarchy/mullion.conf"
fi

# Patches applied to hyprbars at build time, kept where rebuild-hyprbars looks.
mkdir -p "$HOME/.local/share/mullion/patches"
if compgen -G "$HERE/patches/*.py" >/dev/null; then
  install -m755 "$HERE"/patches/*.py "$HOME/.local/share/mullion/patches/"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: ~/.local/bin is not on your PATH; the snap keybindings need it." ;;
esac
"$HOME/.local/bin/rebuild-hyprbars"

say "Installing the bar widget and settings panel"
# Installed from the marketplace, this already runs from inside the plugin
# directory. Cloned and run by hand, it does not, and without this step there
# is no bar icon and no settings panel at all.
PLUGIN_ID=$(python3 -c "import json;print(json.load(open('$HERE/manifest.json'))['id'])")
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
if [[ $(cd "$HERE" && pwd) == "$PLUGIN_DIR" ]]; then
  echo "Already running from the plugin directory."
else
  mkdir -p "$PLUGIN_DIR"
  for item in manifest.json BarWidget.qml install.sh uninstall.sh README.md LICENSE bin config patches assets; do
    [[ -e $HERE/$item ]] && cp -r "$HERE/$item" "$PLUGIN_DIR/"
  done
  rm -rf "$PLUGIN_DIR/bin/__pycache__"
  echo "Installed to $PLUGIN_DIR"
fi
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 1
omarchy plugin enable "$PLUGIN_ID" --section left >/dev/null 2>&1 || true

say "Installing the window-shelf bar widget (minimize)"
if omarchy plugin list 2>/dev/null | grep -q "io.github.gardnmi.window-shelf"; then
  echo "Already installed."
else
  omarchy plugin add https://github.com/gardnmi/omarchy-minimize.git --enable --yes
fi

say "Installing the Hyprland config"
cp "$HERE/config/mullion.lua" "$HOME/.config/hypr/mullion.lua"

HYPR="$HOME/.config/hypr/hyprland.lua"
cp "$HYPR" "$HYPR.bak.$(date +%s)"

# The two edits are checked separately: a config that has one but not the
# other (a partial uninstall, a hand-edit) must get the missing half rather
# than be declared already done.
if ! grep -q "hyprbars.so" "$HYPR" || ! grep -q 'require("hypr.mullion")' "$HYPR"; then
  python3 - "$HYPR" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = 'require("default.hypr.omarchy")'
block = '''-- macOS-style title bars. Loaded before Omarchy's defaults so the theme can
-- color the bar. Guarded so a version mismatch can never block login.
pcall(function()
  hl.plugin.load(os.getenv("HOME") .. "/.local/share/hyprland/plugins/hyprbars.so")
end)

''' + anchor
if "hyprbars.so" not in s:
    if anchor not in s:
        sys.exit("could not find require(\"default.hypr.omarchy\") in hyprland.lua")
    s = s.replace(anchor, block, 1)
if 'require("hypr.mullion")' not in s:
    s = s.replace('require("hypr.looknfeel")',
                  'require("hypr.looknfeel")\nrequire("hypr.mullion")', 1)
open(p, "w").write(s)
PY
  echo "Patched hyprland.lua (backup written alongside it)."
else
  echo "hyprland.lua already patched; leaving it alone."
fi

say "Adding theme-tracked title-bar colors"
mkdir -p "$HOME/.config/omarchy/themed"
TPL="$HOME/.config/omarchy/themed/hyprland.lua.tpl"
if [[ ! -f $TPL ]]; then
  cp "${OMARCHY_PATH:-/usr/share/omarchy}/default/themed/hyprland.lua.tpl" "$TPL"
fi
if ! grep -q "hyprbars" "$TPL"; then
  cat "$HERE/config/themed-hyprland.lua.tpl.snippet" >> "$TPL"
  omarchy theme set "$(omarchy theme current)" >/dev/null 2>&1 || true
fi

say "Checking for browsers that draw their own window buttons"
# A browser drawing its own frame gives you two sets of controls: ours on the
# title bar, and its close button at the right of the tab strip.
"$HOME/.local/bin/use-system-titlebars" || true

say "Reloading Hyprland"
# The plugin's Lua API only appears on the config parse AFTER the one that
# loaded it, so the buttons register on this second pass.
hyprctl reload >/dev/null 2>&1 || true
sleep 1
hyprctl reload >/dev/null 2>&1 || true
sleep 1
hyprctl configerrors || true

# The drag preview talks to an IpcHandler inside the bar widget, and those
# only bind when the shell loads the plugin; a hot rescan is not enough.
say "Restarting the shell so the snap preview registers"
omarchy restart shell >/dev/null 2>&1 || true
sleep 4

if hyprctl plugin list 2>/dev/null | grep -q hyprbars; then
  say "Done. Traffic lights on every window; minimized windows appear as chips in the bar."
else
  say "Installed, but the title-bar plugin is not loaded yet. Log out and back in."
fi
