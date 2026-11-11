#!/usr/bin/env bash
# Exercise omp transition enforcement through the real arm and drain entrypoints.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-omp-watch-transition)
FM_TEST_CLEANUP_DIRS+=("$LAB")
trap fm_test_cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/state" "$LAB/data" "$LAB/config"
for file in fm-watch-arm.sh fm-wake-drain.sh fm-wake-lib.sh fm-classify-lib.sh; do
  cp "$ROOT/bin/$file" "$LAB/bin/"
done
if [ -f "$ROOT/bin/fm-omp-watch-transition.sh" ]; then
  cp "${FM_TRANSITION_IMPLEMENTATION:-$ROOT/bin/fm-omp-watch-transition.sh}" "$LAB/bin/fm-omp-watch-transition.sh"
fi
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
cat > "$LAB/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
printf 'launched\n' >> "$FM_HOME/launches"
printf 'heartbeat: fixture\n'
SH
cat > "$LAB/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
exec "$FM_TRANSITION_SOURCE/bin/fm-fleet-snapshot.sh" "$@"
SH
for file in fm-jira.sh fm-pr-auto-register.sh fm-guard.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/$file"
done
chmod +x "$LAB/bin/"*.sh
export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state"
export FM_DATA_OVERRIDE="$LAB/data" FM_CONFIG_OVERRIDE="$LAB/config"
export FM_TRANSITION_SOURCE="$ROOT" OMPCODE=1 PI_SESSION_ID=normal PI_TOOL_CALL_ID=first
ARM="$LAB/bin/fm-watch-arm.sh"
DRAIN="$LAB/bin/fm-wake-drain.sh"
arm_number=0
arm() {
  arm_number=$((arm_number + 1))
  export PI_TOOL_CALL_ID="arm-$arm_number"
  rc=0
  output=$("$ARM" "$@" 2>&1) || rc=$?
}
drain() {
  printf '1\t1\theartbeat\tfixture\theartbeat: fixture\n' > "$LAB/state/.wake-queue"
  "$DRAIN" >/dev/null 2>&1
}
arm
expect_code 0 "$rc" 'startup must arm'
jq -es '.[-1].observed == "startup"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'startup was not recognized from native session state'
drain
PI_TOOL_CALL_ID=retired "$LAB/bin/fm-omp-watch-transition.sh" cycle failed 42 late-close
PI_SESSION_ID=foreign "$LAB/bin/fm-omp-watch-transition.sh" cycle failed 42 late-close
PI_TOOL_CALL_ID=bare
arm
expect_code 2 "$rc" 'a clean normal wake cannot finish by a bare re-arm'
assert_contains "$output" firstmate_watch_reset 'refusal names the reset tool'
[ "$(wc -l < "$LAB/launches" | tr -d ' ')" = 1 ] || fail 'refused re-arm launched a watcher'
pass 'clean ordinary wake refuses a bare re-arm before launching'

arm --transition work-pending
expect_code 2 "$rc" 'a declaration needs its concrete reason'
arm --transition invalid --reason 'invalid declaration'
expect_code 2 "$rc" 'unsupported declarations cannot silently arm'

for reason in work-pending unanswered-input chat-question stow-incomplete unknown; do
  PI_TOOL_CALL_ID="declared-$reason"
  arm --transition "$reason" --reason "fixture $reason remains"
  expect_code 0 "$rc" "$reason must preserve supervision"
  if [ "$reason" = unknown ]; then
    assert_contains "$output" WARNING 'unknown must warn visibly'
  fi
  assert_grep "$reason" "$LAB/state/.omp-watch-transitions.log" 'claim is durably recorded'
  drain
done
for operation in push merge cleanup steer; do
  arm --transition work-pending --reason "$operation is half done"
  expect_code 0 "$rc" "half-done $operation must arm"
  drain
done
pass 'explicit work, unanswered input, chat question and incomplete-stow declarations preserve arming'

printf 'needs-decision [key=shape]: choose shape\nworking: unrelated progress\n' > "$LAB/state/worker.status"
arm
expect_code 0 "$rc" 'an open decision cannot be masked by later progress'
drain
printf 'resolved [key=shape]: chosen\n' >> "$LAB/state/worker.status"
arm
expect_code 2 "$rc" 'resolved decision must not remain an exemption'
printf 'blocked [key=next]: next step owed\n' >> "$LAB/state/worker.status"
arm
expect_code 0 "$rc" 'blocked next step must arm'
drain
printf 'resolved [key=next]: unblocked\n' >> "$LAB/state/worker.status"
pass 'keyed decisions and blocked work are verified from the complete status stream'

touch "$LAB/state/.afk"
arm
expect_code 0 "$rc" 'away mode must arm'
rm -f "${LAB:?}/state/.afk"
drain
printf 'none\t-\tomp\n' > "$LAB/state/.afk-daemon-terminal"
arm
expect_code 0 "$rc" 'selected away delivery must arm'
rm -f "${LAB:?}/state/.afk-daemon-terminal"
drain
PI_SESSION_ID=replacement
arm
expect_code 0 "$rc" 'replacement-session startup must arm'
jq -es '.[-1].observed == "startup"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'replacement startup was misclassified'
drain
pass 'away and replacement-session startup remain protected'

touch "$LAB/state/.captain-hold"
arm
expect_code 0 "$rc" 'a global hold must arm without resetting'
rm -f "${LAB:?}/state/.captain-hold"
drain
printf '1\t2\tcheck\tlater\tcheck: waiting\n' > "$LAB/state/.wake-queue"
arm
expect_code 0 "$rc" 'undrained wakes must arm without resetting'
drain
printf 'not a cycle\n' > "$LAB/state/.omp-watch-cycle"
arm
expect_code 0 "$rc" 'unreadable cycle must preserve supervision'
assert_contains "$output" WARNING 'unreadable cycle must warn'
printf 'not a cycle\n' > "$LAB/state/.omp-watch-cycle"
arm --transition work-pending --reason 'second instruction remains'
expect_code 0 "$rc" 'an explicit work claim must still preserve unknown-state arming'
assert_contains "$output" WARNING 'unknown evidence must warn even with a work declaration'
drain
pass 'holds, queued wakes and unknown state preserve arming'

printf '## Queued\n- [ ] choice - Choose behavior (repo: firstmate, kind: captain, hold: awaiting answer, hold-kind: captain)\n' > "$LAB/data/backlog.md"
arm
expect_code 0 "$rc" 'durable backlog hold must arm'
drain
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf 'decisions.json\n' > "$LAB/config/decision-inbox"
printf '{"open": [ ["firstmate", "choice", "answer", "Choose behavior"] ]}\n' > "$LAB/decisions.json"
printf '.open\n' > "$LAB/config/decision-inbox-query.jq"
arm
expect_code 0 "$rc" 'configured decision inbox must arm'
assert_not_contains "$output" WARNING 'a valid private projection must be read without changing its input shape'
drain
printf '{"open": []}\n' > "$LAB/decisions.json"
arm
expect_code 2 "$rc" 'empty inbox must not exempt a clean wake'
pass 'backlog holds and configured inbox questions are independently verified'

printf '## Done\n' > "$LAB/data/backlog.md"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  printf -- '- [x] completed-%s - Finished (repo: firstmate)\n' "$i" >> "$LAB/data/backlog.md"
done
arm
expect_code 2 "$rc" 'bounded completion history cannot exempt a clean wake'
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"

rm -f "${LAB:?}/config/decision-inbox"
ln -s "$LAB/missing-inbox-setting" "$LAB/config/decision-inbox"
arm
expect_code 0 "$rc" 'broken inbox configuration must preserve supervision'
assert_contains "$output" WARNING 'broken inbox configuration must warn'
rm -f "${LAB:?}/config/decision-inbox"
drain
mkdir "$LAB/state/unreadable.status"
arm
expect_code 0 "$rc" 'invalid status evidence must preserve supervision'
assert_contains "$output" WARNING 'invalid status evidence must warn'
rmdir "${LAB:?}/state/unreadable.status"
drain
pass 'irrelevant completion history stays clean while unreadable evidence warns and arms'

printf '1\t2\talien\tfixture\tunsupported wake\n' > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 0 "$rc" 'an unknown wake kind must not require reset'
assert_contains "$output" WARNING 'an unknown wake kind must warn'
drain

printf '1\t3\tstale\tworker\tstale: worker (paused; rechecked)\n' > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm --transition idle-recheck --reason 'already reported idle wait'
expect_code 0 "$rc" 'idle recheck must not force another reset'
"$DRAIN" >/dev/null 2>&1
arm --transition idle-recheck --reason 'already reported idle wait'
expect_code 0 "$rc" 'repeated idle recheck must not produce a reset storm'
drain
arm --transition watching-only --reason 'nothing remains'
expect_code 2 "$rc" 'declared watching-only must use reset'
pass 'idle rechecks avoid reset storms and watching-only cannot bypass reset'

printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/bin/fm-watch.sh"
arm --transition unknown --reason 'fixture failure'
expect_code 1 "$rc" 'fixture must actually fail its cycle'
printf '#!/usr/bin/env bash\nprintf "heartbeat: repaired\\n"\n' > "$LAB/bin/fm-watch.sh"
arm
expect_code 0 "$rc" 'failed watcher must repair without reset'
jq -es '.[-1].observed == "repair"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'failed cycle was not recognized as repair'
drain
printf '%s\n' "$PI_SESSION_ID" previous running 999999 fixture > "$LAB/state/.omp-watch-cycle"
arm
expect_code 0 "$rc" 'missing watcher must repair without reset'
jq -es '.[-1].observed == "repair"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'missing watcher was not recognized as repair'
drain
"$LAB/bin/fm-omp-watch-transition.sh" recovery "$PI_SESSION_ID"
arm
expect_code 0 "$rc" 'reset recovery must arm'
drain
arm
expect_code 2 "$rc" 'recovery exemption must not survive the replacement arm'
pass 'failed and missing cycles repair, and reset recovery is consumed once'

OMPCODE=0 arm
expect_code 0 "$rc" 'other primary harnesses must retain existing arming'
pass 'non-omp harnesses keep their existing arm behavior'

output=$(PI_SESSION_ID='' "$ARM" 2>&1) || fail 'unknown native identity must preserve arming'
assert_contains "$output" WARNING 'unknown native identity must warn'
output=$(PI_TOOL_CALL_ID='' "$ARM" 2>&1) || fail 'unknown native call must preserve arming'
assert_contains "$output" WARNING 'unknown native call must warn'
for i in $(seq 1 260); do printf '{"previous":%s}\n' "$i"; done > "$LAB/state/.omp-watch-transitions.log"
arm --transition unknown --reason 'bounded ledger proof'
expect_code 0 "$rc" 'bounded ledger fixture must arm'
jq -es 'length == 256 and .[-1].claim == "unknown"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'transition ledger is unbounded or lost the new claim'
python3 - "$LAB/state/.omp-watch-transitions.log" <<'PY'
import pathlib,sys
assert pathlib.Path(sys.argv[1]).stat().st_mode & 0o777 == 0o600
PY
pass 'unknown native identities warn and the private transition ledger stays bounded'
