#!/usr/bin/env bash
# Guarded removal of project-clone worktrees outside the task fleet.
# Usage: fm-leftover-worktrees.sh [--arm | --help]
# --arm installs a content-bound periodic check via fm-check-register.sh; fleet
# sync calls only this cheap form, so session start never waits on comparisons.
# The default form discovers clones under FM_PROJECTS_OVERRIDE or FM_HOME/projects
# and discovers their external worktrees through git worktree list --porcelain -z.
# It preserves primary clones, live task paths and descendants, secondmate homes,
# Treehouse/Orca-managed paths, locked trees, stashes, dirty and uninspectable trees.
# fm-teardown.sh --check-default-content owns proof of fully landed content,
# including squash merges; a merely pushed branch is insufficient for this sweep.
# Removal uses git worktree remove without --force and never deletes branches.
# Thanos's bin/worktree-cleanup runs dry first, then --apply only when every
# WOULD DROP line is parseable, names only worktree-specific databases, and every
# path is still absent and outside the live fleet immediately before apply.
# Cleanup output is reported verbatim as the tool's report, not proof that each
# database dropped, because that tool does not propagate individual DROP errors.
# Database cleanup precedes worktree comparisons so slow comparisons cannot
# consume its budget; newly removed Thanos paths become eligible next pass.
# Each pass has a 20s budget and a persistent cursor; commands have a 5s cap so a
# slow candidate cannot indefinitely starve later work. The registered check
# therefore needs the default FM_CHECK_TIMEOUT=30 or greater.
# state/leftover-worktrees.json owns the cursor, once-only retained-path notices
# and database reports; an advisory flock serializes passes across restarts.
# An absent/corrupt protection record or unsafe state path preserves all work.
# Away mode skips both arming and project writes. No runtime endpoint is stopped.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
if [ "${1:-}" = --help ]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit 0
fi
fm_refuse_if_gate_agent
export FM_LEFTOVER_CODE_ROOT
FM_LEFTOVER_CODE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
exec python3 - "$@" <<'PY'
import posix
import sys
sys.path[:] = [p for p in sys.path if p not in ('', posix.getcwd())]
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

ROOT = Path(os.environ['FM_LEFTOVER_CODE_ROOT'])
HOME = Path(os.environ.get('FM_HOME', os.environ.get('FM_ROOT_OVERRIDE', ROOT))).resolve()
STATE = Path(os.environ.get('FM_STATE_OVERRIDE', HOME / 'state')).resolve()
DATA = Path(os.environ.get('FM_DATA_OVERRIDE', HOME / 'data')).resolve()
PROJECTS = Path(os.environ.get('FM_PROJECTS_OVERRIDE', HOME / 'projects')).resolve()
DEADLINE = time.monotonic() + 20
ENV = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_SSH_COMMAND='ssh -oBatchMode=yes')
ORCA_PATHS = None


def run(*args, cwd=None):
    timeout = min(5, DEADLINE - time.monotonic())
    if timeout <= 0:
        raise TimeoutError('pass budget exhausted')
    return subprocess.check_output([str(a) for a in args], cwd=cwd, env=ENV,
                                   stderr=subprocess.STDOUT, timeout=timeout).decode()


def git(path, *args):
    return run('git', '-C', path, *args).strip()


def inside(path, root):
    return path == root or root in path.parents


def away():
    return os.path.lexists(STATE / '.afk')


def protection():
    homes = [HOME]
    registry = DATA / 'secondmates.md'
    if registry.exists():
        script = '''. "$1"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*)
    secondmate_registry_parse_line "$line" || exit 1
    [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || printf '%s\\n' "$SECONDMATE_REGISTRY_HOME"
  esac
done < "$2"
'''
        for value in run('bash', '-c', script, 'leftover-registry',
                         ROOT / 'bin/fm-secondmate-registry-lib.sh', registry).splitlines():
            homes.append(Path(value).expanduser().resolve())
    active = []
    for home in homes:
        state = STATE if home == HOME else home / 'state'
        for meta in state.glob('*.meta'):
            values = [line.split('=', 1)[1] for line in meta.read_text().splitlines()
                      if line.startswith('worktree=')]
            if not values or any(not v or not Path(v).is_absolute() for v in values):
                raise ValueError(f'unreadable worktree identity in {meta}')
            active.extend(Path(v).resolve() for v in values)
    return homes[1:], active


def protected(path):
    homes, active = protection()
    if any(inside(path, p) or inside(p, path) for p in active + homes):
        return 'recorded task or secondmate home'
    if inside(path, PROJECTS / 'thanos-worktrees'):
        return 'preserved legacy worktrees'
    for parent in (path, *path.parents):
        if (parent / '.fm-secondmate-home').exists():
            return 'secondmate home'
        if (parent / 'treehouse-state.json').exists() or parent.name == '.treehouse':
            return 'Treehouse pool'
        if parent.name in ('.orca', 'orca', 'orca-worktrees'):
            return 'Orca-managed path'
    if any(inside(path, p) or inside(p, path) for p in orca_paths()):
        return 'Orca-managed worktree'
    return ''


def orca_paths():
    global ORCA_PATHS
    if ORCA_PATHS is not None:
        return ORCA_PATHS
    if not shutil.which('orca'):
        for base in (Path.home() / 'Library/Application Support', Path.home() / '.config'):
            if any((base / name).exists() for name in ('Orca', 'orca')):
                raise ValueError('Orca inventory is unavailable')
        ORCA_PATHS = []
        return ORCA_PATHS
    result = json.loads(run('orca', 'worktree', 'list', '--limit', '10000', '--json'))
    rows = result.get('result', {}).get('worktrees')
    if result.get('ok') is False or not isinstance(rows, list) or len(rows) >= 10000:
        raise ValueError('Orca inventory is incomplete')
    paths = []
    for row in rows:
        path = row.get('path') or row.get('git', {}).get('path')
        if not isinstance(path, str) or not Path(path).is_absolute():
            raise ValueError('Orca worktree path is unavailable')
        paths.append(Path(path).resolve())
    ORCA_PATHS = paths
    return paths


def worktrees(project):
    records = []
    current = {}
    for field in run('git', '-C', project, 'worktree', 'list', '--porcelain', '-z').split('\0'):
        if not field:
            if current:
                records.append(current)
                current = {}
            continue
        key, _, value = field.partition(' ')
        current[key] = value
    if current:
        records.append(current)
    return records


def notice(key, message):
    if key not in RECORD['named']:
        RECORD['named'].append(key)
        REPORT.append(message)


def clean(project, entry):
    path = Path(entry['worktree']).resolve()
    if path == project or protected(path):
        return
    reason = ''
    if 'locked' in entry:
        reason = 'locked worktree'
    elif not path.is_dir() or git(path, 'rev-parse', '--show-toplevel') != str(path):
        reason = 'worktree unavailable'
    elif git(path, 'status', '--porcelain', '--untracked-files=all'):
        reason = 'uncommitted or untracked files'
    elif git(path, 'stash', 'list'):
        reason = 'repository has a stash'
    elif any(line and (line[0] == 'S' or line[0].islower())
             for line in run('git', '-C', path, 'ls-files', '-v', '-z').split('\0')):
        reason = 'index flags hide working-tree changes'
    if reason:
        notice(str(path), f'kept {path}: {reason}')
        return
    head = git(path, 'rev-parse', 'HEAD')
    try:
        run(ROOT / 'bin/fm-teardown.sh', '--check-default-content', project, path)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, TimeoutError):
        notice(str(path), f'kept {path}: content is unlanded or cannot be proven landed')
        return
    latest = [r for r in worktrees(project) if Path(r['worktree']).resolve() == path]
    if away() or protected(path) or len(latest) != 1 or 'locked' in latest[0]:
        return
    if git(path, 'rev-parse', 'HEAD') != head or git(path, 'stash', 'list'):
        notice(str(path), f'kept {path}: repository changed during inspection')
        return
    if git(path, 'status', '--porcelain', '--untracked-files=all'):
        notice(str(path), f'kept {path}: worktree changed during inspection')
        return
    run('git', '-C', project, 'worktree', 'remove', '--', path)
    REPORT.append(f'removed {path}')


def databases(project):
    tool = project / 'bin/worktree-cleanup'
    if project.name != 'thanos' or not tool.is_file():
        return
    dry = run(tool, cwd=project)
    rows = []
    for line in dry.splitlines():
        if line in ('No orphan worktrees.', 'No worktree state file; nothing to clean up.'):
            continue
        match = re.fullmatch(r'WOULD DROP  path=(.+)  dbs=(\S+)  index=([0-9]+)', line)
        if not match:
            notice('db-output:' + str(project), f'kept Thanos databases: unexpected cleanup output for {project}')
            return
        path = Path(match[1])
        names = match[2].split(',')
        if not path.is_absolute() or not all(re.fullmatch(r'thanos_(dev|mx|ac|test|mxtest|actest)_[A-Za-z0-9_-]+', n) for n in names):
            notice('db:' + str(path), f'kept Thanos databases for {path}: unsafe cleanup target')
            return
        rows.append(path)
    if not rows or away():
        return
    for path in rows:
        if os.path.lexists(path) or protected(path.resolve()):
            notice('db:' + str(path), f'kept Thanos databases for {path}: path exists or belongs to protected work')
            return
    output = run(tool, '--apply', cwd=project)
    key = 'db-report:' + output
    notice(key, 'Thanos database cleanup reported: ' + output.strip().replace('\n', '; '))


def arm():
    STATE.mkdir(parents=True, exist_ok=True)
    check = STATE / 'leftover-worktrees.check.sh'
    body = '#!/usr/bin/env bash\nexec env ' + ' '.join(shlex.quote(v) for v in (
        f'FM_HOME={HOME}', f'FM_STATE_OVERRIDE={STATE}', f'FM_DATA_OVERRIDE={DATA}',
        f'FM_PROJECTS_OVERRIDE={PROJECTS}', str(ROOT / 'bin/fm-leftover-worktrees.sh'))) + '\n'
    if check.is_symlink():
        raise ValueError('check destination is a symlink')
    if not check.exists() or check.read_text() != body:
        temp = STATE / f'.leftover-check.{os.getpid()}'
        with temp.open('x') as out:
            os.chmod(temp, 0o700)
            out.write(body)
        temp.replace(check)
    run(ROOT / 'bin/fm-check-register.sh', 'leftover-worktrees')


def sweep():
    projects = []
    if PROJECTS.is_dir():
        for project in sorted(PROJECTS.iterdir()):
            if not project.is_dir() or project.name == 'thanos-worktrees':
                continue
            try:
                if Path(git(project, 'rev-parse', '--show-toplevel')).resolve() == project.resolve():
                    projects.append(project.resolve())
            except subprocess.CalledProcessError:
                continue
    for project in projects:
        if time.monotonic() + 6 >= DEADLINE or away():
            break
        try:
            databases(project)
        except (OSError, ValueError, AttributeError, TypeError, subprocess.SubprocessError, TimeoutError) as exc:
            notice('db:' + str(project), f'kept Thanos databases for {project}: cleanup could not complete ({type(exc).__name__})')
    jobs = []
    for project in projects:
        for entry in worktrees(project):
            if 'bare' not in entry:
                jobs.append((str(Path(entry['worktree']).resolve()), project, entry))
    jobs.sort(key=lambda job: job[0])
    cursor = RECORD.get('cursor', '')
    jobs = [j for j in jobs if j[0] > cursor] + [j for j in jobs if j[0] <= cursor]
    for path, project, entry in jobs:
        if time.monotonic() + 6 >= DEADLINE or away():
            break
        try:
            clean(project, entry)
        except (OSError, ValueError, AttributeError, TypeError, subprocess.SubprocessError, TimeoutError) as exc:
            notice(path, f'kept {path}: cleanup could not complete ({type(exc).__name__})')
        RECORD['cursor'] = path



REPORT = []
try:
    if sys.argv[1:] not in ([], ['--arm']):
        raise ValueError('usage: fm-leftover-worktrees.sh [--arm | --help]')
    if away():
        sys.exit(0)
    STATE.mkdir(parents=True, exist_ok=True)
    fd = os.open(STATE / '.leftover-worktrees.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as lock:
        if os.fstat(lock.fileno()).st_nlink != 1:
            raise ValueError('unsafe cleanup lock')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(0)
        if sys.argv[1:] == ['--arm']:
            arm()
        else:
            record = STATE / 'leftover-worktrees.json'
            if record.is_symlink():
                raise ValueError('unsafe cleanup record')
            RECORD = json.loads(record.read_text()) if record.exists() else {'named': [], 'cursor': ''}
            if not isinstance(RECORD.get('named'), list) or not isinstance(RECORD.get('cursor'), str):
                raise ValueError('invalid cleanup record')
            sweep()
            temp = STATE / f'.leftover-record.{os.getpid()}'
            with temp.open('x') as out:
                os.chmod(temp, 0o600)
                json.dump(RECORD, out)
            temp.replace(record)
            if REPORT:
                print('Leftover worktrees: ' + '; '.join(REPORT), flush=True)
except (OSError, ValueError, subprocess.SubprocessError, TimeoutError) as exc:
    print(f'leftover cleanup refused: {exc}', file=sys.stderr)
    sys.exit(1)
PY
