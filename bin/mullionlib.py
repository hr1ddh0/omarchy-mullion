"""Shared safety primitives for every Mullion helper.

Three jobs, each answering a way this plugin could otherwise be turned against
the person running it:

  * `tool()` resolves an executable from a fixed list of root-owned system
    directories instead of $PATH. These helpers run from Hyprland's exec, from
    a bar widget, and from an installer, none of which control the environment
    they inherit; a writable directory early in $PATH would otherwise choose
    what `git`, `make` or `hyprctl` mean.
  * `owned_dir()` / `write_atomic()` give every write a retained, verified
    directory descriptor and a same-directory rename. A component swapped for
    a symlink between the check and the write cannot redirect us, and a reader
    never sees a half-written config.
  * the `require_*` validators normalise anything that came from a user, an
    environment variable or a config file before it is used as a path or
    embedded in a command.

Imported by the helpers and driven from the shell by the installers through
the command-line interface at the bottom.
"""
import errno
import json
import os
import re
import secrets
import stat
import subprocess
import sys

# Every directory we are willing to resolve a system executable from, in the
# order they are tried. /bin and /sbin are symlinks into /usr/bin on Arch, so
# naming /usr/bin covers them; it goes first so a resolved tool is reported
# under the path people recognise. /usr/local/* is searched but, being the
# directory a machine's own admin writes to, routinely fails the root-owned
# test below and is then skipped rather than trusted.
TRUSTED_BIN_DIRS = ("/usr/bin", "/usr/local/bin", "/usr/sbin", "/usr/local/sbin")

# Handed to any child process we start, so a build or a dispatched command
# inherits the same restricted search path rather than ours.
SAFE_PATH = ":".join(TRUSTED_BIN_DIRS)

# Where the installer puts Mullion's own executables and data.
USER_BIN = "~/.local/bin"
USER_LIB = "~/.local/share/mullion"


class MullionError(Exception):
    """A refusal that should be reported to the user, not a traceback."""


# ---------------------------------------------------------------------------
# Executables.

def _writable_by_others(mode):
    return bool(mode & (stat.S_IWGRP | stat.S_IWOTH))


def _is_trusted_dir(path):
    """A directory only root can add entries to."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    return (stat.S_ISDIR(st.st_mode) and st.st_uid == 0
            and not _writable_by_others(st.st_mode))


def tool(name):
    """Absolute path to a system executable, or raise.

    Deliberately ignores $PATH. The file must live in a root-owned directory,
    resolve to a regular file owned by root, and not be writable by anyone
    else, so the name is bound to an identity the user already trusts with
    their system rather than to whatever the environment points at today.
    """
    if "/" in name:
        raise MullionError("tool() takes a bare name, got %r" % name)
    for directory in TRUSTED_BIN_DIRS:
        if not _is_trusted_dir(directory):
            continue
        candidate = os.path.join(directory, name)
        try:
            # Follows symlinks on purpose: /usr/bin/sh -> bash is normal, and
            # what matters is that whatever we end up executing is root-owned.
            st = os.stat(candidate)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
            continue
        if _writable_by_others(st.st_mode):
            continue
        if not os.access(candidate, os.X_OK):
            continue
        return candidate
    raise MullionError(
        "%s was not found in a trusted system directory (%s)."
        % (name, ", ".join(TRUSTED_BIN_DIRS)))


def helper(name):
    """Absolute path to one of Mullion's own commands in ~/.local/bin.

    Ours rather than root's, so the test is that the user owns it and nobody
    else can write it, and that it is a real file and not a symlink pointing
    somewhere else.
    """
    if "/" in name:
        raise MullionError("helper() takes a bare name, got %r" % name)
    path = os.path.join(os.path.expanduser(USER_BIN), name)
    try:
        st = os.lstat(path)
    except OSError:
        raise MullionError("%s is not installed; run Mullion's install.sh" % name)
    if stat.S_ISLNK(st.st_mode):
        raise MullionError("%s is a symlink; refusing to run it" % path)
    if st.st_uid != os.geteuid() or _writable_by_others(st.st_mode):
        raise MullionError("%s is not owned solely by you; refusing to run it" % path)
    return path


def run(argv, **kwargs):
    """subprocess.run with a controlled environment.

    Everything a child needs is passed explicitly; $PATH is replaced rather
    than inherited so a helper cannot be reached through a planted directory.
    """
    env = dict(kwargs.pop("env", None) or os.environ)
    env["PATH"] = SAFE_PATH
    env.pop("IFS", None)
    env.pop("BASH_ENV", None)
    env.pop("ENV", None)
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return subprocess.run(argv, env=env, **kwargs)


# ---------------------------------------------------------------------------
# Directories and files.

def owned_dir(path, create=False, mode=0o700, require_root=False):
    """Open a directory and return a descriptor we can trust for later writes.

    The descriptor is the point. Checking a path and then writing to it by name
    leaves a window in which a component can be replaced; every write in this
    module happens relative to a descriptor opened here, so the directory we
    verified is the directory we write into, whatever happens to the path
    afterwards.

    The path is fully resolved first, because a user legitimately symlinking
    ~/.config elsewhere is common and refusing that would break real setups.
    What must hold is that the directory we actually land on is owned by the
    right account and not writable by anyone else.
    """
    resolved = os.path.realpath(os.path.expanduser(path))
    if not os.path.isabs(resolved):
        raise MullionError("%s does not resolve to an absolute path" % path)
    if create and not os.path.isdir(resolved):
        os.makedirs(resolved, mode=mode, exist_ok=True)

    try:
        fd = os.open(resolved, os.O_RDONLY | os.O_DIRECTORY)
    except OSError as exc:
        raise MullionError("cannot open directory %s (%s)" % (resolved, exc))

    try:
        st = os.fstat(fd)
        # Ours is the normal case. root's is accepted too for the directories
        # we only ever read from, such as Omarchy's own installed defaults,
        # because root owning them is precisely what makes them trustworthy.
        allowed = (0,) if require_root else (os.geteuid(), 0)
        if st.st_uid not in allowed:
            raise MullionError(
                "%s is owned by uid %d, expected %s; refusing to use it"
                % (resolved, st.st_uid, " or ".join(str(u) for u in allowed)))
        if _writable_by_others(st.st_mode):
            raise MullionError(
                "%s is writable by other users; refusing to write there" % resolved)
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_at(dirfd, name, missing_ok=False):
    """Read a file inside an already-verified directory, never through a link."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
    except FileNotFoundError:
        if missing_ok:
            return None
        raise MullionError("%s does not exist" % name)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            raise MullionError("%s is a symlink; refusing to read through it" % name)
        raise
    with os.fdopen(fd, "rb") as handle:
        return handle.read()


def read_text_at(dirfd, name, missing_ok=False):
    data = read_at(dirfd, name, missing_ok=missing_ok)
    return None if data is None else data.decode("utf-8", "surrogateescape")


def write_atomic(dirfd, name, data, mode=0o600):
    """Replace a file in one step, inside the verified directory.

    Written to a fresh temporary name in the same directory, flushed to disk,
    then renamed over the target. A reader sees either the old file or the new
    one, and because the temporary is created O_EXCL|O_NOFOLLOW we can never be
    made to write through something that was planted under the name we chose.
    """
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogateescape")
    tmp = ".mullion.tmp.%d.%s" % (os.getpid(), secrets.token_hex(6))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 mode, dir_fd=dirfd)
    try:
        with os.fdopen(fd, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
        os.replace(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dirfd)
        except OSError:
            pass
        raise
    # So the rename itself survives a crash, not just the bytes.
    os.fsync(dirfd)


def exists_at(dirfd, name):
    try:
        os.lstat(name, dir_fd=dirfd)
        return True
    except OSError:
        return False


def remove_at(dirfd, name):
    """Unlink inside the verified directory.

    unlink never follows the final component, so this removes the name itself
    even if something has replaced it with a link.
    """
    try:
        os.unlink(name, dir_fd=dirfd)
        return True
    except FileNotFoundError:
        return False
    except IsADirectoryError:
        raise MullionError("%s is a directory" % name)


def backup_at(dirfd, name, suffix):
    """Keep a copy of a file we are about to change, written the same way."""
    current = read_at(dirfd, name, missing_ok=True)
    if current is None:
        return None
    backup = "%s.%s" % (name, suffix)
    write_atomic(dirfd, backup, current, mode=0o600)
    return backup


def install_file(src_path, dirfd, name, mode=0o600):
    """Copy a file from the plugin checkout into a verified directory."""
    src_dir, src_name = os.path.split(os.path.abspath(src_path))
    src_fd = owned_dir(src_dir)
    try:
        data = read_at(src_fd, src_name)
    finally:
        os.close(src_fd)
    write_atomic(dirfd, name, data, mode=mode)


def copy_tree(src_root, dest_root):
    """Recursive copy that refuses links and special files.

    Used to place the plugin's own files where the shell looks for them. Only
    regular files and directories are copied, so a symlink in the source tree
    cannot make the destination reach outside itself.
    """
    src_root = os.path.realpath(src_root)
    made = 0
    for current, dirnames, filenames in os.walk(src_root, followlinks=False):
        rel = os.path.relpath(current, src_root)
        rel = "" if rel == "." else rel
        # Never descend into a link, and skip build detritus.
        dirnames[:] = [d for d in sorted(dirnames)
                       if not os.path.islink(os.path.join(current, d))
                       and d not in ("__pycache__", ".git")]
        dest_dir = os.path.join(dest_root, rel) if rel else dest_root
        dest_fd = owned_dir(dest_dir, create=True, mode=0o755)
        try:
            for filename in sorted(filenames):
                source = os.path.join(current, filename)
                st = os.lstat(source)
                if not stat.S_ISREG(st.st_mode):
                    continue
                mode = 0o755 if st.st_mode & stat.S_IXUSR else 0o644
                with open(source, "rb") as handle:
                    write_atomic(dest_fd, filename, handle.read(), mode=mode)
                made += 1
        finally:
            os.close(dest_fd)
    return made


# ---------------------------------------------------------------------------
# Validation of anything that did not come from us.

PLUGIN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
WINDOW_ADDRESS = re.compile(r"^0x[0-9a-fA-F]{1,16}$")
CONF_KEY = re.compile(r"^[a-z][a-z0-9_]*$")


def require_plugin_id(value):
    """Matches the rule Omarchy's own plugin commands enforce."""
    if not value or not PLUGIN_ID.match(value) or ".." in value:
        raise MullionError("refusing to use %r as a plugin id" % value)
    return value


def require_window_address(value):
    """A Hyprland window handle, before it is spliced into a Lua dispatch."""
    if not value or not WINDOW_ADDRESS.match(value):
        raise MullionError("refusing to use %r as a window address" % value)
    return value


def require_env_dir(name, default, require_root=False):
    """An environment-supplied directory, normalised and ownership-checked.

    XDG_RUNTIME_DIR, XDG_CONFIG_HOME and OMARCHY_PATH all end up as the base of
    a path we write to or read a template from, and all three are attacker
    controlled if the process environment is. A relative or traversing value is
    rejected outright rather than normalised into something surprising.
    """
    raw = os.environ.get(name) or ""
    if raw:
        if not os.path.isabs(raw) or ".." in raw.split(os.sep):
            raise MullionError("%s=%r is not a plain absolute path" % (name, raw))
    path = raw or os.path.expanduser(default)
    fd = owned_dir(path, require_root=require_root)
    os.close(fd)
    return os.path.realpath(path)


# The settings Mullion understands, with the range each may take. mullion.lua
# clamps these too, but that only protects Hyprland; validating on the way in
# is what stops an out-of-band value or a newline ever reaching the file and
# being read back by something less careful.
CONF_SCHEMA = {
    "window_style": {"choices": ("macos", "windows", "none")},
    "button_size": {"min": 6, "max": 28},
    "bar_height": {"min": 16, "max": 64},
    "icons_always_visible": {"bool": True},
    "rounding": {"min": 0, "max": 32},
    "border_size": {"min": 0, "max": 12},
    "gaps_in": {"min": 0, "max": 40},
    "gaps_out": {"min": 0, "max": 80},
    "float_by_default": {"bool": True},
    "shadow": {"bool": True},
    "shadow_range": {"min": 0, "max": 64},
    "shadow_opacity": {"min": 0, "max": 255},
    "drag_snap": {"bool": True},
    "snap_edge": {"min": 1, "max": 200},
    "snap_corner": {"min": 1, "max": 600},
    "hide_app_window_buttons": {"bool": True},
}


def require_conf_pair(key, value):
    """One setting, checked against the schema before it can be written."""
    key = key.strip()
    value = value.strip()
    if not CONF_KEY.match(key) or key not in CONF_SCHEMA:
        raise MullionError("%r is not a Mullion setting" % key)
    rule = CONF_SCHEMA[key]
    if "\n" in value or "\r" in value:
        raise MullionError("a setting value cannot span lines")
    if rule.get("bool"):
        if value not in ("true", "false"):
            raise MullionError("%s must be true or false, got %r" % (key, value))
        return key, value
    if "choices" in rule:
        if value not in rule["choices"]:
            raise MullionError("%s must be one of %s, got %r"
                               % (key, ", ".join(rule["choices"]), value))
        return key, value
    try:
        number = int(value, 10)
    except ValueError:
        raise MullionError("%s must be a whole number, got %r" % (key, value))
    if not (rule["min"] <= number <= rule["max"]):
        raise MullionError("%s must be between %d and %d, got %d"
                           % (key, rule["min"], rule["max"], number))
    return key, str(number)


# ---------------------------------------------------------------------------
# Shell-facing entry points, so the installers get the same guarantees.

def _cli_install_file(args):
    src, dest_dir, name, mode = args[0], args[1], args[2], int(args[3], 8)
    fd = owned_dir(dest_dir, create=True, mode=0o755)
    try:
        install_file(src, fd, name, mode=mode)
    finally:
        os.close(fd)


def _cli_install_default(args):
    """Write a default file only when the user has none."""
    src, dest_dir, name = args[0], args[1], args[2]
    fd = owned_dir(dest_dir, create=True, mode=0o755)
    try:
        if exists_at(fd, name):
            print("keeping")
            return
        install_file(src, fd, name, mode=0o644)
        print("wrote")
    finally:
        os.close(fd)


def _cli_copy_tree(args):
    print(copy_tree(args[0], args[1]))


def _cli_remove(args):
    dest_dir = args[0]
    fd = owned_dir(dest_dir)
    try:
        for name in args[1:]:
            remove_at(fd, name)
    finally:
        os.close(fd)


def _cli_append_once(args):
    """Append a snippet to a file exactly once, atomically.

    The previous shell form was `cat snippet >> target`, which both follows a
    link at the target and can leave a partial block behind if it is
    interrupted.
    """
    dest_dir, name, marker, snippet = args[0], args[1], args[2], args[3]
    fd = owned_dir(dest_dir, create=True, mode=0o755)
    try:
        current = read_text_at(fd, name, missing_ok=True) or ""
        if marker in current:
            print("present")
            return
        with open(snippet, "r", encoding="utf-8") as handle:
            addition = handle.read()
        if current and not current.endswith("\n"):
            current += "\n"
        write_atomic(fd, name, current + addition, mode=0o644)
        print("appended")
    finally:
        os.close(fd)


# The block install.sh adds near the top of hyprland.lua, and uninstall.sh
# removes. Kept here, next to the code that writes it, so the two can never
# describe it differently.
LOADER_ANCHOR = 'require("default.hypr.omarchy")'
LOADER_BLOCK = '''-- macOS-style title bars. Loaded before Omarchy's defaults so the theme can
-- color the bar. Guarded so a version mismatch can never block login.
pcall(function()
  hl.plugin.load(os.getenv("HOME") .. "/.local/share/hyprland/plugins/hyprbars.so")
end)

'''
LOOKNFEEL = 'require("hypr.looknfeel")'
MULLION_REQUIRE = 'require("hypr.mullion")'


def _cli_patch_hyprland(args):
    """Add Mullion's two lines to hyprland.lua, atomically and reversibly.

    The two edits are tested separately: a config carrying one but not the
    other, from a partial uninstall or a hand-edit, needs the missing half
    rather than being declared already done.
    """
    dest_dir, name, stamp = args[0], args[1], args[2]
    fd = owned_dir(dest_dir)
    try:
        before = read_text_at(fd, name)
        after = before
        if "hyprbars.so" not in after:
            if LOADER_ANCHOR not in after:
                raise MullionError(
                    "could not find %s in %s; leaving it untouched"
                    % (LOADER_ANCHOR, name))
            after = after.replace(LOADER_ANCHOR, LOADER_BLOCK + LOADER_ANCHOR, 1)
        if MULLION_REQUIRE not in after:
            if LOOKNFEEL not in after:
                raise MullionError(
                    "could not find %s in %s; leaving it untouched"
                    % (LOOKNFEEL, name))
            after = after.replace(LOOKNFEEL, LOOKNFEEL + "\n" + MULLION_REQUIRE, 1)
        if after == before:
            print("unchanged")
            return
        # The backup is written through the same verified descriptor, so the
        # copy cannot be redirected either.
        backup_at(fd, name, "bak.%s" % stamp)
        write_atomic(fd, name, after, mode=0o644)
        print("patched")
    finally:
        os.close(fd)


def _cli_unpatch_hyprland(args):
    dest_dir, name, stamp = args[0], args[1], args[2]
    fd = owned_dir(dest_dir)
    try:
        before = read_text_at(fd, name, missing_ok=True)
        if before is None:
            print("absent")
            return
        after = "".join(
            line + "\n" for line in before.splitlines()
            if line.strip() != MULLION_REQUIRE)
        after = re.sub(
            r"-- macOS-style title bars.*?\npcall\(function\(\)\n.*?hyprbars\.so.*?\nend\)\n\n",
            "", after, flags=re.S)
        if after == before:
            print("unchanged")
            return
        backup_at(fd, name, "bak.%s" % stamp)
        write_atomic(fd, name, after, mode=0o644)
        print("unpatched")
    finally:
        os.close(fd)


def _cli_check_id(args):
    print(require_plugin_id(args[0]))


def _cli_sha256(args):
    import hashlib
    with open(args[0], "rb") as handle:
        print(hashlib.sha256(handle.read()).hexdigest())


def _cli_json_field(args):
    """Read one field out of a JSON file without shelling into an interpreter."""
    path, field = args[0], args[1]
    with open(path, "r", encoding="utf-8") as handle:
        value = json.load(handle)[field]
    if not isinstance(value, str):
        raise MullionError("%s in %s is not a string" % (field, path))
    print(value)


CLI = {
    "install-file": _cli_install_file,
    "install-default": _cli_install_default,
    "copy-tree": _cli_copy_tree,
    "remove": _cli_remove,
    "append-once": _cli_append_once,
    "patch-hyprland": _cli_patch_hyprland,
    "unpatch-hyprland": _cli_unpatch_hyprland,
    "check-id": _cli_check_id,
    "sha256": _cli_sha256,
    "json-field": _cli_json_field,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in CLI:
        sys.exit("usage: mullionlib.py {%s} ..." % "|".join(sorted(CLI)))
    try:
        CLI[argv[1]](argv[2:])
    except MullionError as exc:
        sys.exit("mullion: %s" % exc)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
