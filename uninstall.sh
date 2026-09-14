#!/bin/bash
# Remove macOS-style window handling. Leaves your theme untouched.
#
# Every removal goes through the same verified-descriptor, no-follow path
# operations the installer uses, so a link planted under one of these names
# cannot turn a cleanup into a delete somewhere else.
set -euo pipefail

export PATH=/usr/bin:/usr/local/bin:/usr/sbin
unset LD_PRELOAD LD_LIBRARY_PATH PYTHONPATH PYTHONHOME BASH_ENV ENV IFS 2>/dev/null || true

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
  die "$name was not found in a trusted system directory."
}

PYTHON=$(tool python3)
HYPRCTL=$(tool hyprctl)

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=""
for candidate in "$HERE/bin/mullionlib.py" "$HOME/.local/share/mullion/lib/mullionlib.py"; do
  [[ -f $candidate ]] && { LIB=$candidate; break; }
done
[[ -n $LIB ]] || die "mullionlib.py is missing; cannot uninstall safely."
mfs() { "$PYTHON" "$LIB" "$@"; }

STAMP=$(date +%s)

# ---------------------------------------------------------------------------
say "Restoring any minimized windows first"
# The workspace name is passed as an argument rather than pasted into the
# program text, so a workspace named something awkward stays data.
"$HYPRCTL" clients -j | "$PYTHON" - "$("$HYPRCTL" activeworkspace -j | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["name"])')" "$HYPRCTL" <<'PY'
import json, re, subprocess, sys

target, hyprctl = sys.argv[1], sys.argv[2]
# Hyprland accepts a Lua expression here, so anything spliced into it has to be
# checked first rather than trusted.
if not re.fullmatch(r"[A-Za-z0-9 :._-]{1,64}", target):
    sys.exit("refusing to restore onto a workspace named %r" % target)

for client in json.load(sys.stdin):
    if "omarchy-minimized" not in client["workspace"]["name"]:
        continue
    address = client["address"]
    if not re.fullmatch(r"0x[0-9a-fA-F]{1,16}", address):
        continue
    subprocess.run([hyprctl, "dispatch",
                    'hl.dsp.window.move({ workspace = "%s", window = "address:%s" })'
                    % (target, address)],
                   capture_output=True)
PY

# ---------------------------------------------------------------------------
say "Removing config"
mfs remove "$HOME/.config/hypr" mullion.lua
case "$(mfs unpatch-hyprland "$HOME/.config/hypr" hyprland.lua "$STAMP")" in
  unpatched) echo "Removed Mullion's lines from hyprland.lua (backup written alongside it)." ;;
  *)         echo "hyprland.lua carried no Mullion lines." ;;
esac

say "Removing the plugin binary and commands"
mfs remove "$HOME/.local/share/hyprland/plugins" hyprbars.so
mfs remove "$HOME/.local/bin" \
  rebuild-hyprbars mullion-snap mullion-drag-snap use-system-titlebars mullion-set

# The helper needs its library until the last call, so this goes last and by
# hand; it is a directory tree rather than a name, and it is one we created.
if [[ -d $HOME/.local/share/mullion && ! -L $HOME/.local/share/mullion ]]; then
  rm -rf "$HOME/.local/share/mullion"
fi

echo
echo "Restoring window buttons to other applications"
# Already removed from ~/.local/bin above, so run the copy in this checkout.
if [[ -x $HERE/bin/use-system-titlebars ]]; then
  "$HERE/bin/use-system-titlebars" --revert 2>/dev/null || true
fi

echo "Left in place (remove by hand if you want them gone):"
echo "  - your settings:            ~/.config/omarchy/mullion.conf"
echo "  - the bar widget:           omarchy plugin remove hriddho.mullion"
echo "  - the window-shelf widget:  omarchy plugin remove io.github.gardnmi.window-shelf"
echo "  - the hyprbars block appended to ~/.config/omarchy/themed/hyprland.lua.tpl"
"$HYPRCTL" reload >/dev/null 2>&1 || true
say "Done."
