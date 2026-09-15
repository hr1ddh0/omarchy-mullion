#!/usr/bin/bash -p
# Remove macOS-style window handling. Leaves your theme untouched.
#
# Every file this edits or removes goes through the same verified-descriptor,
# no-follow operations the installer uses, so a link planted under one of
# these names cannot turn a cleanup into a change somewhere else, and the
# directory tree Mullion created for itself is removed through descriptors,
# never following a link.
set -euo pipefail

# ---------------------------------------------------------------------------
# A controlled environment, for this script and for everything it starts.
#
# `bash -p` stops bash itself reading BASH_ENV or importing functions, but the
# environment would still be handed on to every child: Omarchy's own bash
# tools, git, make, the compiler. So unless the process environment is already
# exactly the allowlist built below, the script re-executes itself under
# `env -i` with only those variables, each value checked. The decision is made
# from the process's real environment in /proc, not from a variable that could
# be preset to skip it.
UID_NUM=$(/usr/bin/id -u)
IFS=: read -r _ _ _ _ _ REAL_HOME _ < <(/usr/bin/getent passwd "$UID_NUM") || true
if [[ ${REAL_HOME:-} != /* ]]; then
  echo "Could not read your home directory from the password database." >&2
  exit 1
fi
RUNTIME_DIR=/run/user/$UID_NUM
SECOND_PASS=0
if [[ ${1:-} == --mullion-clean-env ]]; then SECOND_PASS=1; shift; fi

# The environment this process really started with, read from /proc rather
# than from shell variables, which bash may have set or changed since.
declare -A STARTED_WITH=()
mapfile -d '' -t ACTUAL_ENV < <(/usr/bin/sort -z /proc/$$/environ)
for entry in "${ACTUAL_ENV[@]}"; do
  if [[ $entry == *=* ]]; then STARTED_WITH[${entry%%=*}]=${entry#*=}; fi
done
# Kept only so the installer can tell the user whether ~/.local/bin is on their
# PATH; it is never used to find anything.
if (( ! SECOND_PASS )) && [[ -z ${STARTED_WITH[MULLION_CALLER_PATH]+x} ]]; then
  STARTED_WITH[MULLION_CALLER_PATH]=${STARTED_WITH[PATH]-}
fi

allowed_env() {
  local -a env=(PATH=/usr/bin "HOME=$REAL_HOME" LANG=C.UTF-8 OMARCHY_PATH=/usr/share/omarchy)
  local pair name pattern value
  if [[ -d $RUNTIME_DIR ]]; then env+=("XDG_RUNTIME_DIR=$RUNTIME_DIR"); fi
  if [[ -S $RUNTIME_DIR/bus ]]; then env+=("DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus"); fi
  # TERM is always present, so a missing or unusable one cannot make the two
  # passes disagree.
  value=${STARTED_WITH[TERM]-}
  if [[ $value =~ ^[A-Za-z0-9._+-]{1,64}$ ]]; then env+=("TERM=$value"); else env+=(TERM=dumb); fi
  for pair in \
      'WAYLAND_DISPLAY=^[A-Za-z0-9_.-]{1,64}$' \
      'DISPLAY=^:[0-9]+(\.[0-9]+)?$' \
      'HYPRLAND_INSTANCE_SIGNATURE=^[A-Za-z0-9_]{1,128}$' \
      'XDG_SESSION_TYPE=^[a-z]{1,16}$' \
      'XDG_CURRENT_DESKTOP=^[A-Za-z0-9:_-]{1,64}$' \
      'COLORTERM=^[A-Za-z0-9._+-]{1,64}$' \
      'https_proxy=^[[:graph:]]{1,512}$' \
      'HTTPS_PROXY=^[[:graph:]]{1,512}$' \
      'no_proxy=^[[:graph:]]{1,512}$' \
      'NO_PROXY=^[[:graph:]]{1,512}$' \
      'MULLION_CALLER_PATH=^[[:graph:]]{1,4096}$'; do
    name=${pair%%=*}
    pattern=${pair#*=}
    value=${STARTED_WITH[$name]-}
    if [[ -n $value && $value =~ $pattern ]]; then env+=("$name=$value"); fi
  done
  printf '%s\0' "${env[@]}"
}

mapfile -d '' -t WANTED_ENV < <(allowed_env | /usr/bin/sort -z)
ENV_IS_CLEAN=1
if (( ${#WANTED_ENV[@]} != ${#ACTUAL_ENV[@]} )); then
  ENV_IS_CLEAN=0
else
  for i in "${!WANTED_ENV[@]}"; do
    if [[ ${WANTED_ENV[i]} != "${ACTUAL_ENV[i]}" ]]; then ENV_IS_CLEAN=0; break; fi
  done
fi
if (( ! ENV_IS_CLEAN )); then
  # A second pass that still does not match means something outside our
  # control is adding to the environment; refuse rather than loop.
  if (( SECOND_PASS )); then
    echo "Could not start with a controlled environment; refusing to continue." >&2
    exit 1
  fi
  exec /usr/bin/env -i "${WANTED_ENV[@]}" /usr/bin/bash -p -- \
    "$(/usr/bin/realpath -e -- "${BASH_SOURCE[0]}")" --mullion-clean-env "$@"
fi
MULLION_CALLER_PATH=${STARTED_WITH[MULLION_CALLER_PATH]-}
unset WANTED_ENV ACTUAL_ENV ENV_IS_CLEAN STARTED_WITH
umask 022

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

tool() {
  local name=$1 path=/usr/bin/$1 owner mode
  [[ -f $path && -x $path ]] || die "$name was not found in /usr/bin."
  read -r owner mode < <(/usr/bin/stat -Lc '%u %a' -- "$path")
  [[ $owner == 0 ]] && (( (8#$mode & 8#022) == 0 )) \
    || die "/usr/bin/$name is not a root-owned, non-writable executable."
  printf '%s\n' "$path"
}

owned_file() {
  local path=$1 owner mode kind
  read -r owner mode kind < <(/usr/bin/stat -c '%u %a %F' -- "$path" 2>/dev/null) || return 1
  [[ $kind == "regular file" && $owner == "$UID_NUM" ]] && (( (8#$mode & 8#022) == 0 ))
}

[[ $HOME == "$REAL_HOME" ]] || die "HOME does not match your account's home directory."

PYTHON=$(tool python3)
HYPRCTL=$(tool hyprctl)

HERE=$(/usr/bin/realpath -e -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")")
LIB=""
for candidate in "$HERE/bin/mullionlib.py" "$HOME/.local/share/mullion/lib/mullionlib.py"; do
  if owned_file "$candidate"; then LIB=$candidate; break; fi
done
[[ -n $LIB ]] || die "mullionlib.py is missing or not owned by you; cannot uninstall safely."
mfs() { "$PYTHON" -I "$LIB" "$@"; }

STAMP=$(/usr/bin/date +%s)

# ---------------------------------------------------------------------------
say "Restoring any minimized windows first"
# Hyprland's answers are passed to the program as arguments, and the program
# text itself is fixed, so no window title or workspace name can become code.
# Every value spliced into the Lua dispatch is checked first.
RESTORE=$(/usr/bin/cat <<'PY'
import json, re, subprocess, sys

hyprctl = sys.argv[1]
active = json.loads(sys.argv[2])
clients = json.loads(sys.argv[3])
target = str(active.get("name", ""))
if not re.fullmatch(r"[A-Za-z0-9 :._-]{1,64}", target):
    print("  the current workspace name cannot be used safely; switch to a"
          " numbered workspace and run this again to restore minimized windows")
    sys.exit(0)

restored = 0
for client in clients:
    workspace = client.get("workspace") if isinstance(client, dict) else None
    if not isinstance(workspace, dict) or "omarchy-minimized" not in str(workspace.get("name", "")):
        continue
    address = str(client.get("address", ""))
    if not re.fullmatch(r"0x[0-9a-fA-F]{1,16}", address):
        continue
    subprocess.run([hyprctl, "dispatch",
                    'hl.dsp.window.move({ workspace = "%s", window = "address:%s" })'
                    % (target, address)],
                   capture_output=True)
    restored += 1
print("  restored %d window%s" % (restored, "" if restored == 1 else "s"))
PY
)
if CLIENTS=$("$HYPRCTL" clients -j 2>/dev/null) && ACTIVE=$("$HYPRCTL" activeworkspace -j 2>/dev/null); then
  "$PYTHON" -I -c "$RESTORE" "$HYPRCTL" "$ACTIVE" "$CLIENTS" \
    || echo "  could not restore them; they are on the special:omarchy-minimized workspace"
else
  echo "  Hyprland is not reachable; skipping"
fi

# ---------------------------------------------------------------------------
# hyprland.lua first: if it cannot be edited, stop before anything is removed,
# so the desktop is never left loading a config that no longer exists.
say "Removing config"
UNPATCH=$(mfs unpatch-hyprland "$HOME/.config/hypr" hyprland.lua "$STAMP") \
  || die "hyprland.lua could not be updated (see above); nothing was removed."
case "$UNPATCH" in
  unpatched) echo "Removed Mullion's lines from hyprland.lua (backup written alongside it)." ;;
  *)         echo "hyprland.lua carried no Mullion lines." ;;
esac
mfs remove "$HOME/.config/hypr" mullion.lua

say "Removing the plugin binary and commands"
mfs remove "$HOME/.local/share/hyprland/plugins" hyprbars.so
mfs remove "$HOME/.local/bin" \
  rebuild-hyprbars mullion-snap mullion-drag-snap use-system-titlebars mullion-set

# Bytecode Python cached beside the commands, including from the names earlier
# releases used.
PYCACHE="$HOME/.local/bin/__pycache__"
if [[ -d $PYCACHE && ! -L $PYCACHE ]]; then
  CACHED=()
  shopt -s nullglob
  for cached in "$PYCACHE"/{mullion-snap,mullion-drag-snap,macos-snap,macos-drag-snap}*.pyc; do
    CACHED+=("${cached##*/}")
  done
  shopt -u nullglob
  if (( ${#CACHED[@]} )); then mfs remove "$PYCACHE" "${CACHED[@]}"; fi
  mfs rmdir-if-empty "$HOME/.local/bin" __pycache__
fi

echo
echo "Restoring window buttons to other applications"
# The installed copy is gone, so run the one beside this script, with the
# library it ships with. It restores what it recorded before first changing
# anything, from state kept under ~/.local/share/mullion, so it runs before
# that directory is removed.
if owned_file "$HERE/bin/use-system-titlebars" && owned_file "$HERE/bin/mullionlib.py"; then
  "$PYTHON" -I "$HERE/bin/use-system-titlebars" --revert || true
fi

mfs remove-tree "$HOME/.local/share" mullion

echo "Left in place (remove by hand if you want them gone):"
echo "  - your settings:            ~/.config/omarchy/mullion.conf"
echo "  - the bar widget:           omarchy plugin remove hriddho.mullion"
echo "  - the window-shelf widget:  omarchy plugin remove io.github.gardnmi.window-shelf"
echo "  - the hyprbars block appended to ~/.config/omarchy/themed/hyprland.lua.tpl"
"$HYPRCTL" reload >/dev/null 2>&1 || true
say "Done."
