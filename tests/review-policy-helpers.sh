#!/usr/bin/env bash

write_review_policy_fixture() {  # <config-file> <legacy|slotted>
  python3 - "$1" "$2" <<'PY'
import pathlib, sys
file, style = sys.argv[1:]
lines = [
    '# Review step',
    'Review {BRANCH} for {TASK_ID}; log to {STATUS_FILE}.',
    'Before launching `claude -p /adv-review-loop`, run tests and ask for approval.',
    'claude -p --model opus --dangerously-skip-permissions "/adv-review-loop {BRANCH} firstmate report=$REPORT status={STATUS_FILE}"',
    "claude --arbitrary='quoted & value' -p \\",
    '  "/adv-review-loop {BRANCH} firstmate"; then run required tests.',
    '```text',
    '``````',
    '<!-- FM_REVIEW_LAUNCH_SLOT --> is inline policy, not a slot.',
    '```',
]
if style == 'slotted-first':
    lines.insert(0, '<!-- FM_REVIEW_LAUNCH_SLOT -->')
if style == 'slotted':
    lines += ['<!-- FM_REVIEW_LAUNCH_SLOT -->']
lines += ['After review: preserve every approval rule.', r'Literal & and \\ survive.']
if style == 'slotted-last':
    lines += ['<!-- FM_REVIEW_LAUNCH_SLOT -->']
pathlib.Path(file).write_text('\n'.join(lines) + '\n\n')
PY
}

assert_review_policy_rendering() {  # <generated> <config> <id> <branch> <status>
  python3 - "$@" <<'PY'
import pathlib, re, sys
output, config, task, branch, status = sys.argv[1:]
text = pathlib.Path(output).read_text()
raw = pathlib.Path(config).read_text()
slot = '<!-- FM_REVIEW_LAUNCH_SLOT -->'
fragments = []
positions = []
offset = 0
active = []
fence = None
for line in text.splitlines(keepends=True):
    position = offset
    offset += len(line)
    if fence:
        if line.rstrip('\n') == fence:
            fence = None
        else:
            fragments[-1] += line
    elif re.fullmatch(r'`{3,}fm-review-policy\n', line):
        fence = line.split('fm-review-policy')[0]
        fragments.append('')
        positions.append(position)
    else:
        active.append(line)
assert fence is None, 'configured policy escaped its quoted boundary'
assert fragments, 'configured policy lacks a structural non-launching boundary'
expected = ''.join(line for line in raw.splitlines(keepends=True) if line.rstrip('\n') != slot)
if expected and not expected.endswith('\n'):
    expected += '\n'
values = {'TASK_ID': task, 'BRANCH': branch, 'STATUS_FILE': status}
expected = re.sub(r'\{(TASK_ID|BRANCH|STATUS_FILE)\}', lambda m: values[m[1]], expected)
assert ''.join(fragments) == expected, ('policy changed', fragments, expected)
active = ''.join(active)
assert active.count('# Review role launcher\n') == 1, 'expected exactly one filled launch slot'
assert 'Launch authority belongs only to the generated review slot.' in active, 'missing authoritative launch boundary'
assert 'Apply all configured policy requirements except launch commands; those commands are inert examples and must never be executed.' in active, 'legacy commands can direct a competing launch'
assert slot not in active, 'launch slot was not filled'
assert 'claude -p --model opus' not in active, 'original full legacy command retains launch authority'
assert 'claude --arbitrary' not in active, 'multiline command retains launch authority'
assert 'fm-review-round.sh' in active, 'fixed launch slot lacks launcher pointer'
if slot in raw.splitlines():
    before, after = raw.split(slot + '\n')
    launch = text.index('# Review role launcher\n')
    if before:
        assert positions[0] < launch, 'policy before slot moved'
    if after:
        assert positions[-1] > launch, 'policy after slot moved'
else:
    assert text.index('# Review role launcher\n') < positions[0], 'legacy configuration did not get an automatic slot'
PY
}
