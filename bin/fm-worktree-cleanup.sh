#!/usr/bin/env bash
# Private implementation for fm-teardown.sh's ignored-artifact cleanup.
# Git selects ignored, untracked paths; tracked and non-ignored paths are never
# selected. KEEP below is the single retention list: names match at any depth,
# entries with a slash match as a path suffix, and it holds reusable dependency
# installs, .env* private configuration, live Lavish review sessions and local
# agent configuration or notes. Everything else ignored is disposable task
# material. A read-only directory inside an ignored worktree path being removed
# is made writable first; a retained one gets its mode back, and nothing outside
# the worktree or behind a link is ever made writable.
# Symlinks are unlinked, never traversed. A build-output link whose target lies
# in a temporary root also removes that target only when the task owns it:
# below the recorded tasktmp, or at or below an absolute path the task listed,
# one per line, in its temporary-target record (state/<task-id>.temp-targets)
# when it created that directory. A listed path must lie inside a temporary
# root. Every other existing temporary link target outside the worktree is kept,
# and the report names it with its size so firstmate can decide. Nested
# repositories stay.
# A path that cannot be removed does not stop the rest; the one report line
# lists completed removals, freed space and each failing path, and the exit
# status is 1. Space is estimated from allocated blocks (hard-linked files do
# not count). Requires python3 on macOS (libproc) or Linux (/proc).
# The caller's working directory may be a worktree holding worker code, so the
# script drops it ('' and its absolute path) from sys.path before any other
# import; the rest of PYTHONPATH still applies.
#
# --worktree <worktree> <tasktmp> [<temp-target-record>] first stops every
# process whose working directory is inside the worktree (the set Treehouse's
# return terminates), except this process and its callers: SIGTERM, then SIGKILL
# after FM_WORKTREE_CLEANUP_STOP_GRACE_SECS (default 2, Treehouse's own return
# grace). It refuses without deleting when it cannot inspect processes or one
# survives. Teardown calls it only after the landed-work guards passed and while
# the slot is still leased, so no writer recreates output and no new task can
# be handed the slot before cleanup finishes.
#
# --free-slot <project> <pool-directory> <slot-name> requires Treehouse's JSON
# status and treehouse-state.json/treehouse-state.lock protocol (flock on Unix).
# It checks an available status against an unchanged pool snapshot while holding
# Treehouse's own lock through cleanup, without leasing, resetting or returning.
# A changed snapshot refuses; rerun only after checking current pool status.
set -eu
exec python3 - "$@" <<'PY'
import posix
import sys
try:
    cwd = posix.getcwd()
except OSError:
    cwd = ""
sys.path[:] = [entry for entry in sys.path if entry not in ("", cwd)]

import ctypes
import fcntl
import fnmatch
import json
import os
from pathlib import Path
import signal
import stat
import struct
import subprocess
import time

KEEP = ("node_modules", "vendor/bundle", ".venv", "venv", ".bundle", "deps", ".yarn/cache",
        "Pods", ".terraform", ".gradle", "bower_components", ".env*", ".lavish",
        ".claude", ".codex", ".agents", "CLAUDE.local.md")
BUILD_OUTPUT = ("target", ".build", "build")
TEMP_ROOTS = tuple(Path(p).resolve() for p in ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders"))


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def keep(relative):
    parts = relative.parts
    return any(fnmatch.fnmatchcase("/".join(parts[i:]), pattern)
               for i in range(len(parts)) for pattern in KEEP)


def within(parent, path):
    return path == parent or parent in path.parents


def processes():
    table = {}
    if sys.platform == "darwin":
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        count = libproc.proc_listallpids(None, 0)
        pids = (ctypes.c_int * (count + 64))()
        count = libproc.proc_listallpids(pids, ctypes.sizeof(pids))
        for pid in pids[:count]:
            paths = ctypes.create_string_buffer(2352)  # struct proc_vnodepathinfo
            bsd = ctypes.create_string_buffer(136)  # struct proc_bsdinfo
            if (libproc.proc_pidinfo(pid, 9, ctypes.c_uint64(0), paths, 2352) == 2352
                    and libproc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), bsd, 136) == 136):
                table[pid] = (struct.unpack_from("I", bsd.raw, 16)[0],
                              Path(os.fsdecode(paths.raw[152:1176].split(b"\0", 1)[0])))
    else:
        for name in os.listdir("/proc"):
            if name.isdigit():
                try:
                    with open(f"/proc/{name}/stat", "rb") as status:
                        ppid = int(status.read().rsplit(b")", 1)[1].split()[1])
                    table[int(name)] = (ppid, Path(os.readlink(f"/proc/{name}/cwd")))
                except OSError:
                    pass
    if os.getpid() not in table:
        raise OSError("cannot inspect which processes use the worktree")
    return table


def writers(root):
    table = processes()
    protected, pid = set(), os.getpid()
    while pid in table and pid not in protected:
        protected.add(pid)
        pid = table[pid][0]
    return {pid for pid, (_, cwd) in table.items() if pid not in protected and within(root, cwd)}


def stop_writers(root):
    grace = float(os.environ.get("FM_WORKTREE_CLEANUP_STOP_GRACE_SECS", "2"))
    for sig in (signal.SIGTERM, signal.SIGKILL):
        targets = writers(root)
        if not targets:
            return
        for pid in targets:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        deadline = time.monotonic() + grace
        while targets & writers(root) and time.monotonic() < deadline:
            time.sleep(0.05)
    survivors = writers(root)
    if survivors:
        raise OSError("worktree processes survived termination: "
                      + ", ".join(str(pid) for pid in sorted(survivors)))


def allocated(path):
    total = path.lstat().st_blocks * 512
    for directory, dirs, files in os.walk(path):
        for name in dirs + files:
            total += os.lstat(os.path.join(directory, name)).st_blocks * 512
    return total


def owned_roots(task_temp, record):
    owned = [Path(task_temp).resolve()] if task_temp else []
    try:
        lines = Path(record).read_text().splitlines() if record else []
    except FileNotFoundError:
        lines = []
    for line in lines:
        if os.path.isabs(line):
            entry = Path(line).resolve()
            if any(temporary in entry.parents for temporary in TEMP_ROOTS):
                owned.append(entry)
    return owned


class Cleanup:
    def __init__(self, root, owned=()):
        self.root = Path(root).resolve()
        self.owned = owned
        self.removed = 0
        self.freed = 0
        self.names = []
        self.kept = {}
        self.failed = []

    def release_target(self, link):
        try:
            target = link.resolve()
        except (OSError, RuntimeError):
            return
        if (not target.exists() or not any(temporary in target.parents for temporary in TEMP_ROOTS)
                or within(target, self.root) or within(self.root, target)):
            return
        if (link.name in BUILD_OUTPUT and any(within(owned, target) for owned in self.owned)
                and subprocess.run(["git", "-C", str(target), "rev-parse", "--git-dir"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0):
            self.remove(target, Path(target.name), external=True)
        else:
            self.kept[target] = allocated(target)

    def remove(self, path, relative, external=False):
        if not external and keep(relative):
            return False
        try:
            st = path.lstat()
            if stat.S_ISLNK(st.st_mode):
                if not external:
                    self.release_target(path)
                path.unlink()
            elif stat.S_ISDIR(st.st_mode):
                if (path / ".git").exists():
                    return False
                widened = not external and st.st_mode & 0o700 != 0o700
                if widened:
                    os.chmod(path, st.st_mode | 0o700)
                if not all([self.remove(child, relative / child.name, external)
                            for child in sorted(path.iterdir())]):
                    if widened:
                        os.chmod(path, stat.S_IMODE(st.st_mode))
                    return False
                path.rmdir()
            else:
                path.unlink()
        except OSError as exc:
            self.failed.append((path, exc.strerror or str(exc)))
            return False
        self.removed += 1
        if st.st_nlink == 1:
            self.freed += st.st_blocks * 512
        return True

    def run(self):
        candidates = git(self.root, "ls-files", "--others", "--ignored", "--exclude-standard",
                         "--directory", "-z").split(b"\0")
        for raw in candidates:
            if raw:
                relative = Path(os.fsdecode(raw.rstrip(b"/")))
                before = self.removed
                self.remove(self.root / relative, relative)
                if self.removed != before:
                    self.names.append(str(relative))
        shown = ", ".join(repr(name) for name in self.names[:8]) or "none"
        if len(self.names) > 8:
            shown += f", +{len(self.names) - 8} more"
        line = f"cleanup: removed {self.removed} ignored entries ({shown}); freed ~{self.freed} bytes"
        if self.kept:
            line += "; kept temporary link targets: " + ", ".join(
                f"'{target}' (~{size} bytes)" for target, size in self.kept.items())
        if self.failed:
            line += "; failed: " + ", ".join(f"'{path}' ({error})" for path, error in self.failed)
        print(line)
        return not self.failed


def worktree(root, task_temp="", record=""):
    root = Path(root).resolve()
    stop_writers(root)
    return Cleanup(root, owned_roots(task_temp, record)).run()


def free_slot(project, pool, name):
    pool = Path(pool)
    state_path = pool / "treehouse-state.json"
    before = state_path.read_bytes()
    statuses = json.loads(subprocess.check_output(
        ["treehouse", "status", "--json"], cwd=project))
    with (pool / "treehouse-state.lock").open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        after = state_path.read_bytes()
        if before != after:
            raise ValueError("pool changed during inspection; inspect status and retry")
        entries = [e for e in json.loads(after)["worktrees"] if e["name"] == name]
        if len(entries) != 1:
            raise ValueError("slot is missing or ambiguous")
        entry = entries[0]
        if entry.get("leased"):
            raise ValueError("slot is leased")
        if any(entry.get(key) for key in ("owner_pid", "destroying", "lease_id", "recovery_error")):
            raise ValueError("slot has an outstanding reservation or recovery state")
        statuses = [s for s in statuses if s["name"] == name and s["path"] == entry["path"]]
        if len(statuses) != 1 or statuses[0]["status"] != "available":
            raise ValueError("slot is not available")
        root = entry["path"]
        default = subprocess.run(["git", "-C", root, "symbolic-ref", "refs/remotes/origin/HEAD"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        base = default.stdout.decode().strip().rsplit("/", 1)[-1] if default.returncode == 0 else "main"
        if subprocess.run(["git", "-C", root, "merge-base", "--is-ancestor", "HEAD", base],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            raise ValueError("slot has work not landed on its default branch")
        return Cleanup(root).run()


try:
    if sys.argv[1] == "--free-slot":
        complete = free_slot(*sys.argv[2:])
    else:
        complete = worktree(*sys.argv[2:])
except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
    print(f"REFUSED: ignored cleanup: {exc}", file=sys.stderr)
    sys.exit(1)
sys.exit(0 if complete else 1)
PY
