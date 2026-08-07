#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh quota snapshots.
#
# These tests drive the public spawn interface through a fake tmux endpoint and
# a real isolated git worktree. The quota stub proves that successful, failed,
# and timed-out observations become metadata without changing spawn success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

# This file owns the reading contract, so it opts back in to the real code path
# that tests/lib.sh neutralizes for the suite, and supplies its own quota-axi
# stub and per-case cache instead.
unset FM_QUOTA_AXI_READING_DISABLE

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-quota-reading)

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
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '0.1.17\n'; exit 0 ;;
  --json)
    case "${FM_FAKE_QUOTA_MODE:-success}" in
      success)
        printf '%s\n' '{"generatedAt":"2026-08-06T02:33:24Z","providers":[{"provider":"claude","windows":[{"id":"seven_day","percentRemaining":44,"resetsAt":"2026-08-08T15:59:59Z"}]},{"provider":"codex","windows":[{"id":"weekly","percentRemaining":57,"resetsAt":"2026-08-10T17:53:54Z"}]}]}'
        ;;
      fail) exit 7 ;;
      slow) sleep 30 ;;
      *) exit 8 ;;
    esac
    ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/quota-axi"
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
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$case_dir/cache"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
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
    FM_QUOTA_AXI_CACHE="$CASE_DIR/cache/quotas.json" FM_FAKE_QUOTA_MODE="$mode" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
}

test_success_records_timestamped_headroom() {
  local id rec out status meta
  id=quota-success-q1
  rec=$(make_case quota-success "$id")
  read_case "$rec"

  out=$(run_spawn success "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a successful quota reading must not disturb spawn"
  assert_contains "$out" "spawned $id" "normal spawn did not succeed"
  assert_grep 'quota_reading=at=2026-08-06T02:33:24Z;claude/seven_day=44%@2026-08-08T15:59:59Z;codex/weekly=57%@2026-08-10T17:53:54Z' "$meta" \
    "normal spawn did not record timestamped provider headroom"
  pass "normal spawn records timestamped quota headroom in task metadata"
}

test_failed_reading_records_unavailable_and_spawns() {
  local id rec out status meta
  id=quota-failed-q2
  rec=$(make_case quota-failed "$id")
  read_case "$rec"

  out=$(run_spawn fail "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a failed quota reading must not fail spawn"
  assert_contains "$out" "spawned $id" "spawn failed with a nonzero quota tool"
  assert_grep 'quota_reading=unavailable' "$meta" \
    "failed quota reading was omitted instead of recorded unavailable"
  pass "nonzero quota-axi still spawns and records unavailable"
}

test_slow_reading_times_out_and_spawns() {
  local id rec out status meta started elapsed
  id=quota-slow-q3
  rec=$(make_case quota-slow "$id")
  read_case "$rec"

  started=$(date +%s)
  out=$(run_spawn slow "$id")
  status=$?
  elapsed=$(($(date +%s) - started))
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a timed-out quota reading must not fail spawn"
  [ "$elapsed" -lt 10 ] || fail "slow quota-axi was not bounded (elapsed ${elapsed}s)"
  assert_contains "$out" "spawned $id" "spawn failed when quota-axi timed out"
  assert_grep 'quota_reading=unavailable' "$meta" \
    "timed-out quota reading was omitted instead of recorded unavailable"
  pass "slow quota-axi is bounded while spawn succeeds with unavailable recorded"
}

test_fresh_cache_avoids_a_quota_process() {
  local id rec out status meta
  id=quota-cache-q4
  rec=$(make_case quota-cache "$id")
  read_case "$rec"
  printf '%s\n' '{"generatedAt":"2026-08-06T02:34:00Z","providers":[{"provider":"codex","windows":[{"id":"weekly","percentRemaining":58}]}]}' \
    > "$CASE_DIR/cache/quotas.json"

  out=$(run_spawn fail "$id")
  status=$?
  meta="$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a fresh quota cache should keep spawn fast"
  assert_contains "$out" "spawned $id" "fresh-cache spawn did not succeed"
  assert_grep 'quota_reading=at=2026-08-06T02:34:00Z;codex/weekly=58%' "$meta" \
    "fresh cached headroom was not recorded"
  pass "a fresh quota cache avoids another provider refresh"
}

test_older_metadata_is_absent_safe() {
  local meta value
  meta="$TMP_ROOT/older.meta"
  fm_write_meta "$meta" 'window=firstmate:fm-old' 'harness=claude' 'kind=ship'
  value=$(fm_meta_get "$meta" quota_reading)
  [ -z "$value" ] || fail "older metadata without quota_reading did not return an empty value"
  pass "older metadata safely omits quota_reading"
}

test_success_records_timestamped_headroom
test_failed_reading_records_unavailable_and_spawns
test_slow_reading_times_out_and_spawns
test_fresh_cache_avoids_a_quota_process
test_older_metadata_is_absent_safe
