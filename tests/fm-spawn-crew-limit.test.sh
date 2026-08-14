#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's live worker limit (config/crew-limit).
#
# The limit exists because concurrent workers are a machine-level cost, and a
# rule that only firstmate remembers is not a rule the machine is protected by.
# These tests drive the real fm-spawn against a fake tmux whose window inventory
# is the one dial they turn: a seeded task's window listed in the inventory
# classifies alive through the ordinary liveness path, and an unlisted one
# classifies dead exactly as it does after a crash. Nothing here asserts
# implementation text; every case is an exit code, a refusal message a human has
# to act on, or the presence or absence of the artifacts a spawn creates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-crew-limit)

# A tmux fake whose agent-liveness answers are driven entirely by the
# `session:window` lines in $FM_FAKE_TMUX_WINDOWS. Every listed window reports a
# harness foreground command and therefore reads alive; every unlisted one is
# absent from the session inventory and therefore reads dead, which is how a
# crashed worker's endpoint really presents. `treehouse` and `new-window` calls
# are logged so a refusal can be proven to happen before any of them.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u

live_windows() {
  [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ] && [ -f "$FM_FAKE_TMUX_WINDOWS" ] || return 0
  cat "$FM_FAKE_TMUX_WINDOWS"
}

case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
  *"#{pane_current_command}"*) printf 'claude\n'; exit 0 ;;
esac

case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ "${2:-}" = "-a" ]; then
      live_windows
      exit 0
    fi
    target=
    prev=
    for a in "$@"; do
      [ "$prev" = "-t" ] && target=$a
      prev=$a
    done
    live_windows | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      [ "${entry%%:*}" = "$target" ] || continue
      printf '%s\n' "${entry#*:}"
    done
    exit 0
    ;;
  new-window)
    [ -z "${FM_FAKE_WINDOW_LOG:-}" ] || printf 'new-window %s\n' "$*" >> "$FM_FAKE_WINDOW_LOG"
    # Opt-in: newly created windows join the live inventory, so a sequence of
    # spawns accumulates real live workers instead of vanishing.
    if [ "${FM_FAKE_REGISTER_NEW_WINDOWS:-}" = 1 ] && [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ]; then
      session=firstmate
      name=
      prev=
      for a in "$@"; do
        [ "$prev" = "-n" ] && name=$a
        [ "$prev" = "-t" ] && session=${a%:}
        prev=$a
      done
      [ -z "$name" ] || printf '%s:%s\n' "$session" "$name" >> "$FM_FAKE_TMUX_WINDOWS"
    fi
    printf '@1\n'
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_case <name> [<brief-id>...] - a home, a project with a real worktree, a
# fake bin, and one brief per id. Echoes a record for read_case_record.
make_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/windows"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/window.log"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  WINDOWS_FILE="$CASE_DIR/windows"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  WINDOW_LOG="$CASE_DIR/window.log"
}

# seed_task <id> <kind> <alive|dead> - a durable task record plus, when alive,
# its window in the fake tmux inventory.
seed_task() {
  local id=$1 kind=$2 liveness=$3 window
  # Assigned after the positional locals: `local` expands all of its arguments
  # against the CALLER's scope, so deriving the window inline would silently
  # reuse the calling test's id and give every seeded task one shared endpoint.
  window="fm:fm-$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=$kind"
  [ "$liveness" = alive ] || return 0
  printf '%s\n' "$window" >> "$WINDOWS_FILE"
}

seed_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$HOME_DIR/grok-home" \
    FM_FAKE_TMUX_WINDOWS="$WINDOWS_FILE" FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    FM_FAKE_WINDOW_LOG="$WINDOW_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off --captain-pick claude
}

# Forget what earlier spawns in the same case did, so a later refusal is judged
# on its own side effects.
reset_spawn_logs() {
  : > "$TREEHOUSE_LOG"
  : > "$WINDOW_LOG"
}

assert_no_spawn_artifacts() {
  local id=$1
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must leave no task record for $id"
  assert_absent "$HOME_DIR/state/.spawn-$id.lock" "a refused spawn must leave no spawn lock for $id"
  [ ! -s "$TREEHOUSE_LOG" ] || fail "a refused spawn must not allocate a worktree"$'\n'"$(cat "$TREEHOUSE_LOG")"
  [ ! -s "$WINDOW_LOG" ] || fail "a refused spawn must not create an endpoint"$'\n'"$(cat "$WINDOW_LOG")"
}

test_fourth_concurrent_worker_is_refused_by_default() {
  local rec id out status
  id=cap-fourth-k1
  rec=$(make_case cap-fourth "$id")
  read_case_record "$rec"
  seed_task held-one-k1 ship alive
  seed_task held-two-k1 ship alive
  seed_task held-three-k1 scout alive

  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a fourth concurrent worker should be refused with the default limit"
  assert_contains "$out" "3 live workers already hold the limit of 3" \
    "the refusal did not report how many workers are live against the limit"
  assert_contains "$out" "held-one-k1" "the refusal did not name the first slot holder"
  assert_contains "$out" "held-two-k1" "the refusal did not name the second slot holder"
  assert_contains "$out" "held-three-k1" "the refusal did not name the third slot holder"
  assert_contains "$out" "$HOME_DIR/config/crew-limit" \
    "the refusal did not name the config path that raises the limit"
  assert_no_spawn_artifacts "$id"
  pass "a fourth concurrent worker is refused, naming the live holders and the config path"
}

test_third_worker_is_allowed_by_default() {
  local rec id out status
  id=cap-third-k2
  rec=$(make_case cap-third "$id")
  read_case_record "$rec"
  seed_task held-one-k2 ship alive
  seed_task held-two-k2 ship alive

  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a third concurrent worker should launch with the default limit"
  assert_contains "$out" "spawned $id" "the third worker did not launch"
  assert_present "$HOME_DIR/state/$id.meta" "the third worker recorded no task metadata"
  pass "an absent config file allows three concurrent workers"
}

test_dead_worker_does_not_hold_a_slot() {
  local rec id out status
  id=cap-dead-k3
  rec=$(make_case cap-dead "$id")
  read_case_record "$rec"
  seed_task held-one-k3 ship alive
  seed_task held-two-k3 ship alive
  # The crash case: a durable task record whose endpoint no longer carries an
  # agent. It must not keep a slot occupied.
  seed_task crashed-k3 ship dead

  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a task whose worker is dead should not consume a slot"
  assert_contains "$out" "spawned $id" "the spawn did not launch after a dead worker freed its slot"
  assert_present "$HOME_DIR/state/$id.meta" "the spawn recorded no task metadata"
  # Proof the case is not vacuous: with that same task alive, the limit binds.
  printf 'fm:fm-crashed-k3\n' >> "$WINDOWS_FILE"
  rm -f "$HOME_DIR/state/$id.meta"
  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "the same fleet with that worker alive should refuse the spawn"
  assert_contains "$out" "crashed-k3" "the live counterpart did not hold a slot"
  pass "a dead worker's task frees its slot while the same task alive holds one"
}

test_secondmate_spawn_is_neither_counted_nor_blocked() {
  local rec id sm out status ship_id
  id=cap-secondmate-k4
  ship_id=cap-after-secondmate-k4
  rec=$(make_case cap-secondmate "$id" "$ship_id")
  read_case_record "$rec"
  seed_task held-one-k4 ship alive
  seed_task held-two-k4 ship alive
  seed_task held-three-k4 ship alive
  sm="$CASE_DIR/secondmate-home"
  seed_secondmate_home "$sm" "$id"

  out=$(run_spawn "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "a secondmate spawn is a persistent home and must never be capped"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "the secondmate spawn recorded no home"

  # And that live secondmate must not itself hold a worker slot: with the three
  # ship holders gone, a fresh worker still launches beside it.
  rm -f "$HOME_DIR/state/held-one-k4.meta" "$HOME_DIR/state/held-two-k4.meta" \
    "$HOME_DIR/state/held-three-k4.meta"
  printf 'fm:fm-%s\n' "$id" >> "$WINDOWS_FILE"
  out=$(run_ship_spawn "$ship_id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a live secondmate must not consume a worker slot"
  assert_contains "$out" "spawned $ship_id" "the worker beside a live secondmate did not launch"
  pass "secondmate spawns are exempt from the limit and hold no slot themselves"
}

test_documented_override_allows_one_spawn() {
  local rec id out status
  id=cap-override-k5
  rec=$(make_case cap-override "$id")
  read_case_record "$rec"
  seed_task held-one-k5 ship alive
  seed_task held-two-k5 ship alive
  seed_task held-three-k5 ship alive

  out=$(FM_ALLOW_OVER_CREW_LIMIT=1 run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "the documented per-invocation override should allow the spawn"
  assert_contains "$out" "spawned $id" "the override did not launch the worker"
  assert_contains "$out" "past the live worker limit of 3" \
    "an over-limit spawn must announce itself rather than pass silently"

  rm -f "$HOME_DIR/state/$id.meta"
  reset_spawn_logs
  out=$(FM_ALLOW_OVER_CREW_LIMIT=yes run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "only the exact documented override value may release the limit"
  assert_no_spawn_artifacts "$id"
  pass "FM_ALLOW_OVER_CREW_LIMIT=1 allows one deliberate spawn and no other value does"
}

test_configured_limit_replaces_the_default() {
  local rec id out status
  id=cap-configured-k6
  rec=$(make_case cap-configured "$id")
  read_case_record "$rec"
  printf '1\n' > "$HOME_DIR/config/crew-limit"
  seed_task held-one-k6 ship alive

  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a configured limit of 1 should refuse a second worker"
  assert_contains "$out" "1 live workers already hold the limit of 1" \
    "the refusal did not report the configured limit"
  assert_no_spawn_artifacts "$id"

  printf '4\n' > "$HOME_DIR/config/crew-limit"
  seed_task held-two-k6 ship alive
  seed_task held-three-k6 ship alive
  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a configured limit of 4 should allow a fourth worker"
  assert_contains "$out" "spawned $id" "the raised limit did not launch the fourth worker"
  pass "config/crew-limit replaces the default in both directions"
}

test_zero_limit_starts_no_workers() {
  local rec id out status
  id=cap-zero-k10
  rec=$(make_case cap-zero "$id")
  read_case_record "$rec"
  printf '0\n' > "$HOME_DIR/config/crew-limit"

  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a limit of zero should refuse a worker even on an empty fleet"
  assert_contains "$out" "so this home starts no workers" \
    "an empty fleet under a zero limit must say why rather than name absent holders"
  assert_no_spawn_artifacts "$id"
  pass "a limit of zero refuses every worker and explains itself on an empty fleet"
}

test_unreadable_limit_refuses_rather_than_defaulting() {
  local rec id out status
  id=cap-malformed-k7
  rec=$(make_case cap-malformed "$id")
  read_case_record "$rec"
  printf 'three\n' > "$HOME_DIR/config/crew-limit"

  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a malformed limit must refuse instead of falling back to the default"
  assert_contains "$out" "$HOME_DIR/config/crew-limit" "the refusal did not name the malformed file"
  assert_contains "$out" "three" "the refusal did not quote the malformed value"
  assert_no_spawn_artifacts "$id"
  pass "an unreadable limit refuses the spawn and names the file to correct"
}

test_scouts_are_capped_and_hold_slots() {
  local rec id out status
  id=cap-scout-k8
  rec=$(make_case cap-scout "$id")
  read_case_record "$rec"
  seed_task held-one-k8 scout alive
  seed_task held-two-k8 scout alive
  seed_task held-three-k8 scout alive

  out=$(run_spawn "$id" "$PROJ_DIR" --scout --captain-pick claude)
  status=$?
  expect_code 1 "$status" "a scout spawn is a worker and should be capped like a ship task"
  assert_contains "$out" "3 live workers already hold the limit of 3" \
    "the scout refusal did not report the live count against the limit"
  assert_no_spawn_artifacts "$id"
  pass "scouts count toward the limit and are refused by it"
}

test_batch_dispatch_stops_at_the_limit() {
  local rec out status
  rec=$(make_case cap-batch batch-one-k11 batch-two-k11 batch-three-k11 batch-four-k11)
  read_case_record "$rec"

  # The scenario the limit exists for: one dispatch asking for four workers at
  # once. Each pair re-execs the single-task path, so each launched worker
  # becomes a live holder the next pair has to count.
  out=$(FM_FAKE_REGISTER_NEW_WINDOWS=1 run_ship_spawn \
    "batch-one-k11=$PROJ_DIR" "batch-two-k11=$PROJ_DIR" \
    "batch-three-k11=$PROJ_DIR" "batch-four-k11=$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a batch that outruns the limit should report a failed pair"
  assert_present "$HOME_DIR/state/batch-one-k11.meta" "the first batch worker did not launch"
  assert_present "$HOME_DIR/state/batch-two-k11.meta" "the second batch worker did not launch"
  assert_present "$HOME_DIR/state/batch-three-k11.meta" "the third batch worker did not launch"
  assert_absent "$HOME_DIR/state/batch-four-k11.meta" "the fourth batch worker launched past the limit"
  assert_contains "$out" "batch: FAILED to spawn batch-four-k11" \
    "the batch did not report which pair was refused"
  pass "a batch dispatch launches up to the limit and refuses the pair beyond it"
}

test_respawn_of_a_capped_task_is_not_blocked_by_itself() {
  local rec id out status
  id=cap-respawn-k9
  rec=$(make_case cap-respawn "$id")
  read_case_record "$rec"
  seed_task held-one-k9 ship alive
  seed_task held-two-k9 ship alive
  # This task is already one of the three: recovering it must not be refused
  # for occupying the slot it is being returned to.
  seed_task "$id" ship dead

  out=$(run_ship_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a recovery respawn must not count its own recorded endpoint"
  assert_contains "$out" "spawned $id" "the recovery respawn did not launch"
  pass "a task's own record never blocks its recovery respawn"
}

test_fourth_concurrent_worker_is_refused_by_default
test_third_worker_is_allowed_by_default
test_dead_worker_does_not_hold_a_slot
test_secondmate_spawn_is_neither_counted_nor_blocked
test_documented_override_allows_one_spawn
test_configured_limit_replaces_the_default
test_zero_limit_starts_no_workers
test_unreadable_limit_refuses_rather_than_defaulting
test_scouts_are_capped_and_hold_slots
test_batch_dispatch_stops_at_the_limit
test_respawn_of_a_capped_task_is_not_blocked_by_itself

echo "# all fm-spawn-crew-limit tests passed"
