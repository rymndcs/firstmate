#!/usr/bin/env bash
# Private implementation for fm-teardown.sh's ignored-artifact cleanup.
# Git selects ignored, untracked paths; tracked and non-ignored paths are never
# selected, even with teardown --force. KEEP below is the single retention list:
# directory names match at any depth; vendor/bundle is a path suffix, while .env
# and .env.* retain private environment configuration. Everything else ignored
# is disposable task material. Symlinks are unlinked, never traversed; only a
# build-output link below the recorded tasktmp in a temporary root also removes
# its resolved target. Unattributed temporary targets and nested repositories stay.
# Requires python3 on supported Unix hosts.
# Space is estimated from allocated blocks (hard-linked files do not count).
#
# --free-slot <project> <pool-directory> <slot-name> requires Treehouse's JSON
# status and treehouse-state.json/treehouse-state.lock protocol (flock on Unix).
# It checks an available status against an unchanged pool snapshot while holding
# Treehouse's own lock through cleanup, without leasing, resetting or returning.
# A changed snapshot refuses; rerun only after checking current pool status.
# This private entry point's --worktree mode is called only after teardown guards.
set -eu
exec python3 - "$@" <<'PY'
import fcntl
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import sys

KEEP = ("node_modules", "vendor/bundle", ".venv", "venv", ".bundle", ".env", ".env.*")
BUILD_OUTPUT = ("target", ".build", "build")
TEMP_ROOTS = ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def keep(relative):
    parts = relative.parts
    return any(fnmatch.fnmatchcase("/".join(parts[i:]), pattern)
               for i in range(len(parts)) for pattern in KEEP)


def cleanup(root, task_temp=""):
    root = Path(root).resolve()
    owned_temp = Path(task_temp).resolve() if task_temp else None
    candidates = git(root, "ls-files", "--others", "--ignored", "--exclude-standard",
                     "--directory", "-z").split(b"\0")
    removed = 0
    freed = 0
    names = []

    def remove(path, relative, external=False):
        nonlocal removed, freed
        if not external and keep(relative):
            return
        st = path.lstat()
        if path.is_symlink():
            try:
                target = path.resolve()
            except (OSError, RuntimeError):
                target = None
            if (target is not None and not external and path.name in BUILD_OUTPUT
                    and owned_temp in target.parents and target not in root.parents):
                for temporary in TEMP_ROOTS:
                    temporary = Path(temporary).resolve()
                    if temporary in target.parents:
                        if target.exists():
                            repository = subprocess.run(
                                ["git", "-C", str(target), "rev-parse", "--git-dir"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            if repository.returncode != 0:
                                remove(target, Path(target.name), external=True)
                        break
            path.unlink()
        elif path.is_dir():
            if (path / ".git").exists():
                return
            for child in path.iterdir():
                remove(child, relative / child.name, external)
            if any(path.iterdir()):
                return
            path.rmdir()
        else:
            path.unlink()
        removed += 1
        if st.st_nlink == 1:
            freed += st.st_blocks * 512

    for raw in candidates:
        if raw:
            relative = Path(os.fsdecode(raw.rstrip(b"/")))
            before = removed
            remove(root / relative, relative)
            if removed != before:
                names.append(str(relative))
    shown = ", ".join(repr(name) for name in names[:8]) or "none"
    if len(names) > 8:
        shown += f", +{len(names) - 8} more"
    print(f"cleanup: removed {removed} ignored entries ({shown}); freed ~{freed} bytes")


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
        cleanup(root)


try:
    if sys.argv[1] == "--free-slot":
        free_slot(*sys.argv[2:])
    else:
        cleanup(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
    print(f"REFUSED: ignored cleanup: {exc}", file=sys.stderr)
    sys.exit(1)
PY
