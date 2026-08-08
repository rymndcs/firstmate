#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh dispatch snapshots.
#
# These tests drive the public spawn interface through a fake tmux endpoint and
# a real isolated git worktree. The dispatch-axi stub proves that successful,
# degraded, wholly-degraded, failed, timed-out, and unrecognized-schema
# observations become metadata without changing spawn success.
#
# The stub also carries one fixture per documented `candidates[].evidence` shape,
# because the selection procedure in .agents/skills/quota-array-dispatch/SKILL.md
# branches on those shapes and its only other coverage is credentialed and
# opt-in. These cases pin the DATA that procedure reads: what the reading records
# for a balance candidate, a window candidate, a window-fallback candidate that
# carries no headroom figure, and each of the three sentinel candidates. They
# cannot exercise the agent's judgment over that data, which stays the
# credentialed test's job; docs/verification/dispatch-auth.md records the split.
# Nothing here reads instruction source: every assertion goes through the real
# spawn path, with no credentials, no network, and no real dispatch-axi.
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
  all-degraded)
    printf '%s\n' '{"generatedAt":"2026-08-07T22:05:30Z","schemaVersion":1,"candidates":[],"rankings":[],"degradedSources":["quota-axi: quota-axi not found on PATH"]}'
    ;;
  future-schema)
    printf '%s\n' '{"generatedAt":"2026-08-07T22:06:00Z","schemaVersion":99,"candidates":[{"provider":"claude","runway":{"runwayHuman":"17h 57m"}}],"rankings":[{"provider":"claude","rank":1}],"degradedSources":[]}'
    ;;
  injection)
    printf '%s\n' '{"generatedAt":"2026-08-07T22:07:00Z","schemaVersion":1,"candidates":[{"provider":"ev;il=1\nharness","runway":{"runwayHuman":"1h"}}],"rankings":[{"provider":"ev;il=1\nharness","rank":1}],"degradedSources":[]}'
    ;;
  shape-balance)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:10:00Z","schemaVersion":1,"candidates":[{"provider":"deepseek","source":"balance","label":"DeepSeek","runway":{"status":"low_confidence_balance","runwaySeconds":23558400,"runwayHuman":">272d 18h","projectionConfidence":"low","projectionBasis":"balance_burn"},"evidence":{"balance_usd":12.5,"granted_balance":0,"topped_up_balance":12.5,"daily_burn_usd":0.04,"is_available":true,"history_days":3},"warnings":[],"errors":[]}],"rankings":[{"provider":"deepseek","rank":1,"runway_human":">272d 18h"}],"degradedSources":[]}'
    ;;
  shape-window)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:11:00Z","schemaVersion":1,"candidates":[{"provider":"claude","source":"window","label":"Claude","runway":{"status":"through_reset","runwaySeconds":64620,"runwayHuman":"17h 57m","projectionConfidence":"high","projectionBasis":"observed_burn","limitingWindow":"model:fable"},"evidence":{"effectivePercentRemaining":41,"worstReservePercentPoints":-6,"liveWindows":["all_models","model:fable"]},"warnings":[],"errors":[]}],"rankings":[{"provider":"claude","rank":1,"runway_human":"17h 57m"}],"degradedSources":[]}'
    ;;
  shape-window-fallback)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:12:00Z","schemaVersion":1,"candidates":[{"provider":"codex","source":"window","label":"Codex","runway":{"status":"window_fallback","runwaySeconds":9000,"runwayHuman":"2h 30m","projectionBasis":"window_fallback","limitingWindow":"weekly"},"evidence":{"liveWindows":["weekly"]},"warnings":[],"errors":["No effectiveAvailability entries; using window fallback"]}],"rankings":[{"provider":"codex","rank":1,"runway_human":"2h 30m"}],"degradedSources":[]}'
    ;;
  sentinel-empty)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:13:00Z","schemaVersion":1,"candidates":[{"provider":"deepseek","source":"balance","runway":{"status":"low_confidence_balance","runwayHuman":"9d 4h"},"evidence":{"balance_usd":4.2,"daily_burn_usd":0.45,"is_available":true,"history_days":5},"warnings":[],"errors":[]},{"provider":"cursor","source":"unknown","runway":{"status":"unknown"},"evidence":{"effectiveAvailability":"empty"},"warnings":[],"errors":["sqlite3_unavailable","No effectiveAvailability entries"]}],"rankings":[{"provider":"deepseek","rank":1,"runway_human":"9d 4h"},{"provider":"cursor","rank":null,"runway_human":null}],"degradedSources":[]}'
    ;;
  sentinel-no-semantics)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:14:00Z","schemaVersion":1,"candidates":[{"provider":"deepseek","source":"balance","runway":{"status":"low_confidence_balance","runwayHuman":"9d 4h"},"evidence":{"balance_usd":4.2,"daily_burn_usd":0.45,"is_available":true,"history_days":5},"warnings":[],"errors":[]},{"provider":"cursor","source":"unknown","runway":{"status":"unknown"},"evidence":{"raw_has_quota_semantics":false},"warnings":[],"errors":["No quotaSemantics in provider data"]}],"rankings":[{"provider":"deepseek","rank":1,"runway_human":"9d 4h"},{"provider":"cursor","rank":null,"runway_human":null}],"degradedSources":[]}'
    ;;
  sentinel-not-a-dict)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:15:00Z","schemaVersion":1,"candidates":[{"provider":"deepseek","source":"balance","runway":{"status":"low_confidence_balance","runwayHuman":"9d 4h"},"evidence":{"balance_usd":4.2,"daily_burn_usd":0.45,"is_available":true,"history_days":5},"warnings":[],"errors":[]},{"provider":"cursor","source":"unknown","runway":{"status":"unknown"},"evidence":{"effectiveAvailability[0]":"not a dict"},"warnings":[],"errors":["effectiveAvailability[0] not a dict"]}],"rankings":[{"provider":"deepseek","rank":1,"runway_human":"9d 4h"},{"provider":"cursor","rank":null,"runway_human":null}],"degradedSources":[]}'
    ;;
  runway-key-camel)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:16:00Z","schemaVersion":1,"candidates":[{"provider":"claude","source":"window","runway":{"status":"through_reset","runwaySeconds":64620,"runwayHuman":"17h 57m","projectionConfidence":"high","projectionBasis":"observed_burn"},"evidence":{"effectivePercentRemaining":41,"worstReservePercentPoints":-6,"liveWindows":["model:fable"]},"warnings":[],"errors":[]}],"rankings":[{"provider":"claude","rank":1,"runway_human":"17h 57m"}],"degradedSources":[]}'
    ;;
  runway-key-snake)
    printf '%s\n' '{"generatedAt":"2026-08-08T01:17:00Z","schemaVersion":1,"candidates":[{"provider":"claude","source":"window","runway":{"status":"through_reset","runwaySeconds":64620,"runway_human":"17h 57m","projectionConfidence":"high","projectionBasis":"observed_burn"},"evidence":{"effectivePercentRemaining":41,"worstReservePercentPoints":-6,"liveWindows":["model:fable"]},"warnings":[],"errors":[]}],"rankings":[{"provider":"claude","rank":1,"runway_human":"17h 57m"}],"degradedSources":[]}'
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

test_degraded_source_survives_a_snapshot_with_no_usable_candidate() {
  local id rec out status meta reading
  id=dispatch-all-degraded-d8
  rec=$(make_case dispatch-all-degraded "$id")
  read_case "$rec"

  out=$(run_spawn all-degraded "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a snapshot with no usable candidate must not fail spawn"
  assert_contains "$out" "spawned $id" "spawn failed on a snapshot with no usable candidate"
  assert_grep 'dispatch_reading=at=2026-08-07T22:05:30Z;degraded=quota-axi' "$meta" \
    "a snapshot with no usable candidate collapsed to unavailable and lost its named degraded source"
  reading=$(fm_meta_get "$meta" dispatch_reading)
  [ "$reading" != unavailable ] \
    || fail "an all-degraded snapshot is indistinguishable from dispatch-axi never running"
  pass "a snapshot with no usable candidate still records its named degraded source"
}

test_balance_shape_records_its_ranked_runway() {
  local id rec meta
  id=dispatch-shape-balance-d9
  rec=$(make_case dispatch-shape-balance "$id")
  read_case "$rec"

  run_spawn shape-balance "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'dispatch_reading=at=2026-08-08T01:10:00Z;deepseek=1/>272d 18h' "$meta" \
    "a balance-shaped candidate did not record its rank and runway"
  pass "shape 1 balance records the ranked candidate and its runway"
}

test_window_shape_records_its_ranked_runway() {
  local id rec meta
  id=dispatch-shape-window-d10
  rec=$(make_case dispatch-shape-window "$id")
  read_case "$rec"

  run_spawn shape-window "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'dispatch_reading=at=2026-08-08T01:11:00Z;claude=1/17h 57m' "$meta" \
    "a window-shaped candidate did not record its rank and runway"
  pass "shape 2 window records the ranked candidate and its runway"
}

test_window_fallback_shape_keeps_its_runway() {
  local id rec meta reading
  id=dispatch-shape-fallback-d11
  rec=$(make_case dispatch-shape-fallback "$id")
  read_case "$rec"

  run_spawn shape-window-fallback "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  reading=$(fm_meta_get "$meta" dispatch_reading)
  # This shape half-matches shape 2: `source: window` with no headroom figure at
  # all. Carrying no figure is not a figure of zero, so the candidate must reach
  # metadata ranked and with its runway intact rather than emptied out.
  assert_grep 'dispatch_reading=at=2026-08-08T01:12:00Z;codex=1/2h 30m' "$meta" \
    "a window-fallback candidate did not record its runway"
  case "$reading" in
    *'codex=-/'*|*'codex=1/unknown'*|unavailable)
      fail "a window-fallback candidate was emptied out instead of kept: $reading" ;;
  esac
  pass "shape 3 window fallback keeps its runway and is not read as zero headroom"
}

assert_sentinel_is_recorded_unranked() {
  local mode=$1 name=$2 id=$3 rec out status meta reading
  rec=$(make_case "$name" "$id")
  read_case "$rec"

  out=$(run_spawn "$mode" "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  reading=$(fm_meta_get "$meta" dispatch_reading)
  expect_code 0 "$status" "sentinel evidence ($mode) must not block spawn"
  assert_contains "$out" "spawned $id" "spawn failed on sentinel evidence ($mode)"
  case "$reading" in
    *'cursor=-/unknown'*) ;;
    *) fail "sentinel evidence ($mode) was dropped or scored instead of recorded unranked: $reading" ;;
  esac
  # The measurable candidate beside it must survive too, so a sentinel is shown
  # to be unranked rather than to have poisoned the whole snapshot.
  case "$reading" in
    *'deepseek=1/9d 4h'*) ;;
    *) fail "sentinel evidence ($mode) cost the measurable candidate beside it: $reading" ;;
  esac
}

test_sentinel_shapes_are_recorded_unranked() {
  assert_sentinel_is_recorded_unranked sentinel-empty \
    dispatch-sentinel-empty dispatch-sentinel-empty-d12
  pass "shape 4 sentinel effectiveAvailability empty is recorded unranked"

  assert_sentinel_is_recorded_unranked sentinel-no-semantics \
    dispatch-sentinel-semantics dispatch-sentinel-semantics-d13
  pass "shape 4 sentinel raw_has_quota_semantics false is recorded unranked"

  assert_sentinel_is_recorded_unranked sentinel-not-a-dict \
    dispatch-sentinel-notdict dispatch-sentinel-notdict-d14
  pass "shape 4 sentinel effectiveAvailability[0] not a dict is recorded unranked"
}

test_runway_is_read_from_the_documented_camelcase_field() {
  local id rec meta reading
  id=dispatch-runway-camel-d15
  rec=$(make_case dispatch-runway-camel "$id")
  read_case "$rec"

  run_spawn runway-key-camel "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'dispatch_reading=at=2026-08-08T01:16:00Z;claude=1/17h 57m' "$meta" \
    "candidates[].runway.runwayHuman was not the field the runway came from"

  # The rot guard. dispatch-axi carries camelCase `runwayHuman` under
  # candidates[].runway and snake_case `runway_human` under rankings[]. A silent
  # swap to the wrong sibling would degrade every provider to `unknown` while
  # schemaVersion 1 still validated, so this fixture removes only the camelCase
  # key and pins that the reading notices.
  id=dispatch-runway-snake-d16
  rec=$(make_case dispatch-runway-snake "$id")
  read_case "$rec"

  run_spawn runway-key-snake "$id" > /dev/null
  meta="$HOME_DIR/state/$id.meta"
  reading=$(fm_meta_get "$meta" dispatch_reading)
  assert_grep 'dispatch_reading=at=2026-08-08T01:17:00Z;claude=1/unknown' "$meta" \
    "a candidate runway carrying only runway_human did not record unknown"
  case "$reading" in
    *'17h 57m'*) fail "the reading fell back to a runway_human sibling: $reading" ;;
  esac
  pass "the runway is read from runwayHuman, and a runway_human-only candidate records unknown"
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
test_degraded_source_survives_a_snapshot_with_no_usable_candidate
test_balance_shape_records_its_ranked_runway
test_window_shape_records_its_ranked_runway
test_window_fallback_shape_keeps_its_runway
test_sentinel_shapes_are_recorded_unranked
test_runway_is_read_from_the_documented_camelcase_field
test_unrecognized_schema_records_unavailable
test_reading_cannot_forge_a_second_metadata_key
test_failed_reading_records_unavailable_and_spawns
test_slow_reading_times_out_and_spawns
test_older_metadata_is_absent_safe
