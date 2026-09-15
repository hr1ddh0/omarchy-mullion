"""Shared safety primitives for every Mullion helper.

Three jobs, each answering a way this plugin could otherwise be turned against
the person running it:

  * `tool()` resolves an executable from /usr/bin only, and only when root owns
    both the directory and the file, and `child_env()` builds the complete
    environment of every child from an allowlist. These helpers run from
    Hyprland's exec, from a bar widget and from an installer, none of which
    control the environment they inherit.
  * `owned_dir()` walks a directory path from / one component at a time,
    resolving symlinks itself so each link's owner can be checked, verifying
    and holding a descriptor for every directory, and `write_atomic()` writes
    through the final descriptor with a same-directory rename. A component
    swapped for a symlink cannot redirect a write, and a reader never sees a
    half-written file.
  * the `require_*` validators normalise anything that came from a user, an
    environment variable or a config file before it is used as a path or
    embedded in a command.

Imported by the helpers and driven from the shell by the installers through
the command-line interface at the bottom.
"""
import errno
import hashlib
import json
import os
import pwd
import re
import secrets
import stat
import subprocess
import sys

# The one directory system executables are resolved from. Omarchy is Arch-only,
# and on Arch /bin, /sbin and /usr/sbin are all symlinks into /usr/bin, so this
# covers every packaged tool. /usr/local/bin is deliberately excluded: it is the
# directory a machine's own admin writes to, and is not always root-owned.
TRUSTED_BIN_DIRS = ("/usr/bin",)

# Handed to every child process in place of the inherited search path.
SAFE_PATH = "/usr/bin"

# Session variables a child may inherit, each only when its value has the shape
# it should. Everything else in the environment is dropped, so a child cannot
# be steered by exported shell functions, loader or module search paths
# (LD_PRELOAD, GIO_EXTRA_MODULES, GCONV_PATH, ...), TMPDIR or anything else.
SESSION_ENV = {
    "WAYLAND_DISPLAY": r"[A-Za-z0-9_.-]{1,64}",
    "DISPLAY": r":[0-9]+(\.[0-9]+)?",
    "HYPRLAND_INSTANCE_SIGNATURE": r"[A-Za-z0-9_]{1,128}",
    "XDG_SESSION_TYPE": r"[a-z]{1,16}",
    "XDG_CURRENT_DESKTOP": r"[A-Za-z0-9:_-]{1,64}",
    "TERM": r"[A-Za-z0-9._+-]{1,64}",
    "COLORTERM": r"[A-Za-z0-9._+-]{1,64}",
}

# How many symlinks one path may pass through before it is refused.
MAX_LINKS = 40


class MullionError(Exception):
    """A refusal that should be reported to the user, not a traceback."""


def real_home():
    """The home directory from the password database, not from $HOME.

    Every path this plugin writes to is under the home directory, so the base
    of all of them must not be something the environment can choose.
    """
    return pwd.getpwuid(os.getuid()).pw_dir


def require_home():
    """Refuse to run when $HOME disagrees with the password database."""
    env_home = os.environ.get("HOME") or ""
    home = real_home()
    if not env_home or os.path.realpath(env_home) != os.path.realpath(home):
        raise MullionError("HOME=%r does not match your account's home directory %r"
                           % (env_home, home))
    return home


def user_path(*parts):
    """A path under the real home directory."""
    return os.path.join(real_home(), *parts)


# ---------------------------------------------------------------------------
# Executables and child processes.

def _writable_by_others(mode):
    return bool(mode & (stat.S_IWGRP | stat.S_IWOTH))


def tool(name):
    """Absolute path to a system executable, or raise.

    Deliberately ignores $PATH. The directory and the file it resolves to must
    both be owned by root and writable by nobody else, so the name is bound to
    an identity the user already trusts with their system rather than to
    whatever the environment points at today.
    """
    if not name or "/" in name:
        raise MullionError("tool() takes a bare name, got %r" % name)
    for directory in TRUSTED_BIN_DIRS:
        try:
            dst = os.stat(directory)
        except OSError:
            continue
        if dst.st_uid != 0 or _writable_by_others(dst.st_mode):
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
        if _writable_by_others(st.st_mode) or not os.access(candidate, os.X_OK):
            continue
        return candidate
    raise MullionError("%s was not found as a root-owned executable in /usr/bin." % name)


def owned_file(path):
    """A file of ours that is about to be executed or imported.

    It must be a regular file, not a symlink, owned by the user and writable by
    nobody else. Returns the path unchanged when it qualifies.
    """
    try:
        st = os.lstat(path)
    except OSError:
        raise MullionError("%s is missing; reinstall Mullion" % path)
    if not stat.S_ISREG(st.st_mode):
        raise MullionError("%s is not a regular file; refusing to use it" % path)
    if st.st_uid != os.geteuid() or _writable_by_others(st.st_mode):
        raise MullionError("%s is not owned solely by you; refusing to use it" % path)
    return path


def helper(name):
    """Absolute path to one of Mullion's own installed commands."""
    if not name or "/" in name:
        raise MullionError("helper() takes a bare name, got %r" % name)
    return owned_file(user_path(".local", "bin", name))


def child_env(extra=None):
    """The complete environment for a child process, built from an allowlist.

    Nothing is copied wholesale from our own environment. HOME and the runtime
    and D-Bus locations are derived from the account, the rest of the session
    variables are passed only when their values look right, and `extra` adds
    what a specific child needs.
    """
    uid = os.getuid()
    account = pwd.getpwuid(uid)
    env = {"PATH": SAFE_PATH, "HOME": account.pw_dir, "LANG": "C.UTF-8",
           "USER": account.pw_name, "LOGNAME": account.pw_name}
    runtime = "/run/user/%d" % uid
    if os.path.isdir(runtime):
        env["XDG_RUNTIME_DIR"] = runtime
        if os.path.exists(os.path.join(runtime, "bus")):
            env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=%s/bus" % runtime
    for key, pattern in SESSION_ENV.items():
        value = os.environ.get(key)
        if value and re.fullmatch(pattern, value):
            env[key] = value
    if extra:
        env.update(extra)
    return env


def run(argv, **kwargs):
    """subprocess.run with an allowlisted environment and no shell."""
    env = child_env(kwargs.pop("env", None))
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return subprocess.run(argv, env=env, shell=False, **kwargs)


# ---------------------------------------------------------------------------
# Directories and files.

def _verify_dir(fd, shown, final, require_root):
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        raise MullionError("%s is not a directory" % shown)
    # A system file must be reachable only through directories root controls;
    # anything of ours may also pass through our own directories.
    allowed = (0,) if require_root else (os.geteuid(), 0)
    if st.st_uid not in allowed:
        raise MullionError("%s is owned by uid %d; refusing to use it" % (shown, st.st_uid))
    if _writable_by_others(st.st_mode):
        # A root-owned sticky ancestor such as /tmp is acceptable: nobody can
        # rename or replace an entry inside it that they do not own. Anything
        # else writable by others could have a component swapped under us.
        sticky_root = st.st_uid == 0 and st.st_mode & stat.S_ISVTX
        if final or not sticky_root:
            raise MullionError("%s is writable by other users; refusing to use it "
                               "(if it is yours: chmod go-w %s)" % (shown, shown))


_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _open_child(parent_fd, name, shown):
    try:
        return os.open(name, _DIR_FLAGS, dir_fd=parent_fd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise MullionError("%s changed into a link or file while it was being "
                               "opened; refusing to continue" % shown)
        raise


def _walk_from_root(names, require_root):
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        _verify_dir(fd, "/", final=False, require_root=require_root)
        shown = ""
        for name in names:
            shown += "/" + name
            child = _open_child(fd, name, shown)
            os.close(fd)
            fd = child
            _verify_dir(fd, shown, final=False, require_root=require_root)
    except BaseException:
        os.close(fd)
        raise
    return fd


def owned_dir(path, create=False, mode=0o755, require_root=False):
    """Open a directory and return a descriptor we can trust for later writes.

    The path is walked from / one component at a time. Each directory is
    opened with O_NOFOLLOW relative to its verified parent, its owner and
    permissions checked, and its descriptor held before the next is opened.
    Symlinks are resolved here rather than by the kernel or realpath, so the
    owner of every link on the way is checked: links owned by you or by root
    are followed, a link owned by anyone else is refused. Every directory we
    pass through is therefore one only you or root can change, and the
    descriptor returned is the directory that was verified.
    """
    expanded = os.path.expanduser(path)
    if not os.path.isabs(expanded) or "\0" in expanded:
        raise MullionError("%r is not an absolute path" % path)
    if ".." in expanded.split("/"):
        raise MullionError("%r contains '..'; refusing to resolve it" % path)

    uid = os.geteuid()
    pending = [p for p in expanded.split("/") if p and p != "."]
    stack = []
    links = 0
    fd = _walk_from_root([], require_root)
    try:
        while pending:
            name = pending.pop(0)
            if name == ".":
                continue
            if name == "..":
                # Only reachable through a link target; walk back up by
                # re-opening the verified parents from the root.
                if stack:
                    stack.pop()
                os.close(fd)
                fd = -1
                fd = _walk_from_root(stack, require_root)
                continue
            shown = "/" + "/".join(stack + [name])
            try:
                st = os.lstat(name, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise MullionError("%s does not exist" % shown)
                try:
                    os.mkdir(name, mode, dir_fd=fd)
                except FileExistsError:
                    pass
                st = os.lstat(name, dir_fd=fd)
            if stat.S_ISLNK(st.st_mode):
                if st.st_uid not in (uid, 0):
                    raise MullionError("%s is a symlink owned by uid %d; refusing to "
                                       "follow it" % (shown, st.st_uid))
                links += 1
                if links > MAX_LINKS:
                    raise MullionError("%s passes through too many symlinks" % path)
                target = os.readlink(name, dir_fd=fd)
                parts = [p for p in target.split("/") if p]
                if target.startswith("/"):
                    stack = []
                    os.close(fd)
                    fd = -1
                    fd = _walk_from_root([], require_root)
                pending = parts + pending
                continue
            child = _open_child(fd, name, shown)
            os.close(fd)
            fd = child
            stack.append(name)
            _verify_dir(fd, shown, final=False, require_root=require_root)
        _verify_dir(fd, "/" + "/".join(stack), final=True, require_root=require_root)
    except BaseException:
        if fd >= 0:
            os.close(fd)
        raise
    return fd


def child_dir(parent_fd, name, create=False, mode=0o755):
    """Open a subdirectory relative to a verified descriptor, never via a link."""
    if not name or "/" in name or name in (".", ".."):
        raise MullionError("%r is not a plain directory name" % name)
    try:
        fd = os.open(name, _DIR_FLAGS, dir_fd=parent_fd)
    except FileNotFoundError:
        if not create:
            raise MullionError("%s does not exist" % name)
        try:
            os.mkdir(name, mode, dir_fd=parent_fd)
        except FileExistsError:
            pass
        fd = _open_child(parent_fd, name, name)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise MullionError("%s is a link or a file, not a directory" % name)
        raise
    try:
        _verify_dir(fd, name, final=True, require_root=False)
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_at(dirfd, name, missing_ok=False):
    """Read a file inside a verified directory, never through a link."""
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
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise MullionError("%s is not a regular file" % name)
        return handle.read()


def read_text_at(dirfd, name, missing_ok=False):
    data = read_at(dirfd, name, missing_ok=missing_ok)
    return None if data is None else data.decode("utf-8", "surrogateescape")


def write_atomic(dirfd, name, data, mode=0o600, keep_mode=True):
    """Replace a file in one step, inside the verified directory.

    Written to a fresh temporary name in the same directory, flushed to disk,
    then renamed over the target. A reader sees either the old file or the new
    one, and because the temporary is created O_EXCL|O_NOFOLLOW we can never be
    made to write through something planted under the name we chose. An
    existing regular file keeps its permissions unless keep_mode is False.
    """
    if not name or "/" in name or name in (".", ".."):
        raise MullionError("%r is not a plain file name" % name)
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogateescape")
    if keep_mode:
        try:
            st = os.lstat(name, dir_fd=dirfd)
            if stat.S_ISREG(st.st_mode):
                mode = stat.S_IMODE(st.st_mode)
        except FileNotFoundError:
            pass
    tmp = ".mullion.tmp.%d.%s" % (os.getpid(), secrets.token_hex(6))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=dirfd)
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


def backup_at(dirfd, name, suffix, keep_existing=False):
    """Keep a copy of a file we are about to change, written the same way.

    With keep_existing, a backup that is already there is left alone, so the
    copy always holds the file as it was before Mullion first touched it.
    """
    backup = "%s.%s" % (name, suffix)
    if keep_existing and exists_at(dirfd, backup):
        return backup
    current = read_at(dirfd, name, missing_ok=True)
    if current is None:
        return None
    write_atomic(dirfd, backup, current, mode=0o600, keep_mode=False)
    return backup


def read_source(src_path, require_root=False):
    """Read a file we are about to install, from a verified directory.

    With require_root, every directory on the way and the file itself must be
    owned by root, so a system default can only come from where root put it.
    """
    src_dir, src_name = os.path.split(os.path.abspath(src_path))
    src_fd = owned_dir(src_dir, require_root=require_root)
    try:
        if not require_root:
            return read_at(src_fd, src_name)
        try:
            fd = os.open(src_name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=src_fd)
        except OSError as exc:
            raise MullionError("cannot open %s (%s)" % (src_path, exc))
        with os.fdopen(fd, "rb") as handle:
            st = os.fstat(handle.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or _writable_by_others(st.st_mode):
                raise MullionError("%s is not a root-owned regular file" % src_path)
            return handle.read()
    finally:
        os.close(src_fd)


def sha256_at(dirfd, name):
    return hashlib.sha256(read_at(dirfd, name)).hexdigest()


def config_target(directory, name):
    """The verified directory and file name to edit for a config file.

    A config file that is itself a symlink owned by you (a dotfile manager's
    link, typically) is resolved one step so its real location is edited. The
    link target is walked through owned_dir like any other path, never
    normalised by text first, so a `..` in it is refused rather than resolved
    differently from how the kernel would. A link owned by anyone else, or a
    link to another link, is refused.
    """
    fd = owned_dir(directory)
    try:
        st = os.lstat(name, dir_fd=fd)
    except FileNotFoundError:
        return fd, name
    if not stat.S_ISLNK(st.st_mode):
        return fd, name
    try:
        if st.st_uid not in (os.geteuid(), 0):
            raise MullionError("%s is a symlink owned by uid %d; refusing to follow it"
                               % (name, st.st_uid))
        target = os.readlink(name, dir_fd=fd)
    finally:
        os.close(fd)
    if ".." in target.split("/"):
        raise MullionError("%s links through '..'; refusing to follow it" % name)
    base = os.path.expanduser(directory)
    resolved = target if target.startswith("/") else os.path.join(base, target)
    new_dir, new_name = os.path.split(resolved)
    if not new_name:
        raise MullionError("%s does not link to a file" % name)
    new_fd = owned_dir(new_dir)
    try:
        if stat.S_ISLNK(os.lstat(new_name, dir_fd=new_fd).st_mode):
            raise MullionError("%s links to another link; refusing to follow it" % name)
    except FileNotFoundError:
        pass
    except BaseException:
        os.close(new_fd)
        raise
    return new_fd, new_name


def remove_tree_at(dirfd, name):
    """Remove an entry inside a verified directory, recursively, by descriptor.

    A file or link is unlinked (a link is never followed), and a directory is
    emptied through descriptors opened with O_NOFOLLOW before it is removed,
    so nothing outside the named entry can be reached however the tree is
    rearranged while this runs.
    """
    if not name or "/" in name or name in (".", ".."):
        raise MullionError("%r is not a plain name" % name)
    try:
        st = os.lstat(name, dir_fd=dirfd)
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(st.st_mode):
        os.unlink(name, dir_fd=dirfd)
        return True
    fd = _open_child(dirfd, name, name)
    try:
        if os.fstat(fd).st_uid != os.geteuid():
            raise MullionError("%s is not yours; refusing to remove it" % name)
        for entry in os.listdir(fd):
            remove_tree_at(fd, entry)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=dirfd)
    return True


def copy_tree(src_root, dest_root):
    """Recursive copy that refuses links and special files on both sides.

    The destination is walked by descriptor: each subdirectory is opened or
    created relative to its verified parent with O_NOFOLLOW, so a link planted
    anywhere inside the destination cannot make the copy land outside it.
    """
    src_root = os.path.realpath(src_root)
    root_fd = owned_dir(dest_root, create=True)
    count = [0]

    def copy(src_dir, dest_fd):
        for entry in sorted(os.listdir(src_dir)):
            if entry in ("__pycache__", ".git"):
                continue
            source = os.path.join(src_dir, entry)
            st = os.lstat(source)
            if stat.S_ISDIR(st.st_mode):
                sub = child_dir(dest_fd, entry, create=True)
                try:
                    copy(source, sub)
                finally:
                    os.close(sub)
            elif stat.S_ISREG(st.st_mode):
                fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd, "rb") as handle:
                    data = handle.read()
                mode = 0o755 if st.st_mode & stat.S_IXUSR else 0o644
                write_atomic(dest_fd, entry, data, mode=mode, keep_mode=False)
                count[0] += 1
            # Links, sockets and devices are skipped.

    try:
        copy(src_root, root_fd)
    finally:
        os.close(root_fd)
    return count[0]


# ---------------------------------------------------------------------------
# Whole-tree digests, for a dependency we verify without trusting git.

MANIFEST_LINE = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9._+@-]+(?:/[A-Za-z0-9._+@-]+)*)$")


def tree_digests(root, skip_top=(".git",)):
    """{relative path: sha256} for every file under root.

    Walked by descriptor with O_NOFOLLOW. A link, socket or device anywhere in
    the tree is refused outright, since it is not something a reviewed plugin
    ships. Only the named top-level entries are skipped.
    """
    found = {}
    root_fd = owned_dir(root)

    def walk(dir_fd, prefix):
        for entry in sorted(os.listdir(dir_fd)):
            rel = prefix + entry
            st = os.lstat(entry, dir_fd=dir_fd)
            if not prefix and entry in skip_top:
                # Skipped only as a real directory; a link or file in its place
                # is exactly what a reviewed plugin does not ship.
                if not stat.S_ISDIR(st.st_mode):
                    raise MullionError("%s is a link or file, not a directory" % rel)
                continue
            if stat.S_ISDIR(st.st_mode):
                sub = child_dir(dir_fd, entry)
                try:
                    walk(sub, rel + "/")
                finally:
                    os.close(sub)
            elif stat.S_ISREG(st.st_mode):
                found[rel] = sha256_at(dir_fd, entry)
            else:
                raise MullionError("%s is a link or special file" % rel)

    try:
        walk(root_fd, "")
    finally:
        os.close(root_fd)
    return found


def load_tree_manifest(path):
    wanted = {}
    for number, line in enumerate(read_source(path).decode("utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        match = MANIFEST_LINE.match(line)
        if not match or ".." in match.group(2).split("/"):
            raise MullionError("%s line %d is not a digest line" % (path, number))
        if match.group(2) in wanted:
            raise MullionError("%s lists %s twice" % (path, match.group(2)))
        wanted[match.group(2)] = match.group(1)
    if not wanted:
        raise MullionError("%s lists no files" % path)
    return wanted


def verify_tree(root, manifest):
    """Raise unless root holds exactly the manifest's files and digests."""
    wanted = load_tree_manifest(manifest)
    got = tree_digests(root)
    problems = []
    problems += ["%s is missing" % p for p in sorted(set(wanted) - set(got))]
    problems += ["%s is not part of the reviewed version" % p for p in sorted(set(got) - set(wanted))]
    problems += ["%s differs from the reviewed version" % p
                 for p in sorted(set(wanted) & set(got)) if wanted[p] != got[p]]
    if problems:
        raise MullionError("%s does not match the reviewed version:\n  %s"
                           % (root, "\n  ".join(problems)))
    return len(got)


# ---------------------------------------------------------------------------
# Validation of anything that did not come from us.

PLUGIN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
WINDOW_ADDRESS = re.compile(r"^0x[0-9a-fA-F]{1,16}$")
CONF_KEY = re.compile(r"^[a-z][a-z0-9_]*$")
HYPRLAND_SIGNATURE = re.compile(r"^[A-Za-z0-9_]{1,128}$")


def require_plugin_id(value):
    """Matches the rule Omarchy's own plugin commands enforce."""
    if not value or not PLUGIN_ID.match(value) or ".." in value:
        raise MullionError("refusing to use %r as a plugin id" % value)
    return value


def require_window_address(value):
    """A Hyprland window handle, before it is spliced into a Lua dispatch."""
    if not isinstance(value, str) or not WINDOW_ADDRESS.match(value):
        raise MullionError("refusing to use %r as a window address" % (value,))
    return value


def require_env_dir(name, default):
    """An environment-supplied directory, normalised and ownership-checked.

    XDG_CONFIG_HOME and similar end up as the base of paths we read and write,
    and are attacker controlled if the process environment is. A relative or
    traversing value is rejected outright; the default is expanded from the
    real home directory, never from the current directory.
    """
    raw = os.environ.get(name) or ""
    if raw and (not os.path.isabs(raw) or ".." in raw.split("/") or "\0" in raw):
        raise MullionError("%s=%r is not a plain absolute path" % (name, raw))
    if raw:
        path = raw
    elif default.startswith("~/"):
        path = user_path(default[2:])
    else:
        path = default
    if not os.path.isabs(path):
        raise MullionError("%r is not an absolute path" % path)
    fd = owned_dir(path)
    os.close(fd)
    return path


def require_runtime_dir():
    """The user's runtime directory, and only the standard one.

    Hyprland's command socket and our drag state live here, so it must be
    /run/user/<uid>, owned by us and closed to everyone else. An
    XDG_RUNTIME_DIR naming anywhere else is refused rather than followed.
    """
    path = "/run/user/%d" % os.getuid()
    raw = os.environ.get("XDG_RUNTIME_DIR")
    if raw and os.path.realpath(raw) != path:
        raise MullionError("XDG_RUNTIME_DIR=%r is not %s" % (raw, path))
    fd = owned_dir(path)
    try:
        st = os.fstat(fd)
    finally:
        os.close(fd)
    if st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) & 0o077:
        raise MullionError("%s must be owned by you with mode 0700" % path)
    return path


# The settings Mullion understands, with the range each may take. mullion.lua
# clamps these too, but that only protects Hyprland; validating on the way in
# is what stops an out-of-range value or a newline ever reaching the file.
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
    """One setting, checked against the schema before it can be written.

    Control characters are refused before any trimming, so a value carrying a
    line break is rejected outright rather than quietly normalised.
    """
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in key + value):
        raise MullionError("a setting cannot contain line breaks or control characters")
    key = key.strip()
    value = value.strip()
    if not CONF_KEY.match(key) or key not in CONF_SCHEMA:
        raise MullionError("%r is not a Mullion setting" % key)
    rule = CONF_SCHEMA[key]
    if rule.get("bool"):
        if value not in ("true", "false"):
            raise MullionError("%s must be true or false, got %r" % (key, value))
        return key, value
    if "choices" in rule:
        if value not in rule["choices"]:
            raise MullionError("%s must be one of %s, got %r"
                               % (key, ", ".join(rule["choices"]), value))
        return key, value
    if not re.fullmatch(r"-?[0-9]{1,6}", value):
        raise MullionError("%s must be a whole number, got %r" % (key, value))
    number = int(value, 10)
    if not (rule["min"] <= number <= rule["max"]):
        raise MullionError("%s must be between %d and %d, got %d"
                           % (key, rule["min"], rule["max"], number))
    return key, str(number)


# ---------------------------------------------------------------------------
# hyprland.lua: the loader block and the require line.
#
# Both are found and removed as exact text or as whole uncommented lines, never
# with a pattern that could reach into the rest of the user's config.

LOADER_BLOCK = '''-- macOS-style title bars. Loaded before Omarchy's defaults so the theme can
-- color the bar. Guarded so a version mismatch can never block login, and the
-- plugin path is only built from a plain absolute home directory.
pcall(function()
  local home = os.getenv("HOME") or ""
  if home:match("^/[%w._/-]+$") and not home:find("%.%.") then
    hl.plugin.load(home .. "/.local/share/hyprland/plugins/hyprbars.so")
  end
end)

'''

# What earlier Mullion releases wrote, upgraded in place when found and removed
# on uninstall.
LEGACY_LOADER_BLOCKS = (
    '''-- macOS-style title bars. Loaded before Omarchy's defaults so the theme can
-- color the bar. Guarded so a version mismatch can never block login.
pcall(function()
  hl.plugin.load(os.getenv("HOME") .. "/.local/share/hyprland/plugins/hyprbars.so")
end)

''',
    '''-- Mac-style title bars with traffic-light buttons (hyprbars plugin).
-- Loaded BEFORE Omarchy's defaults so the active theme can color the bar.
-- pcall-guarded: a plugin built against a different Hyprland version simply
-- doesn't load, and the desktop still starts normally without title bars.
-- Rebuild after a Hyprland update with: ~/.local/bin/rebuild-hyprbars
pcall(function()
  hl.plugin.load(os.getenv("HOME") .. "/.local/share/hyprland/plugins/hyprbars.so")
end)

''',
)

MULLION_REQUIRE = 'require("hypr.mullion")'
_ANCHOR_LINE = re.compile(r'^[ \t]*require\("default\.hypr\.omarchy"\)[ \t]*$', re.M)
_LOOKNFEEL_LINE = re.compile(r'^[ \t]*require\("hypr\.looknfeel"\)[ \t]*$', re.M)
_MULLION_LINE = re.compile(r'^[ \t]*require\("hypr\.mullion"\)[ \t]*$', re.M)
_MULLION_LINE_WITH_BREAK = re.compile(r'^[ \t]*require\("hypr\.mullion"\)[ \t]*(?:\r?\n|\Z)', re.M)
_ACTIVE_HYPRBARS_LOAD = re.compile(r'^(?![ \t]*--).*hyprbars\.so', re.M)


def patch_hyprland_text(text):
    """hyprland.lua with Mullion's loader and require line present.

    Presence is judged by uncommented lines only, so a line the user commented
    out is added back, and insertion points are whole lines, so a mention of a
    module inside a comment is never mistaken for the real thing.
    """
    after = text
    for legacy in LEGACY_LOADER_BLOCKS:
        if legacy in after:
            after = after.replace(legacy, LOADER_BLOCK, 1)
    if LOADER_BLOCK not in after and not _ACTIVE_HYPRBARS_LOAD.search(after):
        anchor = _ANCHOR_LINE.search(after)
        if not anchor:
            raise MullionError('could not find a require("default.hypr.omarchy") line '
                               'in hyprland.lua; leaving it untouched')
        after = after[:anchor.start()] + LOADER_BLOCK + after[anchor.start():]
    if not _MULLION_LINE.search(after):
        looknfeel = _LOOKNFEEL_LINE.search(after)
        if not looknfeel:
            raise MullionError('could not find a require("hypr.looknfeel") line '
                               'in hyprland.lua; leaving it untouched')
        after = after[:looknfeel.end()] + "\n" + MULLION_REQUIRE + after[looknfeel.end():]
    return after


def unpatch_hyprland_text(text):
    """hyprland.lua with exactly what Mullion added taken out, nothing else."""
    after = text
    for block in (LOADER_BLOCK,) + LEGACY_LOADER_BLOCKS:
        after = after.replace(block, "")
    return _MULLION_LINE_WITH_BREAK.sub("", after)


# ---------------------------------------------------------------------------
# Shell-facing entry points, so the installers get the same guarantees.

def _mode(text):
    if not re.fullmatch(r"[0-7]{3}", text):
        raise MullionError("%r is not an octal file mode" % text)
    return int(text, 8)


def _cli_install_file(args):
    """install-file SRC DEST_DIR NAME MODE"""
    src, dest_dir, name, mode = args[0], args[1], args[2], _mode(args[3])
    data = read_source(src)
    fd = owned_dir(dest_dir, create=True)
    try:
        write_atomic(fd, name, data, mode=mode, keep_mode=False)
    finally:
        os.close(fd)


def _cli_install_system_file(args):
    """install-system-file SRC DEST_DIR NAME MODE: source must be root-owned."""
    src, dest_dir, name, mode = args[0], args[1], args[2], _mode(args[3])
    data = read_source(src, require_root=True)
    fd = owned_dir(dest_dir, create=True)
    try:
        write_atomic(fd, name, data, mode=mode, keep_mode=False)
    finally:
        os.close(fd)


def _cli_install_default(args):
    """install-default SRC DEST_DIR NAME: only when the user has none."""
    src, dest_dir, name = args[0], args[1], args[2]
    fd = owned_dir(dest_dir, create=True)
    try:
        if exists_at(fd, name):
            print("keeping")
            return
        write_atomic(fd, name, read_source(src), mode=0o644, keep_mode=False)
        print("wrote")
    finally:
        os.close(fd)


def _cli_ensure_dir(args):
    """ensure-dir DIR: create if needed and verify every component."""
    os.close(owned_dir(args[0], create=True))


def _cli_copy_tree(args):
    print(copy_tree(args[0], args[1]))


def _cli_remove(args):
    """remove DIR NAME...: a missing directory means nothing to remove."""
    if not os.path.lexists(args[0]):
        return
    fd = owned_dir(args[0])
    try:
        for name in args[1:]:
            remove_at(fd, name)
    finally:
        os.close(fd)


def _cli_append_once(args):
    """append-once DIR NAME MARKER SNIPPET: one atomic rewrite, never `>>`."""
    dest_dir, name, marker, snippet = args[0], args[1], args[2], args[3]
    addition = read_source(snippet).decode("utf-8")
    os.close(owned_dir(dest_dir, create=True))
    fd, name = config_target(dest_dir, name)
    try:
        current = read_text_at(fd, name, missing_ok=True) or ""
        if marker in current:
            print("present")
            return
        if current and not current.endswith("\n"):
            current += "\n"
        write_atomic(fd, name, current + addition, mode=0o644)
        print("appended")
    finally:
        os.close(fd)


def _cli_preflight_hyprland(args):
    """preflight-hyprland DIR NAME: prove patch-hyprland would succeed.

    Run before the installer changes anything, so a config it cannot edit
    stops the install at the start rather than leaving it half-applied.
    """
    fd, name = config_target(args[0], args[1])
    try:
        patch_hyprland_text(read_text_at(fd, name))
    finally:
        os.close(fd)
    print("ok")


def _cli_preflight_file(args):
    """preflight-file DIR NAME: the file, if present, is one we can edit."""
    if not os.path.lexists(args[0]):
        print("ok")
        return
    fd, name = config_target(args[0], args[1])
    try:
        read_text_at(fd, name, missing_ok=True)
    finally:
        os.close(fd)
    print("ok")


def _cli_patch_hyprland(args):
    """patch-hyprland DIR NAME STAMP"""
    fd, name = config_target(args[0], args[1])
    try:
        before = read_text_at(fd, name)
        after = patch_hyprland_text(before)
        if after == before:
            print("unchanged")
            return
        backup_at(fd, name, "bak.%s" % args[2])
        write_atomic(fd, name, after, mode=0o644)
        print("patched")
    finally:
        os.close(fd)


def _cli_unpatch_hyprland(args):
    """unpatch-hyprland DIR NAME STAMP"""
    if not os.path.lexists(args[0]):
        print("absent")
        return
    fd, name = config_target(args[0], args[1])
    try:
        before = read_text_at(fd, name, missing_ok=True)
        if before is None:
            print("absent")
            return
        after = unpatch_hyprland_text(before)
        if after == before:
            print("unchanged")
            return
        backup_at(fd, name, "bak.%s" % args[2])
        write_atomic(fd, name, after, mode=0o644)
        print("unpatched")
    finally:
        os.close(fd)


def _cli_check_id(args):
    print(require_plugin_id(args[0]))


def _cli_check_home(args):
    print(require_home())


def _cli_sha256(args):
    """sha256 DIR NAME: digest read through a verified descriptor."""
    fd = owned_dir(args[0])
    try:
        print(sha256_at(fd, args[1]))
    finally:
        os.close(fd)


def _cli_inode(args):
    """inode DIR NAME: device and inode of a regular file, as DEV:INO."""
    fd = owned_dir(args[0])
    try:
        st = os.lstat(args[1], dir_fd=fd)
        if not stat.S_ISREG(st.st_mode):
            raise MullionError("%s is not a regular file" % args[1])
        print("%d:%d" % (st.st_dev, st.st_ino))
    finally:
        os.close(fd)


def _cli_json_field(args):
    """json-field FILE FIELD: one string field, read without shell parsing."""
    value = json.loads(read_source(args[0]).decode("utf-8"))[args[1]]
    if not isinstance(value, str) or any(ord(ch) < 32 for ch in value):
        raise MullionError("%s in %s is not a single-line string" % (args[1], args[0]))
    print(value)


def _cli_verify_tree(args):
    """verify-tree ROOT MANIFEST"""
    print(verify_tree(args[0], args[1]))


def _cli_tree_manifest(args):
    """tree-manifest ROOT: print a manifest for a maintainer to review and ship."""
    for path, digest in sorted(tree_digests(args[0]).items()):
        print("%s  %s" % (digest, path))


RECORD_KEY = re.compile(r"^[a-z][a-z0-9_]{0,39}$")


def _cli_write_record(args):
    """write-record DIR NAME key=value...

    Values arrive as separate arguments and are serialised by json, so nothing
    a compiler or a tool prints is ever pasted into program text.
    """
    dest_dir, name = args[0], args[1]
    record = {}
    for pair in args[2:]:
        key, sep, value = pair.partition("=")
        if not sep or not RECORD_KEY.match(key):
            raise MullionError("%r is not a record field" % pair)
        record[key] = value
    fd = owned_dir(dest_dir, create=True, mode=0o700)
    try:
        write_atomic(fd, name, json.dumps(record, indent=2, sort_keys=True) + "\n",
                     mode=0o600, keep_mode=False)
    finally:
        os.close(fd)


def loaded_image_state(so_path):
    """Which hyprbars image the running Hyprland has mapped.

    "current" when every mapping of a file named hyprbars is exactly so_path
    and the same inode as the file there now; "stale" when an older or deleted
    image, or a hyprbars from somewhere else, is mapped; "unknown" when no
    Hyprland process of ours can be inspected.
    """
    try:
        st = os.stat(so_path)
        # /proc maps shows the path the kernel resolved, so compare against the
        # same resolution; a home reached through a symlink must not look stale.
        real_path = os.path.realpath(so_path)
    except OSError:
        return "unknown"
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            if os.stat("/proc/" + pid).st_uid != os.getuid():
                continue
            with open("/proc/%s/comm" % pid) as handle:
                if handle.read().strip() != "Hyprland":
                    continue
            with open("/proc/%s/maps" % pid) as handle:
                maps = [line for line in handle if "hyprbars" in line]
        except OSError:
            continue
        if not maps:
            return "stale"
        for line in maps:
            fields = line.split(None, 5)
            if len(fields) < 6:
                return "stale"
            if fields[5].strip() != real_path or int(fields[4]) != st.st_ino:
                return "stale"
        return "current"
    return "unknown"


def _cli_remove_tree(args):
    """remove-tree DIR NAME: remove NAME inside DIR, recursively, by descriptor."""
    if not os.path.lexists(args[0]):
        return
    fd = owned_dir(args[0])
    try:
        remove_tree_at(fd, args[1])
    finally:
        os.close(fd)


def _cli_rmdir_if_empty(args):
    """rmdir-if-empty DIR NAME"""
    if not os.path.lexists(args[0]):
        return
    fd = owned_dir(args[0])
    try:
        os.rmdir(args[1], dir_fd=fd)
    except OSError as exc:
        if exc.errno not in (errno.ENOTEMPTY, errno.ENOENT, errno.EEXIST):
            raise
    finally:
        os.close(fd)


STAGE_PREFIX = re.compile(r"^\.[A-Za-z0-9._-]{1,40}$")


def _cli_make_stage(args):
    """make-stage DIR PREFIX: create a private 0700 directory, print its name."""
    if not STAGE_PREFIX.match(args[1]):
        raise MullionError("%r is not a staging prefix" % args[1])
    fd = owned_dir(args[0], create=True)
    try:
        for _ in range(10):
            name = "%s.%s" % (args[1], secrets.token_hex(6))
            try:
                os.mkdir(name, 0o700, dir_fd=fd)
            except FileExistsError:
                continue
            print(name)
            return
        raise MullionError("could not create a staging directory in %s" % args[0])
    finally:
        os.close(fd)


def _cli_rename_in(args):
    """rename-in DIR OLD NEW: rename within a verified directory.

    OLD may name an entry one level down (stage/src). NEW must not exist, so a
    rename can never replace something that is already there.
    """
    old_parts = args[1].split("/")
    if len(old_parts) > 2 or any(p in ("", ".", "..") for p in old_parts):
        raise MullionError("%r is not a plain relative name" % args[1])
    if not args[2] or "/" in args[2] or args[2] in (".", ".."):
        raise MullionError("%r is not a plain name" % args[2])
    fd = owned_dir(args[0])
    src_fd = fd
    try:
        if len(old_parts) == 2:
            src_fd = child_dir(fd, old_parts[0])
        if exists_at(fd, args[2]):
            raise MullionError("%s already exists in %s" % (args[2], args[0]))
        os.rename(old_parts[-1], args[2], src_dir_fd=src_fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        if src_fd != fd:
            os.close(src_fd)
        os.close(fd)


def _cli_loaded_image(args):
    """loaded-image SO_PATH"""
    print(loaded_image_state(args[0]))


CLI = {
    "install-file": _cli_install_file,
    "install-system-file": _cli_install_system_file,
    "install-default": _cli_install_default,
    "ensure-dir": _cli_ensure_dir,
    "copy-tree": _cli_copy_tree,
    "remove": _cli_remove,
    "append-once": _cli_append_once,
    "preflight-hyprland": _cli_preflight_hyprland,
    "preflight-file": _cli_preflight_file,
    "patch-hyprland": _cli_patch_hyprland,
    "unpatch-hyprland": _cli_unpatch_hyprland,
    "check-id": _cli_check_id,
    "check-home": _cli_check_home,
    "sha256": _cli_sha256,
    "inode": _cli_inode,
    "json-field": _cli_json_field,
    "verify-tree": _cli_verify_tree,
    "tree-manifest": _cli_tree_manifest,
    "write-record": _cli_write_record,
    "loaded-image": _cli_loaded_image,
    "remove-tree": _cli_remove_tree,
    "rmdir-if-empty": _cli_rmdir_if_empty,
    "make-stage": _cli_make_stage,
    "rename-in": _cli_rename_in,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in CLI:
        sys.exit("usage: mullionlib.py {%s} ..." % "|".join(sorted(CLI)))
    try:
        require_home()
        CLI[argv[1]](argv[2:])
    except MullionError as exc:
        sys.exit("mullion: %s" % exc)
    except (IndexError, KeyError):
        sys.exit("mullion: bad arguments to %s" % argv[1])
    except (OSError, ValueError, UnicodeError) as exc:
        sys.exit("mullion: %s failed: %s" % (argv[1], exc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
