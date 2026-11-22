#!/usr/bin/env bash
# Drop only task-owned scratch databases recorded in state/<id>.databases.
# Usage: fm-task-databases.sh <task-meta> <database-record>
#        fm-task-databases.sh --create <database-record> <database-name>
# --create runs createdb, then captures pg_database.oid and appends the identity
# only on success. A failed creation or catalog read never registers a name.
# Each record line is an exact local database name, TAB, its creation-time OID.
# Names use 1-63 ASCII letters/digits/underscore/hyphen, starting without a hyphen;
# OIDs are positive decimal PostgreSQL OIDs. No URLs or connection options.
# Never backfill missing OIDs from a database currently using a recorded name.
# Missing records do nothing. Duplicate identities drop once; absence is complete.
# A different current OID refuses cleanup and preserves the replacement for retry.
# Names are never inferred from task IDs, ticket numbers, branches or patterns.
# Protected database names, databases derived from existing recorded project
# copies and their worktrees, and names claimed by another task are refused.
# Each drop is one `dropdb <name>` invocation against localhost:5432, never FORCE.
# A fresh catalog query counts all connections before each drop; connected names
# are reported and retained. PostgreSQL also refuses a drop if a connection opens
# after that query. No connection is terminated. Query, validation and drop errors
# return 1 after reporting unfinished names, preserving the record for retry.
# Teardown owns the landed-work proof and removes the record only on completion.
set -eu
if [ "${1:-}" = --help ]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit 0
fi
exec python3 - "$@" <<'PY'
import posix
import sys
try:
    cwd = posix.getcwd()
except OSError:
    cwd = ''
sys.path[:] = [p for p in sys.path if p not in ('', cwd)]
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess


def read_record(path):
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise ValueError(f'unsafe database record {path}')
    return path.read_bytes()


def valid_name(name):
    return re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_-]{0,62}', name)


def valid_oid(oid):
    return re.fullmatch(r'[1-9][0-9]*', oid) and int(oid) <= 4294967295


def identities_from(raw, path):
    identities = []
    for line, entry in enumerate(raw.decode().splitlines(), 1):
        fields = entry.split('\t')
        if not valid_name(fields[0]):
            raise ValueError(f'invalid database name in {path} at line {line}: {entry!r}')
        if len(fields) != 2 or not valid_oid(fields[1]):
            raise ValueError(f'invalid database identity in {path} at line {line}: {entry!r}')
        identities.append(tuple(fields))
    return list(dict.fromkeys(identities))


def metadata(path):
    rows = read_record(path).decode().splitlines()
    values = {}
    for key in ('worktree', 'project'):
        entries = [line.split('=', 1)[1] for line in rows if line.startswith(key + '=')]
        if len(entries) != 1 or not Path(entries[0]).is_absolute():
            raise ValueError(f'missing or ambiguous {key} in task metadata')
        values[key] = entries[0]
    return values


def checkout_names(project, worktree):
    output = subprocess.check_output(['git', '-C', project, 'worktree', 'list', '--porcelain', '-z'])
    paths = [os.fsdecode(field[9:]) for field in output.split(b'\0') if field.startswith(b'worktree ')]
    if not paths:
        raise ValueError('project worktree inventory is unavailable')
    paths.extend((project, worktree))
    paths = set(paths) | {os.path.realpath(path) for path in paths}
    protected = set()
    for path in paths:
        if not Path(path).exists():
            continue
        digest = hashlib.sha256(os.path.abspath(path).encode()).hexdigest()[:32]
        protected.update(f'racingr_wms_{kind}_{digest}' for kind in ('dev', 'test'))
        name = Path(path).name
        slug = re.sub(r'[^a-zA-Z0-9_]', '', name.replace('-', '_'))
        if len(slug) > 52:
            slug = slug[:44] + '_' + hashlib.sha1(name.encode()).hexdigest()[:7]
        test_slug = slug if len(slug) <= 45 else slug[:37] + '_' + hashlib.sha1(name.encode()).hexdigest()[:7]
        protected.update(f'thanos_{kind}_{slug}' for kind in ('dev', 'mx', 'ac'))
        protected.update(f'thanos_{kind}_{test_slug}' for kind in ('test', 'mxtest', 'actest'))
    return protected


def protected_name(name, slots):
    return (name in {'postgres', 'template0', 'template1', 'thanos_development', 'thanos_template',
                     'racingr_wms_dev', 'racingr_wms_test'}
            or re.search(r'(^|_)(production|prod|development)(_|$)', name, re.IGNORECASE)
            or any(name == slot or re.fullmatch(re.escape(slot) + r'-[0-9]+', name) for slot in slots))


def ownership(meta, record, raw, meta_raw):
    if read_record(meta) != meta_raw:
        raise ValueError('task metadata changed during database cleanup')
    values = metadata(meta)
    if read_record(record) != raw:
        raise ValueError('database record changed during cleanup')
    slots = checkout_names(values['project'], values['worktree'])
    other_names = set()
    for peer in record.parent.glob('*.meta'):
        peer_record = peer.with_suffix('.databases')
        if peer == meta:
            continue
        if os.path.lexists(peer_record):
            other_names.update(name for name, _ in identities_from(read_record(peer_record), peer_record))
        peer_values = metadata(peer)
        for path in set(peer_values.values()):
            if Path(path).is_dir():
                slots.update(checkout_names(path, path))
    return slots, other_names


def database_env():
    env = dict(os.environ, PGHOST='localhost', PGHOSTADDR='127.0.0.1', PGPORT='5432',
               PGDATABASE='postgres', PGCONNECT_TIMEOUT='5')
    for key in ('PGSERVICE', 'PGSERVICEFILE', 'PGOPTIONS'):
        env.pop(key, None)
    return env


def catalog(query, env):
    return subprocess.check_output(['psql', '-X', '-w', '-tA', '-d', 'postgres',
                                    '-v', 'ON_ERROR_STOP=1', '-c', query], env=env).decode().splitlines()


def create(record, name):
    if not valid_name(name):
        raise ValueError(f'invalid database name {name!r}')
    if os.path.lexists(record):
        identities_from(read_record(record), record)
    env = database_env()
    subprocess.run(['createdb', name], env=env, check=True)
    result = catalog(f"SELECT d.oid FROM pg_database d WHERE d.datname = '{name}'", env)
    if len(result) != 1 or not valid_oid(result[0]):
        raise ValueError(f'creation OID unavailable for {name}; database is not registered')
    with record.open('ab') as handle:
        handle.write(f'{name}\t{result[0]}\n'.encode())
    return True


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--create':
        return create(Path(sys.argv[2]), sys.argv[3])
    if len(sys.argv) != 3:
        raise ValueError('usage: fm-task-databases.sh <task-meta> <database-record> | --create <database-record> <name>')
    meta, record = map(Path, sys.argv[1:])
    if not os.path.lexists(record):
        return True
    raw = read_record(record)
    identities = identities_from(raw, record)
    if not identities:
        return True
    meta_raw = read_record(meta)
    slots, peers = ownership(meta, record, raw, meta_raw)
    for name, _ in identities:
        if protected_name(name, slots) or name in peers:
            raise ValueError(f'protected or shared database {name}; correct the task record')
    env = database_env()
    complete, freed = True, 0
    for name, oid in identities:
        try:
            query = ("SELECT d.datname, d.oid, (SELECT count(*) FROM pg_stat_activity a WHERE a.datid = d.oid), "
                     f"pg_database_size(d.oid) FROM pg_database d WHERE d.datname = '{name}'")
            result = catalog(query, env)
            if not result:
                continue
            if len(result) != 1:
                raise ValueError('unexpected database catalog result')
            fields = result[0].split('|')
            if len(fields) != 4 or fields[0] != name or not valid_oid(fields[1]) or not all(re.fullmatch(r'[0-9]+', v) for v in fields[2:]):
                raise ValueError('invalid database catalog result')
            if fields[1] != oid:
                raise ValueError(f'identity changed: recorded OID {oid}, current OID {fields[1]}')
            if int(fields[2]):
                print(f'database cleanup: kept {name}: {fields[2]} open connection(s)', flush=True)
                complete = False
                continue
            latest_slots, latest_peers = ownership(meta, record, raw, meta_raw)
            if protected_name(name, latest_slots) or name in latest_peers:
                raise ValueError('database ownership changed during cleanup')
            subprocess.run(['dropdb', name], env=env, check=True)
            freed += int(fields[3])
            print(f'database cleanup: dropped {name}', flush=True)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            print(f'database cleanup: kept {name}: {exc}', file=sys.stderr, flush=True)
            complete = False
    print(f'database cleanup: freed ~{freed} bytes', flush=True)
    return complete


try:
    sys.exit(0 if main() else 1)
except (OSError, ValueError, UnicodeError, subprocess.SubprocessError) as exc:
    print(f'REFUSED: database cleanup: {exc}', file=sys.stderr)
    sys.exit(1)
PY
