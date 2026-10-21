#!/usr/bin/env bash
# Private implementation for fm-teardown.sh's ignored-artifact cleanup.
# Git selects ignored, untracked paths; tracked and non-ignored paths are never
# selected. A path git lists inside another listed directory is handled with
# that directory, never again on its own. KEEP below is the single retention
# list: names match at any depth and entries with a slash match as a path
# suffix, except that deps below a target or build directory is compiler output
# (target/debug/deps, build/cargo/debug/deps) and goes. It holds
# reusable dependency installs, .env* private configuration, live Lavish review
# sessions and local agent configuration or notes. Everything else ignored is
# disposable task material. A read-only directory inside an ignored worktree
# path being removed is made writable first; a retained one gets its mode back,
# and nothing outside the worktree or behind a link is ever made writable.
# Symlinks are unlinked, never traversed. Every directory the task listed, one
# absolute path per line, in its temporary-target record
# (state/<task-id>.temp-targets) is removed whole, whether or not a link
# reaches it. A listed path must lie inside a temporary root, and must not be
# or hold the caller's TMPDIR. A build-output link whose target lies below the
# recorded tasktmp also removes that target. Neither removal touches the
# worktree, a directory holding it, or a git repository. Every other existing
# temporary target outside the worktree is kept, and the report names it with
# its size so firstmate can decide. Nested repositories stay.
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
# return terminates) or inside a recorded directory it will remove, never one it
# keeps, except this process and its callers: SIGTERM, then SIGKILL
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
COMPILER_OUTPUT = {"target", "build"}
BUILD_OUTPUT = ("target", ".build", "build")
TEMP_ROOTS = tuple(Path(p).resolve() for p in ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders"))


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def repository(path):
    return subprocess.run(["git", "-C", str(path), "rev-parse", "--git-dir"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def keep(relative):
    parts = relative.parts
    return any(fnmatch.fnmatchcase("/".join(parts[i:]), pattern)
               and (pattern != "deps" or not COMPILER_OUTPUT.intersection(parts[:i]))
               for pattern in KEEP for i in range(len(parts)))


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


def writers(roots):
    table = processes()
    protected, pid = set(), os.getpid()
    while pid in table and pid not in protected:
        protected.add(pid)
        pid = table[pid][0]
    return {pid for pid, (_, cwd) in table.items()
            if pid not in protected and any(within(root, cwd) for root in roots)}


def stop_writers(roots):
    grace = float(os.environ.get("FM_WORKTREE_CLEANUP_STOP_GRACE_SECS", "2"))
    for sig in (signal.SIGTERM, signal.SIGKILL):
        targets = writers(roots)
        if not targets:
            return
        for pid in targets:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        deadline = time.monotonic() + grace
        while targets & writers(roots) and time.monotonic() < deadline:
            time.sleep(0.05)
    survivors = writers(roots)
    if survivors:
        raise OSError("processes survived termination: "
                      + ", ".join(str(pid) for pid in sorted(survivors)))


def allocated(path):
    total = path.lstat().st_blocks * 512
    for directory, dirs, files in os.walk(path):
        for name in dirs + files:
            total += os.lstat(os.path.join(directory, name)).st_blocks * 512
    return total


def recorded_targets(record):
    try:
        lines = Path(record).read_text().splitlines() if record else []
    except FileNotFoundError:
        lines = []
    user_temp = Path(os.environ.get("TMPDIR", "/tmp")).resolve()
    recorded = []
    for line in lines:
        if os.path.isabs(line):
            entry = Path(line).resolve()
            if any(temporary in entry.parents for temporary in TEMP_ROOTS) and not within(entry, user_temp):
                recorded.append(entry)
    return recorded


class Cleanup:
    def __init__(self, root, task_temp="", recorded=()):
        self.root = Path(root).resolve()
        self.owned = [Path(task_temp).resolve()] if task_temp else []
        self.recorded = recorded
        self.removed = 0
        self.freed = 0
        self.names = []
        self.kept = {}
        self.failed = []

    def outside(self, target):
        return (target.exists() and any(temporary in target.parents for temporary in TEMP_ROOTS)
                and not within(target, self.root) and not within(self.root, target))

    def removable_recorded(self):
        return [entry for entry in self.recorded if self.outside(entry) and not repository(entry)]

    def release(self, target, owned):
        if not self.outside(target):
            return
        if owned and not repository(target):
            self.remove(target, Path(target.name), external=True)
        else:
            self.kept[target] = allocated(target)

    def release_target(self, link):
        try:
            target = link.resolve()
        except (OSError, RuntimeError):
            return
        if not any(within(entry, target) for entry in self.recorded):
            self.release(target, link.name in BUILD_OUTPUT and any(within(owned, target) for owned in self.owned))

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
        listed = [Path(os.fsdecode(raw.rstrip(b"/"))) for raw in git(
            self.root, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"
        ).split(b"\0") if raw]
        tops = set(listed)
        for relative in listed:
            if not any(parent in tops for parent in relative.parents):
                before = self.removed
                self.remove(self.root / relative, relative)
                if self.removed != before:
                    self.names.append(str(relative))
        for entry in self.recorded:
            before = self.removed
            self.release(entry, True)
            if self.removed != before:
                self.names.append(str(entry))
        shown = ", ".join(repr(name) for name in self.names[:8]) or "none"
        if len(self.names) > 8:
            shown += f", +{len(self.names) - 8} more"
        line = f"cleanup: removed {self.removed} ignored entries ({shown}); freed ~{self.freed} bytes"
        if self.kept:
            line += "; kept temporary targets: " + ", ".join(
                f"'{target}' (~{size} bytes)" for target, size in self.kept.items())
        if self.failed:
            line += "; failed: " + ", ".join(f"'{path}' ({error})" for path, error in self.failed)
        print(line)
        return not self.failed


def worktree(root, task_temp="", record=""):
    cleanup = Cleanup(root, task_temp, recorded_targets(record))
    stop_writers([cleanup.root, *cleanup.removable_recorded()])
    return cleanup.run()


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
