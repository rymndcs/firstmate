#!/usr/bin/env python3
"""Protect committed project agent instructions at push and landing.

Protected paths are case-insensitive: CLAUDE.md, CLAUDE.local.md, AGENTS.md and
CONCEPTS.md at any depth, and root .claude/, .codex/ and docs/solutions/.
Both sides of a rename count; only net changes against the branch's merge-base
count. Branch deletions and tags are ignored.

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
cannot borrow any task's approval. remove deletes task markers
and gate entries; shared dispatchers remain inert without them.

check --repo <repo> --task <task> --approval <absolute-file> reads standard
pre-push input, or accepts --head <commit> for landing. Only unlisted protected
paths are printed on refusal. land-pr <task> <number> fetches the current PR
head from the task project; land-local <task> <commit> checks a pinned head.
The registered ai-workspace entry in data/projects.md identifies the exemption
through the home itself or projects/ai-workspace, never a directory basename.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BIN = Path(__file__).resolve().parent
MARKER = "fm-agent-file-task.json"
REFUSAL = "Append needs-decision [key=agent-file-approval] to the status file and stop."


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


def check(repo, task, approval, heads):
    if not heads:
        return
    base_ref = subprocess.check_output([str(BIN / "fm-diff-base.sh"), str(repo)], text=True).strip()
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
            "checker": str(BIN / "fm-protected-paths.sh"),
            "approval": str(home() / "data" / task / "agent-file-approval.md")}


def write_json(path, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".lock")
    with temporary.open("x") as stream:
        json.dump(record, stream)
        stream.write("\n")
    temporary.replace(path)


def install_hook(repo):
    hooks = common_dir(repo) / "hooks"
    configured = optional_git(repo, "config", "--get", "core.hooksPath")
    if configured and Path(git_text(repo, "rev-parse", "--git-path", "hooks")).resolve() != hooks:
        raise ValueError("needs-decision [key=gate-install]: project uses a different hooks directory")
    hooks.mkdir(exist_ok=True)
    lock = hooks / ".fm-protected-install.lock"
    lock.touch(exist_ok=False)
    try:
        hook = hooks / "pre-push"
        template = b'#!/bin/sh\n# firstmate-protected-pre-push-v1\nexec python3 -I "$(dirname "$0")/fm-protected-pre-push.py" "$@"\n'
        managed = hook.exists() and hook.read_bytes() == template
        helper = hooks / "fm-protected-pre-push.py"
        if helper.exists() and not managed:
            raise ValueError("existing hook helper needs reconciliation")
        helper_tmp = hooks / "fm-protected-pre-push.py.lock"
        with helper_tmp.open("xb") as stream:
            stream.write((BIN / "fm-protected-pre-push.py").read_bytes())
        helper_tmp.replace(helper)
        if hook.exists() or hook.is_symlink():
            if managed:
                return hooks
            original = hooks / "pre-push.firstmate-original"
            if original.exists() or original.is_symlink():
                raise ValueError("existing pre-push and preserved hook need reconciliation")
            hook.rename(original)
        with hook.open("xb") as stream:
            stream.write(template)
        hook.chmod(0o755)
    finally:
        lock.unlink()
    return hooks


def gate_repo(repo):
    remote = optional_git(repo, "remote", "get-url", "no-mistakes")
    if not remote:
        return None
    gate = Path(remote)
    if not gate.is_absolute():
        gate = (Path(repo) / gate).resolve()
    if git_text(gate, "rev-parse", "--is-bare-repository") != "true":
        raise ValueError("no-mistakes remote is not a local bare gate repository")
    return gate


def install(repo, task, branch):
    if exempt(repo):
        return
    record = task_record(repo, task, branch)
    install_hook(repo)
    gate = gate_repo(repo)
    if gate:
        hooks = install_hook(gate)
        name = hashlib.sha256(record["ref"].encode()).hexdigest() + ".json"
        entry = hooks / "fm-agent-file-tasks" / name
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
    gate = gate_repo(repo)
    if gate:
        entries = common_dir(gate) / "hooks" / "fm-agent-file-tasks"
        if entries.is_dir():
            for entry in entries.glob("*.json"):
                if json.loads(entry.read_text()) == record:
                    entry.unlink()
    marker.unlink()


def landing(task, head=None, number=None):
    valid_task(task)
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or home() / "state")
    meta = dict(line.split("=", 1) for line in (state / (task + ".meta")).read_text().splitlines() if "=" in line)
    repo = Path(meta["project"])
    if exempt(repo):
        return
    if number is not None:
        ref = "refs/fm-protected/pull/" + number
        git(repo, "fetch", "--quiet", "origin", "+refs/pull/" + number + "/head:" + ref)
        head = git_text(repo, "rev-parse", ref + "^{commit}")
    check(repo, task, home() / "data" / task / "agent-file-approval.md", [head])


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
    child.add_argument("--head")
    for command, arg in (("land-pr", "number"), ("land-local", "head")):
        child = sub.add_parser(command)
        child.add_argument("task")
        child.add_argument(arg)
    args = parser.parse_args()
    if args.command == "install":
        install(args.repo.resolve(), args.task, args.branch)
    elif args.command == "remove":
        remove(args.repo.resolve(), args.task)
    elif args.command == "check":
        valid_task(args.task)
        heads = []
        if args.head:
            heads.append(args.head)
        else:
            for line in sys.stdin:
                local_ref, sha, remote_ref, remote_sha = line.split()
                if remote_ref.startswith("refs/heads/") and set(sha) != {"0"}:
                    heads.append(sha)
        check(args.repo, args.task, args.approval, heads)
    elif args.command == "land-pr":
        landing(args.task, number=args.number)
    else:
        landing(args.task, head=args.head)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(os.fsdecode(error.stderr).strip(), file=sys.stderr)
        print(f"protected paths: {error}", file=sys.stderr)
        sys.exit(1)
