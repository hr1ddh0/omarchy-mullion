#!/bin/bash
# Remove macOS-style window handling. Leaves your theme untouched.
set -euo pipefail
say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }

say "Restoring any minimized windows first"
WS=$(hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
hyprctl clients -j | python3 -c "
import json,subprocess,sys
for c in json.load(sys.stdin):
    if 'omarchy-minimized' in c['workspace']['name']:
        subprocess.run(['hyprctl','dispatch',
          'hl.dsp.window.move({ workspace = \"$WS\", window = \"address:%s\" })' % c['address']])
"

say "Removing config"
rm -f "$HOME/.config/hypr/macos-windows.lua"
sed -i '/require("hypr.macos-windows")/d' "$HOME/.config/hypr/hyprland.lua"
python3 - "$HOME/.config/hypr/hyprland.lua" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'-- macOS-style title bars.*?\npcall\(function\(\)\n.*?hyprbars\.so.*?\nend\)\n\n', '', s, flags=re.S)
open(p, "w").write(s)
PY

say "Removing the plugin binary"
rm -f "$HOME/.local/share/hyprland/plugins/hyprbars.so" \
      "$HOME/.local/bin/rebuild-hyprbars" \
      "$HOME/.local/bin/macos-snap"

echo
echo "Left in place (remove by hand if you want them gone):"
echo "  - the window-shelf widget:  omarchy plugin remove io.github.gardnmi.window-shelf"
echo "  - the hyprbars block appended to ~/.config/omarchy/themed/hyprland.lua.tpl"
hyprctl reload >/dev/null 2>&1 || true
say "Done."
