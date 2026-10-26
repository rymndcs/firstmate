#!/usr/bin/env python3
# firstmate-protected-pre-push-v1
"""Installed in git-common-dir/hooks; inert without a task marker or gate entry."""
import json
import pathlib
import subprocess
import sys


def main():
    payload = sys.stdin.buffer.read()
    hook_dir = pathlib.Path(__file__).resolve().parent
    git_dir = pathlib.Path(subprocess.check_output(
        ["git", "rev-parse", "--absolute-git-dir"], text=True).strip())
    marker = git_dir / "fm-agent-file-task.json"
    checks = []
    if marker.exists():
        checks.append((json.loads(marker.read_text()), payload))
    else:
        entries = hook_dir / "fm-agent-file-tasks"
        if entries.is_dir():
            tasks = [json.loads(path.read_text()) for path in entries.glob("*.json")]
            for task in tasks:
                selected = b"".join(line for line in payload.splitlines(keepends=True)
                                    if line.split()[2:3] == [task["ref"].encode()])
                if selected:
                    checks.append((task, selected))
            if tasks:
                registered = {task["ref"].encode() for task in tasks}
                unknown = b"".join(line for line in payload.splitlines(keepends=True)
                                   if line.split()[2:3] and line.split()[2] not in registered)
                if unknown:
                    checks.append(({**tasks[0], "task": "unregistered-branch", "approval": None}, unknown))
    for task, selected in checks:
        command = [task["checker"], "check", "--repo", str(pathlib.Path.cwd()), "--task", task["task"]]
        if task["approval"] is None:
            command.extend(["--primary", task["project"]])
        else:
            command.extend(["--approval", task["approval"]])
        result = subprocess.run(command, input=selected)
        if result.returncode:
            return result.returncode
    original = hook_dir / "pre-push.firstmate-original"
    if original.exists() and original.stat().st_mode & 0o111:
        return subprocess.run([str(original), *sys.argv[1:]], input=payload).returncode
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"protected paths: {error}", file=sys.stderr)
        sys.exit(1)
