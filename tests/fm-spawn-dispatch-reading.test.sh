#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh dispatch snapshots.
#
# These tests drive the public spawn interface through a fake tmux endpoint and
# a real isolated git worktree. The dispatch-axi stub proves that successful,
# degraded, failed, timed-out, and unrecognized-schema observations become
# metadata without changing spawn success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

# This file owns the reading contract, so it opts back in to the real code path
# that tests/lib.sh neutralizes for the suite, and supplies its own dispatch-axi
# stub instead.
unset FM_DISPATCH_AXI_READING_DISABLE

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-reading)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/dispatch-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --json ] || exit 9
case "${FM_FAKE_DISPATCH_MODE:-success}" in
  success)
    printf '%s\n' '{"generatedAt":"2026-08-07T22:02:13Z","schemaVersion":1,"candidates":[{"provider":"deepseek","runway":{"runwayHuman":">272d 18h"}},{"provider":"codex","runway":{"runwayHuman":"2d 13h 22m"}},{"provider":"claude","runway":{"runwayHuman":"17h 57m"}},{"provider":"kimi","runway":{"runwayHuman":null}}],"rankings":[{"provider":"deepseek","rank":1},{"provider":"codex","rank":2},{"provider":"claude","rank":3},{"provider":"kimi","rank":null}],"degradedSources":[]}'
    ;;
  degraded)
    printf '%s\n' '{"generatedAt":"2026-08-07T22:05:00Z","schemaVersion":1,"candidates":[{"provider":"deepseek","runway":{"runwayHuman":"10d 3h"}}],"rankings":[{"provider":"deepseek","rank":1}],"degradedSources":["quota-axi: quota-axi not found on PATH"]}'
    ;;
  future-schema)
    printf '%s\n' '{"generatedAt":"2026-08-07T22:06:00Z","schemaVersion":99,"candidates":[{"provider":"claude","runway":{"runwayHuman":"17h 57m"}}],"rankings":[{"provider":"claude","rank":1}],"degradedSources":[]}'
    ;;
  injection)
    printf '%s\n' '{"generatedAt":"2026-08-07T22:07:00Z","schemaVersion":1,"candidates":[{"provider":"ev;il=1\nharness","runway":{"runwayHuman":"1h"}}],"rankings":[{"provider":"ev;il=1\nharness","rank":1}],"degradedSources":[]}'
    ;;
  fail) exit 7 ;;
  slow) sleep 30 ;;
  *) exit 8 ;;
esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/dispatch-axi"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home|$project|$worktree|$fakebin"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local mode=$1 id=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WORKTREE_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$HOME_DIR/grok-home" \
    FM_FAKE_DISPATCH_MODE="$mode" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
}

test_success_records_timestamped_ranking() {
  local id rec out status meta
  id=dispatch-success-d1
  rec=$(make_case dispatch-success "$id")
  read_case "$rec"

  out=$(run_spawn success "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a successful dispatch reading must not disturb spawn"
  assert_contains "$out" "spawned $id" "normal spawn did not succeed"
  assert_grep 'dispatch_reading=at=2026-08-07T22:02:13Z;deepseek=1/>272d 18h;codex=2/2d 13h 22m;claude=3/17h 57m;kimi=-/unknown' "$meta" \
    "normal spawn did not record the timestamped ranking and its runway evidence"
  pass "normal spawn records the timestamped dispatch ranking in task metadata"
}

test_unranked_candidate_is_kept_not_dropped() {
  local id rec meta reading
  id=dispatch-unranked-d2
  rec=$(make_case dispatch-unranked "$id")
  read_case "$rec"

  run_spawn success "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  reading=$(fm_meta_get "$meta" dispatch_reading)
  case "$reading" in
    *'kimi=-/unknown'*) ;;
    *) fail "an unmeasurable candidate must be recorded as unranked, got: $reading" ;;
  esac
  pass "an unmeasurable candidate is recorded as unranked rather than dropped"
}

test_degraded_source_is_named_in_the_reading() {
  local id rec meta
  id=dispatch-degraded-d3
  rec=$(make_case dispatch-degraded "$id")
  read_case "$rec"

  run_spawn degraded "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'dispatch_reading=at=2026-08-07T22:05:00Z;deepseek=1/10d 3h;degraded=quota-axi' "$meta" \
    "a source that failed inside dispatch-axi was not named in the reading"
  pass "a degraded source is recorded by name so an empty provider is distinguishable"
}

test_unrecognized_schema_records_unavailable() {
  local id rec out status meta
  id=dispatch-schema-d4
  rec=$(make_case dispatch-schema "$id")
  read_case "$rec"

  out=$(run_spawn future-schema "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "an unrecognized dispatch schema must not fail spawn"
  assert_contains "$out" "spawned $id" "spawn failed on an unrecognized dispatch schema"
  assert_grep 'dispatch_reading=unavailable' "$meta" \
    "an unrecognized schema was summarized instead of recorded unavailable"
  pass "an unrecognized dispatch-axi schema records unavailable rather than a guessed line"
}

test_reading_cannot_forge_a_second_metadata_key() {
  local id rec meta reading
  id=dispatch-injection-d5
  rec=$(make_case dispatch-injection "$id")
  read_case "$rec"

  run_spawn injection "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  reading=$(fm_meta_get "$meta" dispatch_reading)
  case "$reading" in
    *';il=1'*|*$'\n'*) fail "provider-supplied text escaped the reading: $reading" ;;
  esac
  [ "$(grep -c '^harness=' "$meta")" = 1 ] \
    || fail "provider-supplied text forged a second harness= line"
  pass "provider-supplied text cannot forge a separator, a newline, or a second key"
}

test_failed_reading_records_unavailable_and_spawns() {
  local id rec out status meta
  id=dispatch-failed-d6
  rec=$(make_case dispatch-failed "$id")
  read_case "$rec"

  out=$(run_spawn fail "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a failed dispatch reading must not fail spawn"
  assert_contains "$out" "spawned $id" "spawn failed with a nonzero dispatch tool"
  assert_grep 'dispatch_reading=unavailable' "$meta" \
    "failed dispatch reading was omitted instead of recorded unavailable"
  pass "nonzero dispatch-axi still spawns and records unavailable"
}

test_slow_reading_times_out_and_spawns() {
  local id rec out status meta started elapsed
  id=dispatch-slow-d7
  rec=$(make_case dispatch-slow "$id")
  read_case "$rec"

  started=$(date +%s)
  out=$(run_spawn slow "$id")
  status=$?
  elapsed=$(($(date +%s) - started))
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a timed-out dispatch reading must not fail spawn"
  [ "$elapsed" -lt 25 ] || fail "slow dispatch-axi was not bounded (elapsed ${elapsed}s)"
  assert_contains "$out" "spawned $id" "spawn failed when dispatch-axi timed out"
  assert_grep 'dispatch_reading=unavailable' "$meta" \
    "timed-out dispatch reading was omitted instead of recorded unavailable"
  pass "slow dispatch-axi is bounded while spawn succeeds with unavailable recorded"
}

test_older_metadata_is_absent_safe() {
  local meta value
  meta="$TMP_ROOT/older.meta"
  fm_write_meta "$meta" 'window=firstmate:fm-old' 'harness=claude' 'kind=ship'
  value=$(fm_meta_get "$meta" dispatch_reading)
  [ -z "$value" ] || fail "older metadata without dispatch_reading did not return an empty value"
  pass "older metadata safely omits dispatch_reading"
}

test_success_records_timestamped_ranking
test_unranked_candidate_is_kept_not_dropped
test_degraded_source_is_named_in_the_reading
test_unrecognized_schema_records_unavailable
test_reading_cannot_forge_a_second_metadata_key
test_failed_reading_records_unavailable_and_spawns
test_slow_reading_times_out_and_spawns
test_older_metadata_is_absent_safe
