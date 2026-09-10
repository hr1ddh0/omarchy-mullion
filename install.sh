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
install -m755 "$HERE/bin/rebuild-hyprbars" "$HOME/.local/bin/rebuild-hyprbars"
"$HOME/.local/bin/rebuild-hyprbars"

say "Installing the window-shelf bar widget (minimize)"
if omarchy plugin list 2>/dev/null | grep -q "io.github.gardnmi.window-shelf"; then
  echo "Already installed."
else
  omarchy plugin add https://github.com/gardnmi/omarchy-minimize.git --enable --yes
fi

say "Installing the Hyprland config"
cp "$HERE/config/macos-windows.lua" "$HOME/.config/hypr/macos-windows.lua"

HYPR="$HOME/.config/hypr/hyprland.lua"
cp "$HYPR" "$HYPR.bak.$(date +%s)"

if ! grep -q "hyprbars.so" "$HYPR"; then
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
if anchor not in s:
    sys.exit("could not find require(\"default.hypr.omarchy\") in hyprland.lua")
s = s.replace(anchor, block, 1)
if 'require("hypr.macos-windows")' not in s:
    s = s.replace('require("hypr.looknfeel")',
                  'require("hypr.looknfeel")\nrequire("hypr.macos-windows")', 1)
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

say "Reloading Hyprland"
hyprctl reload >/dev/null 2>&1 || true
sleep 1
hyprctl reload >/dev/null 2>&1 || true   # second pass: plugin Lua API appears here
hyprctl configerrors || true

say "Done. Traffic lights on every window; minimized windows appear as chips in the bar."
