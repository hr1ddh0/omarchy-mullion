#!/usr/bin/bash -p
# Install macOS-style window handling for Omarchy.
#
# Builds the hyprbars title-bar plugin against your exact Hyprland build,
# installs the window-shelf bar widget for minimize, and writes the Hyprland
# Lua config that wires them into macOS behavior.
#
# Everything fetched is pinned and verified file by file, the script and
# everything it starts run in an allowlisted environment with executables taken
# only from root-owned /usr/bin, and every file it writes is placed through
# verified directory descriptors and an atomic rename. Every config it will
# edit is checked before anything is changed, so it cannot stop half-applied.
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
  read -r owner mode kind < <(/usr/bin/stat -c '%u %a %F' -- "$path" 2>/dev/null) \
    || die "$path is missing from this checkout."
  [[ $kind == "regular file" && $owner == "$UID_NUM" ]] && (( (8#$mode & 8#022) == 0 )) \
    || die "$path is not a regular file owned solely by you; refusing to use it (if it is yours: chmod go-w \"$path\")."
}

[[ $HOME == "$REAL_HOME" ]] || die "HOME does not match your account's home directory."
[[ $(/usr/bin/stat -c '%u' -- "$OMARCHY_PATH" 2>/dev/null) == 0 ]] \
  || die "$OMARCHY_PATH is missing or not root-owned. This targets Omarchy."

ASSUME_YES=0
if [[ ${1:-} == "--yes" ]]; then ASSUME_YES=1; fi

HERE=$(/usr/bin/realpath -e -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")")
LIB="$HERE/bin/mullionlib.py"
MINIMIZE_MANIFEST="$HERE/deps/omarchy-minimize.sha256"
owned_file "$LIB"
owned_file "$MINIMIZE_MANIFEST"

PYTHON=$(tool python3)
GIT=$(tool git)
HYPRCTL=$(tool hyprctl)
OMARCHY=$(tool omarchy)
OMARCHY_SHELL=$(tool omarchy-shell)
PLUGIN_VALIDATE=$(tool omarchy-plugin-validate)
URL_CHECK=$(tool omarchy-git-url-check)
tool g++ >/dev/null
tool make >/dev/null
tool pkg-config >/dev/null
tool readelf >/dev/null

[[ -d $HOME/.config/hypr ]] || die "~/.config/hypr not found. This targets Omarchy."

# mullionlib does every file placement: verified directory descriptors, no
# following links, atomic rename. -I keeps the interpreter isolated from
# PYTHONPATH and the user site directory.
mfs() { "$PYTHON" -I "$LIB" "$@"; }

WORK=$(/usr/bin/mktemp -d /tmp/mullion.XXXXXXXX)
STAGE_NAME=""
cleanup() {
  /usr/bin/rm -rf -- "$WORK"
  if [[ -n $STAGE_NAME ]]; then mfs remove-tree "$PLUGINS_DIR" "$STAGE_NAME" 2>/dev/null || true; fi
}
trap cleanup EXIT
/usr/bin/mkdir -m 700 -- "$WORK/home"

# git with nothing from the environment: see rebuild-hyprbars for the reasoning.
# It is only ever run on a repository this script has just cloned itself.
PROXY_ENV=()
for var in https_proxy HTTPS_PROXY no_proxy NO_PROXY; do
  if [[ -n ${!var:-} ]]; then PROXY_ENV+=("$var=${!var}"); fi
done
git_safe() {
  /usr/bin/env -i PATH=/usr/bin HOME="$WORK/home" LANG=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_NO_REPLACE_OBJECTS=1 \
    "${PROXY_ENV[@]}" \
    "$GIT" -c protocol.allow=never -c protocol.https.allow=always \
      -c core.hooksPath=/dev/null -c core.fsmonitor=false \
      -c transfer.fsckobjects=true -c fetch.fsckobjects=true \
      -c advice.detachedHead=false "$@"
}

# The minimize widget Mullion depends on, pinned. `omarchy plugin add` clones a
# repository's default branch as it stands today, which is exactly the
# unreviewable input this avoids. The commit below is the one this release was
# tested against, and deps/omarchy-minimize.sha256 lists every file of it with
# its digest; nothing else is enabled.
MINIMIZE_URL="https://github.com/gardnmi/omarchy-minimize.git"
MINIMIZE_COMMIT="5c29836d0c21e852477874dc73bb85976781dfa7"
MINIMIZE_ID="io.github.gardnmi.window-shelf"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
MINIMIZE_DIR="$PLUGINS_DIR/$MINIMIZE_ID"

/usr/bin/cat <<EOF

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
    pinned to commit ${MINIMIZE_COMMIT:0:12} and verified file by file
  * hide the close buttons that GTK apps and Chromium-family browsers
    draw themselves (reversible from the settings panel)

No sudo, and nothing outside your home directory.
./uninstall.sh reverses all of it.

EOF

if (( ASSUME_YES )); then
  echo "Proceeding (--yes)."
elif [[ -t 0 ]]; then
  read -r -p "Continue? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { echo "Nothing was changed."; exit 0; }
else
  echo "Not running interactively, so nothing was changed."
  echo "Run it in a terminal, or pass --yes to agree up front."
  exit 1
fi

# ---------------------------------------------------------------------------
# Everything that could stop the install is checked here, before any change.
say "Checking your setup before changing anything"

mfs preflight-hyprland "$HOME/.config/hypr" hyprland.lua >/dev/null \
  || die "hyprland.lua cannot be updated safely (see above). Nothing was changed."
mfs preflight-file "$HOME/.config/omarchy/themed" hyprland.lua.tpl >/dev/null \
  || die "The theme template cannot be updated safely (see above). Nothing was changed."

# An existing omarchy-minimize is verified by its files, not by asking git:
# git would read that checkout's own configuration, and a checkout can report
# the pinned commit while its files say otherwise.
REPIN_MINIMIZE=0
if [[ -e $MINIMIZE_DIR || -L $MINIMIZE_DIR ]]; then
  [[ -d $MINIMIZE_DIR && ! -L $MINIMIZE_DIR ]] \
    || die "$MINIMIZE_DIR is not a plain directory. Remove it with
'omarchy plugin remove $MINIMIZE_ID' and run ./install.sh again. Nothing was changed."
  if mfs verify-tree "$MINIMIZE_DIR" "$MINIMIZE_MANIFEST" >/dev/null 2>"$WORK/minimize-check"; then
    echo "omarchy-minimize is installed and matches the reviewed version."
  else
    /usr/bin/sed 's/^mullion: /  /' -- "$WORK/minimize-check" >&2
    echo "The installed omarchy-minimize is not the version Mullion was reviewed with."
    if [[ -t 0 ]] && (( ! ASSUME_YES )); then
      read -r -p "Replace it with the reviewed version? Your current copy is kept aside. [y/N] " answer
      [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die "Nothing was changed."
      REPIN_MINIMIZE=1
    else
      die "Run ./install.sh in a terminal to replace it with the reviewed version, or remove it
with 'omarchy plugin remove $MINIMIZE_ID' first. Nothing was changed."
    fi
  fi
fi
echo "Your configuration can be updated safely."

STAMP=$(/usr/bin/date +%s)

# ---------------------------------------------------------------------------
say "Installing Mullion's commands"
for command in rebuild-hyprbars mullion-snap mullion-drag-snap \
               use-system-titlebars mullion-set; do
  mfs install-file "$HERE/bin/$command" "$HOME/.local/bin" "$command" 755
done
# The shared safety library the commands import, the patch set plus the digest
# manifest rebuild-hyprbars checks every build against, and the dependency
# manifest the bar widget re-checks.
mfs install-file "$HERE/bin/mullionlib.py" "$HOME/.local/share/mullion/lib" mullionlib.py 644
for patch in center-button-icons drag-snap-hooks icon-render-room mirror-button-icons; do
  mfs install-file "$HERE/patches/$patch.py" "$HOME/.local/share/mullion/patches" "$patch.py" 644
done
mfs install-file "$HERE/patches/SOURCES.sha256" "$HOME/.local/share/mullion/patches" SOURCES.sha256 644
mfs install-file "$HERE/patches/verify-pins" "$HOME/.local/share/mullion/patches" verify-pins 755
mfs install-file "$MINIMIZE_MANIFEST" "$HOME/.local/share/mullion/deps" omarchy-minimize.sha256 644

# Default settings, only if the user has none: an upgrade must never discard
# what they have tuned.
DEFAULT_RESULT=$(mfs install-default "$HERE/config/mullion.conf" "$HOME/.config/omarchy" mullion.conf) \
  || die "Could not create ~/.config/omarchy/mullion.conf (see above)."
if [[ $DEFAULT_RESULT == wrote ]]; then
  echo "Wrote default settings to ~/.config/omarchy/mullion.conf"
else
  echo "Keeping your existing ~/.config/omarchy/mullion.conf"
fi

case ":$MULLION_CALLER_PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: ~/.local/bin is not on your PATH, so run mullion-set by its full path; the keybindings already use absolute paths." ;;
esac

say "Building the hyprbars title-bar plugin"
BUILD_STATUS=0
"$HOME/.local/bin/rebuild-hyprbars" || BUILD_STATUS=$?
if (( BUILD_STATUS == 3 )); then
  echo "Note: the plugin is built but not loaded yet; it will load when you next log in."
elif (( BUILD_STATUS != 0 )); then
  die "The title-bar build did not complete, so installation stopped here.
Your Hyprland configuration has not been changed."
fi

# ---------------------------------------------------------------------------
say "Installing the bar widget and settings panel"
# Installed from the marketplace, this already runs from inside the plugin
# directory. Cloned and run by hand, it does not, and without this step there
# is no bar icon and no settings panel at all.
PLUGIN_ID=$(mfs json-field "$HERE/manifest.json" id)
PLUGIN_ID=$(mfs check-id "$PLUGIN_ID")
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

if [[ $HERE == "$(/usr/bin/realpath -m -- "$PLUGIN_DIR")" ]]; then
  echo "Already running from the plugin directory."
else
  # A descriptor-walked copy that takes only regular files and real
  # directories, so nothing can point the destination outside itself.
  copied=$(mfs copy-tree "$HERE" "$PLUGIN_DIR")
  echo "Installed $copied files to $PLUGIN_DIR"
fi
"$OMARCHY_SHELL" shell rescanPlugins >/dev/null 2>&1 || true
/usr/bin/sleep 1
"$OMARCHY" plugin enable "$PLUGIN_ID" --section left >/dev/null 2>&1 \
  || echo "Note: could not enable $PLUGIN_ID automatically; run: omarchy plugin enable $PLUGIN_ID"

# ---------------------------------------------------------------------------
say "Installing the window-shelf bar widget (minimize)"
if [[ -e $MINIMIZE_DIR || -L $MINIMIZE_DIR ]] && (( ! REPIN_MINIMIZE )); then
  # Checked again here rather than relying on the preflight: a copy may have
  # appeared, or changed, while the title bars were building.
  mfs verify-tree "$MINIMIZE_DIR" "$MINIMIZE_MANIFEST" >/dev/null \
    || die "$MINIMIZE_ID changed during installation and no longer matches the reviewed
version. Run ./install.sh again."
  # Its git metadata, if any, is removed so that `omarchy plugin update`
  # cannot move it off the reviewed version.
  if [[ -e $MINIMIZE_DIR/.git || -L $MINIMIZE_DIR/.git ]]; then
    mfs remove-tree "$MINIMIZE_DIR" .git
    echo "Detached it from git, so 'omarchy plugin update' cannot move it off the reviewed version."
  fi
  echo "Already installed at the reviewed version (${MINIMIZE_COMMIT:0:12})."
else
  # Omarchy's own URL check first, so a URL naming a git option or a transport
  # helper is refused before anything is fetched.
  "$URL_CHECK" "$MINIMIZE_URL" || die "refusing $MINIMIZE_URL"

  # A private 0700 staging directory, created through a verified descriptor.
  # git writes by path, but only inside this directory, which nobody else can
  # enter.
  STAGE_NAME=$(mfs make-stage "$PLUGINS_DIR" .mullion-dep)
  STAGE="$PLUGINS_DIR/$STAGE_NAME"
  git_safe clone --quiet --no-checkout -- "$MINIMIZE_URL" "$STAGE/src" \
    || die "could not fetch $MINIMIZE_URL"
  git_safe -C "$STAGE/src" checkout --quiet --detach "$MINIMIZE_COMMIT" \
    || die "pinned commit $MINIMIZE_COMMIT is not in $MINIMIZE_URL"
  GOT=$(git_safe -C "$STAGE/src" rev-parse --verify HEAD)
  [[ $GOT == "$MINIMIZE_COMMIT" ]] || die "fetched $GOT but expected $MINIMIZE_COMMIT"

  # Without its git metadata it is a plain plugin directory that Omarchy's
  # updater skips, and its files are then checked one by one against the
  # reviewed manifest: exactly those files, those digests, no links.
  mfs remove-tree "$STAGE/src" .git
  mfs verify-tree "$STAGE/src" "$MINIMIZE_MANIFEST" >/dev/null \
    || die "the downloaded omarchy-minimize does not match the reviewed file digests"

  # Omarchy's own manifest validation, the same gate `omarchy plugin add` uses.
  "$PLUGIN_VALIDATE" "$STAGE/src" \
    || die "the pinned omarchy-minimize failed Omarchy's plugin validation"
  GOT_ID=$(mfs json-field "$STAGE/src/manifest.json" id)
  [[ $GOT_ID == "$MINIMIZE_ID" ]] \
    || die "pinned commit declares id '$GOT_ID', expected '$MINIMIZE_ID'"

  if (( REPIN_MINIMIZE )); then
    ASIDE=".mullion-replaced.$MINIMIZE_ID.$STAMP"
    mfs rename-in "$PLUGINS_DIR" "$MINIMIZE_ID" "$ASIDE"
    echo "Moved your previous copy to $PLUGINS_DIR/$ASIDE"
  fi
  mfs rename-in "$PLUGINS_DIR" "$STAGE_NAME/src" "$MINIMIZE_ID"
  echo "Installed $MINIMIZE_ID at the reviewed version (${MINIMIZE_COMMIT:0:12})"
  "$OMARCHY_SHELL" shell rescanPlugins >/dev/null 2>&1 || true
  /usr/bin/sleep 1
  "$OMARCHY" plugin enable "$MINIMIZE_ID" >/dev/null 2>&1 \
    || echo "Note: could not enable $MINIMIZE_ID automatically; run: omarchy plugin enable $MINIMIZE_ID"
fi

# ---------------------------------------------------------------------------
say "Installing the Hyprland config"
mfs install-file "$HERE/config/mullion.lua" "$HOME/.config/hypr" mullion.lua 644

# Adds the loader block and the require line if either is absent, upgrading a
# loader written by an earlier release, and keeps a timestamped backup.
PATCH_RESULT=$(mfs patch-hyprland "$HOME/.config/hypr" hyprland.lua "$STAMP") \
  || die "hyprland.lua could not be updated (see above). Nothing after this step was changed."
case "$PATCH_RESULT" in
  patched) echo "Updated hyprland.lua (backup written alongside it)." ;;
  *)       echo "hyprland.lua already up to date; leaving it alone." ;;
esac

# ---------------------------------------------------------------------------
say "Adding theme-tracked title-bar colors"
TPL_DIR="$HOME/.config/omarchy/themed"
if [[ ! -e $TPL_DIR/hyprland.lua.tpl && ! -L $TPL_DIR/hyprland.lua.tpl ]]; then
  # Omarchy's packaged default, and only from a root-owned directory.
  mfs install-system-file "$OMARCHY_PATH/default/themed/hyprland.lua.tpl" \
    "$TPL_DIR" hyprland.lua.tpl 644
fi
# Appended once, as a single atomic rewrite rather than a shell append that
# would follow a link and could leave a half-written block behind.
mfs append-once "$TPL_DIR" hyprland.lua.tpl hyprbars \
  "$HERE/config/themed-hyprland.lua.tpl.snippet" >/dev/null
# Re-render the current theme's templates so the block above takes effect,
# in Omarchy's headless mode and without choosing a background. A full
# `omarchy theme set` would also rotate the wallpaper, restart applications and
# write system-wide browser policy through sudo or pkexec, none of which an
# installer should do.
CURRENT_THEME=$("$OMARCHY" theme current 2>/dev/null </dev/null) || CURRENT_THEME=""
if [[ -n $CURRENT_THEME ]]; then
  /usr/bin/env OMARCHY_THEME_HEADLESS=1 OMARCHY_THEME_SKIP_BACKGROUND=1 \
    "$OMARCHY" theme set "$CURRENT_THEME" </dev/null >/dev/null 2>&1 \
    || echo "Note: title-bar colours will follow your theme from the next theme change."
fi

# ---------------------------------------------------------------------------
say "Checking for browsers that draw their own window buttons"
# A browser drawing its own frame gives you two sets of controls: ours on the
# title bar, and its close button at the right of the tab strip.
"$HOME/.local/bin/use-system-titlebars" || true

say "Reloading Hyprland"
# The plugin's Lua API only appears on the config parse AFTER the one that
# loaded it, so the buttons register on this second pass.
"$HYPRCTL" reload >/dev/null 2>&1 || true
/usr/bin/sleep 1
"$HYPRCTL" reload >/dev/null 2>&1 || true
/usr/bin/sleep 1
"$HYPRCTL" configerrors || true

# The drag preview talks to an IpcHandler inside the bar widget, and those
# only bind when the shell loads the plugin; a hot rescan is not enough.
say "Restarting the shell so the snap preview registers"
"$OMARCHY" restart shell >/dev/null 2>&1 \
  || echo "Note: could not restart the shell; run: omarchy restart shell"
/usr/bin/sleep 4

LOADED=$("$HYPRCTL" plugin list 2>/dev/null) || LOADED=""
if [[ $LOADED == *hyprbars* ]]; then
  say "Done. Traffic lights on every window; minimized windows appear as chips in the bar."
else
  say "Installed, but the title-bar plugin is not loaded yet. Log out and back in."
fi
