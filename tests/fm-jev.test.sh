#!/usr/bin/env bash
# Deterministic public-interface tests using fresh temporary tools and fixtures.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev)
export JEV_TEST_ROOT="$TMP_ROOT" JEV_SCRIPT="$ROOT/bin/fm-jev.sh"
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/security" <<'PY'
#!/usr/bin/env python3
import os
import pathlib
import sys
root = pathlib.Path(os.environ['JEV_TEST_ROOT'])
assert sys.argv[1:] == ['find-generic-password', '-s', 'dev.friday.typesafe', '-w']
with (root / 'credential-calls').open('a') as f:
    f.write('read\n')
if (root / 'key-error').exists():
    print('sensitive-provider-error', file=sys.stderr)
    sys.exit(1)
print('fixture-only-key')
PY
cat > "$TMP_ROOT/fakebin/curl" <<'PY'
#!/usr/bin/env python3
import json
import os
import pathlib
import sys
root = pathlib.Path(os.environ['JEV_TEST_ROOT'])
assert 'fixture-only-key' not in ' '.join(sys.argv)
assert sys.argv[1:] == ['--disable', '--silent', '--fail', '--connect-timeout', '5', '--max-time', '30', '--config', '-']
config = sys.stdin.read().splitlines()
assert json.loads(config[1].split(' = ', 1)[1]) == 'Authorization: Bearer fixture-only-key'
assert json.loads(config[0].split(' = ', 1)[1]) == 'https://api.typesafe.ai/v1/systemone'
request = json.loads(json.loads(config[3].split(' = ', 1)[1]))
(root / 'request.json').write_text(json.dumps(request))
if (root / 'curl-error').exists():
    print('sensitive-provider-error fixture-only-key', file=sys.stderr)
    sys.exit(22)
print((root / 'response.json').read_text())
PY
chmod +x "$TMP_ROOT/fakebin/security" "$TMP_ROOT/fakebin/curl"
export PATH="$TMP_ROOT/fakebin:$PATH"
python3 - <<'PY'
import json
import os
import pathlib
import subprocess

root = pathlib.Path(os.environ['JEV_TEST_ROOT'])
script = os.environ['JEV_SCRIPT']


def response(probabilities, **changes):
    answer = {'type': 'choice', 'choice': max(probabilities, key=lambda k: probabilities[k] if type(probabilities[k]) in (int, float) else -1),
              'probabilities': probabilities, 'confidence': 0.01}
    answer.update(changes)
    (root / 'response.json').write_text(json.dumps({'answers': {'ranking': answer}}))


def call(options=None, models=False):
    args = [script] + (['--models'] if models else [])
    return subprocess.run(args + ['Choose a worker? "quoted"\nnext line', 'Context ☃\nwith evidence',
                                 json.dumps(['continue', 'stop'] if options is None else options)],
                          capture_output=True, text=True)


def success(options=None, models=False):
    result = call(options, models)
    assert result.returncode == 0, result.stderr
    assert result.stderr == '', result.stderr
    assert 'fixture-only-key' not in result.stdout
    return json.loads(result.stdout)


def failure(options=None):
    result = call(options)
    assert result.returncode != 0, result.stdout
    assert result.stdout == '', result.stdout
    assert 'ask the captain' in result.stderr, result.stderr
    assert 'fixture-only-key' not in result.stderr
    assert 'sensitive-provider-error' not in result.stderr


response({'0': 0.1, '1': 0.9})
output = success()
assert output['confident'] == 'yes'
assert output['threshold'] == 0.9
assert output['mode'] == 'decision' and output['automatic'] == 'no'
assert output['rankings'] == [
    {'option': 'stop', 'probability': 0.9, 'captain_permission_required': False},
    {'option': 'continue', 'probability': 0.1, 'captain_permission_required': False},
]
request = json.loads((root / 'request.json').read_text())
assert request['model'] == 'jev-latest'
assert request['state']['context'] == 'Context ☃\nwith evidence'
assert request['questions']['ranking'] == {
    'type': 'choice', 'instructions': 'Choose a worker? "quoted"\nnext line',
    'criteria': {'0': 'continue', '1': 'stop'},
}
print('ok - fm-jev.sh: live Choice contract, complete stable ranking and inclusive threshold')

response({'0': 0.899999, '1': 0.100001}, confidence=1)
assert success()['confident'] == 'no'
response({'0': 0.5, '1': 0.5})
assert [r['option'] for r in success()['rankings']] == ['continue', 'stop']
response({'0': 0.99, '1': 0.01})
assert success()['confident'] == 'yes'
assert len((root / 'credential-calls').read_text().splitlines()) == 4
print('ok - fm-jev.sh: below-bar result, ties, high probability and fresh credential reads')

candidates = [{'model': 'provider/Fable', 'effort': 'high'},
              {'model': 'gpt-6-astra', 'effort': 'medium'},
              {'model': 'gpt-6-sol', 'effort': 'xhigh'},
              {'model': 'gpt-6-sol', 'effort': 'high'}]
response({'0': 0.01, '1': 0.96, '2': 0.01, '3': 0.02})
output = success(candidates, True)
assert output['confident'] == 'yes' and output['automatic'] == 'no'
assert output['mode'] == 'models' and 'selected' not in output
assert [r['option'] for r in output['rankings']] == [candidates[1], candidates[3], candidates[0], candidates[2]]
assert [r['captain_permission_required'] for r in output['rankings']] == [True, False, True, True]
response({'0': 0.25, '1': 0.25, '2': 0.25, '3': 0.25})
assert all(r['captain_permission_required'] for r in
           success(['FABLE-preview', 'openai/gpt-6-astra', 'gpt-6-sol XHIGH', 'fable'], True)['rankings'])
request = json.loads((root / 'request.json').read_text())
assert 'Task: Choose a worker?' in request['questions']['ranking']['instructions']
assert list(request['questions']['ranking']['criteria'].values()) == ['FABLE-preview', 'openai/gpt-6-astra', 'gpt-6-sol XHIGH', 'fable']
print('ok - fm-jev.sh: model rankings are advisory and protected models/effort require permission')

for probabilities in [{'0': 1}, {'0': 0.5, '1': 0.4, 'unknown': 0.1},
                      {'0': 1.1, '1': -0.1}, {'0': 0.9, '1': 0.9},
                      {'0': True, '1': False}, {'0': '0.9', '1': 0.1},
                      {'0': float('nan'), '1': 1}]:
    response(probabilities)
    failure()
response({'0': 0.9, '1': 0.1}, choice='1')
failure()
response({'0': 0.9, '1': 0.1}, type='score')
failure()
for body in ['not json', '{}', '{"answers":{"ranking":null}}']:
    (root / 'response.json').write_text(body)
    failure()
print('ok - fm-jev.sh: malformed, mismatched, incomplete and invalid probabilities require confirmation')

for marker in ['key-error', 'curl-error']:
    (root / marker).touch()
    failure()
    (root / marker).unlink()
print('ok - fm-jev.sh: Keychain and transport errors are clear, nonzero and redact credentials')

calls_before = (root / 'credential-calls').read_text()
for options in [[], ['only'], ['', 'stop'], ['same', 'same'], 'bad', [None, 'stop'], ['a'] * 256,
                [{'model': 'gpt-6-sol'}, 'stop']]:
    failure(options)
assert (root / 'credential-calls').read_text() == calls_before
result = subprocess.run([script, '--help'], capture_output=True, text=True)
assert result.returncode == 0 and '--models' in result.stdout
assert (root / 'credential-calls').read_text() == calls_before
print('ok - fm-jev.sh: invalid inputs and help never read credentials or contact Jev')
PY
