#!/usr/bin/env python3
"""Protect committed project agent instructions at push and landing.

Protected paths are case-insensitive: CLAUDE.md, CLAUDE.local.md, AGENTS.md and
CONCEPTS.md at any depth, and root .claude/, .codex/ and docs/solutions/.
Both sides of a rename count; only net changes against the merge-base count.
Pushes and land-pr use the merge-base with origin's default branch, because a
push publishes everything that remote lacks; land-local uses the merge-base
with the local branch it fast-forwards. Branch deletions and tags are ignored.

Approval files are <FM_HOME>/data/<task>/agent-file-approval.md. At least one
line must start '> ' and quote the captain; every other nonblank line names
one exact repo-relative path. Workers never write these files. Installed task
markers bake in the absolute approval and checker paths; no override exists.

install <repo> <task> <branch> installs one shared pre-push dispatcher and a
task marker under the working copy's own Git directory. The original pre-push
is preserved as pre-push.firstmate-original and chained with its arguments and
stdin. Other hooks and Git configuration are untouched. If no-mistakes is
configured, the same dispatcher checks that task's destination branch in its
bare gate, including commits the pipeline adds. An unregistered gate branch
cannot borrow any task's approval; only a push to the default branch of
commits already on the project's own local default branch passes unchecked.
Installs for one project take turns through the owner-PID lock in
fm-wake-lib.sh on the project's hooks directory, held while the dispatchers
and records of the project and its gate are published; no-mistakes keeps one
gate per project, so that lock is the gate's too. A dead installer's lock is
recovered, and a live one makes a second install refuse with a retry hint.
Dispatchers and records are renamed into place from unique temporary files,
and the original pre-push is hard-linked to its preserved name first, so
an interrupted install keeps a pre-push in place and a retry completes it.
remove deletes task markers and gate entries, skipping a gate that no longer
exists; shared dispatchers remain inert without them.

check --repo <repo> --task <task> --approval <absolute-file> reads standard
pre-push input, or accepts --head <commit> for landing; --primary <git-dir>
replaces --approval for unregistered gate branches. Only unlisted protected
paths are printed on refusal. land-pr <task> <number> fetches the current PR
head from the task project into a comparison ref it deletes after the check,
whatever the outcome; land-local <task> <commit> <base> checks a pinned
head against the local branch it lands on.
The registered ai-workspace entry in data/projects.md identifies the exemption
through the home itself or projects/ai-workspace, never a directory basename.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

BIN = Path(__file__).resolve().parent
MARKER = "fm-agent-file-task.json"
REFUSAL = "Append needs-decision [key=agent-file-approval] to the status file and stop."
HOLD_LOCK = ('. "$1"; fm_lock_try_acquire "$2" || { echo "another install holds $2'
             ' (pid ${FM_LOCK_HELD_PID:-unknown}); retry after it finishes" >&2; exit 1; }; '
             'echo held; read -r _; fm_lock_release "$2"')


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def git_text(repo, *args):
    return os.fsdecode(git(repo, *args)).strip()


def optional_git(repo, *args):
    try:
        return git_text(repo, *args)
    except subprocess.CalledProcessError:
        return ""


def common_dir(repo):
    return Path(git_text(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()


def home():
    return Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or BIN.parent).resolve()


def data_dir():
    return Path(os.environ.get("FM_DATA_OVERRIDE") or home() / "data").resolve()


def exempt(repo):
    registry = data_dir() / "projects.md"
    if not registry.exists() or not re.search(r"^- ai-workspace(?:\s|$)", registry.read_text(), re.M):
        return False
    projects = Path(os.environ.get("FM_PROJECTS_OVERRIDE") or home() / "projects")
    return any(optional_git(candidate, "rev-parse", "--path-format=absolute", "--git-common-dir")
               and common_dir(repo) == common_dir(candidate)
               for candidate in (home(), projects / "ai-workspace"))


def valid_task(task):
    subprocess.run(["bash", "-c", '. "$1"; fm_task_id_path_safe "$2"',
                    "protected-paths", str(BIN / "fm-pr-lib.sh"), task], check=True)
    return task


def protected(path):
    lower = path.lower()
    return (lower.rsplit("/", 1)[-1] in {"claude.md", "claude.local.md", "agents.md", "concepts.md"}
            or lower.startswith((".claude/", ".codex/", "docs/solutions/")))


def approval_paths(path):
    if path is None:
        return set()
    if not path.is_absolute():
        raise ValueError("approval file must be absolute")
    if not path.exists():
        return set()
    lines = path.read_text().splitlines()
    if not any(line.startswith("> ") and line[2:].strip() for line in lines):
        return set()
    return {line for line in lines if line.strip() and not line.startswith("> ")}


def remote_default(repo):
    try:
        return subprocess.check_output([str(BIN / "fm-diff-base.sh"), str(repo)], text=True).strip()
    except subprocess.CalledProcessError:
        raise ValueError(f"cannot resolve the comparison base for {repo}") from None


def captain_default(primary, base, ref, sha):
    branch = "refs/heads/" + base.removeprefix("origin/")
    return ref == branch and subprocess.run(
        ["git", "--git-dir", str(primary), "merge-base", "--is-ancestor", sha, branch],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def check(repo, task, approval, heads, base_ref):
    changed = set()
    for head in heads:
        base = git_text(repo, "merge-base", base_ref, head)
        # --no-renames emits both sides as independent net paths, including
        # renames Git's similarity heuristic would not recognize.
        names = git(repo, "diff", "--name-only", "--no-renames", "-z", base, head, "--")
        changed.update(os.fsdecode(name) for name in names.split(b"\0") if name and protected(os.fsdecode(name)))
    unlisted = sorted(changed - approval_paths(approval))
    if unlisted:
        print("Unapproved protected changes:", file=sys.stderr)
        for path in unlisted:
            print("  " + path, file=sys.stderr)
        print(REFUSAL, file=sys.stderr)
        raise ValueError(f"protected changes require captain approval for task {task}")


def task_record(repo, task, branch):
    valid_task(task)
    git(repo, "check-ref-format", "refs/heads/" + branch)
    return {"task": task, "ref": "refs/heads/" + branch,
            "checker": str(BIN / "fm-protected-paths.sh"), "project": str(common_dir(repo)),
            "approval": str(home() / "data" / task / "agent-file-approval.md")}


def write_file(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    stream = tempfile.NamedTemporaryFile("wb", dir=path.parent, prefix="." + path.name + ".", suffix=".tmp", delete=False)
    try:
        with stream:
            stream.write(data)
        os.chmod(stream.name, mode)
        os.replace(stream.name, path)
    except BaseException:
        os.unlink(stream.name)
        raise


def write_json(path, record):
    write_file(path, (json.dumps(record) + "\n").encode())


@contextlib.contextmanager
def install_lock(hooks):
    """Hold fm-wake-lib.sh's owner-PID lock through a bash child that releases it when stdin closes."""
    lock = hooks / ".fm-protected-install.lock"
    holder = subprocess.Popen(["bash", "-c", HOLD_LOCK, "protected-paths", str(BIN / "fm-wake-lib.sh"), str(lock)],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        if holder.stdout.readline() != b"held\n":
            raise ValueError(f"install lock {lock} is held")
        yield
    finally:
        holder.stdin.close()
        holder.wait()


def publish_hook(hooks):
    hook = hooks / "pre-push"
    template = b'#!/bin/sh\n# firstmate-protected-pre-push-v1\nexec python3 -I "$(dirname "$0")/fm-protected-pre-push.py" "$@"\n'
    write_file(hooks / "fm-protected-pre-push.py", (BIN / "fm-protected-pre-push.py").read_bytes())
    if hook.exists() and hook.read_bytes() == template:
        return
    if hook.exists() or hook.is_symlink():
        original = hooks / "pre-push.firstmate-original"
        if not (original.exists() or original.is_symlink()):
            os.link(hook, original, follow_symlinks=False)
        elif not os.path.samestat(os.lstat(original), os.lstat(hook)):
            raise ValueError("existing pre-push and preserved hook need reconciliation")
    write_file(hook, template, 0o755)


def hooks_dir(repo):
    hooks = common_dir(repo) / "hooks"
    configured = optional_git(repo, "config", "--get", "core.hooksPath")
    if configured and Path(git_text(repo, "rev-parse", "--git-path", "hooks")).resolve() != hooks:
        raise ValueError("needs-decision [key=gate-install]: project uses a different hooks directory")
    hooks.mkdir(exist_ok=True)
    return hooks


def gate_repo(repo, missing_ok=False):
    remote = optional_git(repo, "remote", "get-url", "no-mistakes")
    if not remote:
        return None
    gate = Path(remote)
    if not gate.is_absolute():
        gate = (Path(repo) / gate).resolve()
    if missing_ok and not gate.exists():
        return None
    if git_text(gate, "rev-parse", "--is-bare-repository") != "true":
        raise ValueError("no-mistakes remote is not a local bare gate repository")
    return gate


def install(repo, task, branch):
    if exempt(repo):
        return
    record = task_record(repo, task, branch)
    gate = gate_repo(repo)
    hooks = hooks_dir(repo)
    gate_hooks = gate and hooks_dir(gate)
    with install_lock(hooks):
        publish_hook(hooks)
        if gate_hooks:
            publish_hook(gate_hooks)
            name = hashlib.sha256(record["ref"].encode()).hexdigest() + ".json"
            entry = gate_hooks / "fm-agent-file-tasks" / name
            if entry.exists() and json.loads(entry.read_text()) != record:
                raise ValueError("no-mistakes branch is already assigned to another task")
            write_json(entry, record)
        git_dir = Path(git_text(repo, "rev-parse", "--absolute-git-dir"))
        write_json(git_dir / MARKER, record)


def remove(repo, task):
    git_dir = Path(git_text(repo, "rev-parse", "--absolute-git-dir"))
    marker = git_dir / MARKER
    if not marker.exists():
        return
    record = json.loads(marker.read_text())
    if record["task"] != task:
        raise ValueError("task marker belongs to a different task")
    gate = gate_repo(repo, missing_ok=True)
    if gate:
        entries = common_dir(gate) / "hooks" / "fm-agent-file-tasks"
        if entries.is_dir():
            for entry in entries.glob("*.json"):
                if json.loads(entry.read_text()) == record:
                    entry.unlink()
    marker.unlink()


def landing(task, head=None, number=None, base=None):
    valid_task(task)
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or home() / "state")
    meta = dict(line.split("=", 1) for line in (state / (task + ".meta")).read_text().splitlines() if "=" in line)
    repo = Path(meta["project"])
    if exempt(repo):
        return
    approval = home() / "data" / task / "agent-file-approval.md"
    if number is None:
        check(repo, task, approval, [head], base)
        return
    ref = "refs/fm-protected/pull/" + number
    try:
        base = remote_default(repo)
        git(repo, "fetch", "--quiet", "origin", "+refs/pull/" + number + "/head:" + ref)
        check(repo, task, approval, [git_text(repo, "rev-parse", ref + "^{commit}")], base)
    finally:
        git(repo, "update-ref", "-d", ref)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("install", "remove"):
        child = sub.add_parser(command)
        child.add_argument("repo", type=Path)
        child.add_argument("task")
        if command == "install":
            child.add_argument("branch")
    child = sub.add_parser("check")
    child.add_argument("--repo", type=Path, required=True)
    child.add_argument("--task", required=True)
    child.add_argument("--approval", type=Path)
    child.add_argument("--primary", type=Path)
    child.add_argument("--head")
    for command, names in (("land-pr", ("number",)), ("land-local", ("head", "base"))):
        child = sub.add_parser(command)
        child.add_argument("task")
        for name in names:
            child.add_argument(name)
    args = parser.parse_args()
    if args.command == "install":
        install(args.repo.resolve(), args.task, args.branch)
    elif args.command == "remove":
        remove(args.repo.resolve(), args.task)
    elif args.command == "check":
        valid_task(args.task)
        pushed = []
        if args.head:
            pushed.append((None, args.head))
        else:
            for line in sys.stdin:
                local_ref, sha, remote_ref, remote_sha = line.split()
                if remote_ref.startswith("refs/heads/") and set(sha) != {"0"}:
                    pushed.append((remote_ref, sha))
        if pushed:
            base = remote_default(args.repo)
            if args.primary:
                pushed = [(ref, sha) for ref, sha in pushed if not captain_default(args.primary, base, ref, sha)]
            check(args.repo, args.task, args.approval, [sha for _, sha in pushed], base)
    elif args.command == "land-pr":
        landing(args.task, number=args.number)
    else:
        landing(args.task, head=args.head, base=args.base)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(os.fsdecode(error.stderr).strip(), file=sys.stderr)
        print(f"protected paths: {error}", file=sys.stderr)
        sys.exit(1)
