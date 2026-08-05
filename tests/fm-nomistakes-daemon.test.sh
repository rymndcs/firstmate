#!/usr/bin/env bash
# tests/fm-nomistakes-daemon.test.sh - the shared no-mistakes daemon contract
# (bin/fm-nomistakes-daemon.sh) and bootstrap's prevention sweep.
#
# The daemon is ONE instance serving every lane and home, and `treehouse return`
# terminates the lingering processes of the worktree it returns. A daemon a
# crewmate started lazily from inside its own worktree therefore dies with that
# worktree and takes every other lane's in-flight validation run with it. This
# suite pins both halves of the fix: bootstrap roots the daemon from the
# firstmate home before any crewmate can start it lazily, and `ensure` is a
# provably silent no-op whenever there is nothing to do.
#
# `no-mistakes daemon status` is a VENDOR-RENDERED surface, so the verdict reads
# two independent signals - a live pid (a kernel fact) and the rendered line plus
# exit status - and either alone must carry a positive result. The two
# single-signal cases below deliberately drive the signals apart and assert the
# divergence itself, so neither can go quietly vacuous if the vendor rewords its
# output. Everything runs against a `no-mistakes` PATH stub with real processes
# for the pid signals; the machine's real shared daemon is never contacted, since
# it is the same daemon serving the gate that runs this suite.
#
# The teardown-side recovery (restore after a treehouse return, and never failing
# teardown) is pinned in tests/fm-teardown.test.sh, where the landed-work
# teardown fixture already lives.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite covers the ensure path itself, so the suite-wide neutralizer that
# lib.sh sets for every OTHER test must not apply here. Cases that need it back
# set it explicitly.
unset FM_NOMISTAKES_DAEMON_DISABLE

NM="$ROOT/bin/fm-nomistakes-daemon.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-nomistakes-daemon-tests)
# fm_test_tmproot registers its cleanup from inside a command substitution, and
# bash runs a subshell's own EXIT trap when that subshell ends - so the root is
# already gone by the time it is echoed back, and the parent never sees the
# registration. Peer suites never notice because they only ever mkdir -p case
# dirs underneath it; this one writes a file directly at the root, so it
# recreates the directory and owns the removal itself.
mkdir -p "$TMP_ROOT"

# Live helper pids are recorded in a FILE, not an array: start_live_process runs
# inside a command substitution, so anything it assigns dies with that subshell
# and the sleeps would outlive the suite.
LIVE_PID_FILE="$TMP_ROOT/live-pids"
: > "$LIVE_PID_FILE"
cleanup_live_pids() {
  local pid
  if [ -f "$LIVE_PID_FILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done < "$LIVE_PID_FILE"
  fi
  rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup_live_pids EXIT

# A real, live process whose pid the stubs can advertise. The daemon verdict's
# strongest signal is `kill -0`, so it must be exercised against an actual
# process rather than a number the test asserts about.
start_live_process() {
  # The redirects matter: a background child that inherits the command
  # substitution's pipe holds it open, so $(start_live_process) would block
  # until the sleep exits - and then hand back a pid that is already dead.
  sleep 120 >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$LIVE_PID_FILE"
  printf '%s\n' "$!"
}

# A pid that is provably NOT ours to signal. Started, reaped, then confirmed
# gone - the "claims running, cannot be proven alive" case.
dead_pid() {
  local pid
  sleep 0 >/dev/null 2>&1 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

# Build a case dir with a `no-mistakes` stub that logs every invocation as
# "<argv>|<cwd>" and answers `daemon status` from the environment.
# Args: <name>
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home" "$case_dir/elsewhere"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "$(pwd -P)" >> "$NM_LOG"
if [ "${1:-}" = --version ]; then
  printf '%s\n' "no-mistakes version v1.41.2 (fake) 2026-07-24T06:16:03Z"
  exit 0
fi
case "${1:-} ${2:-}" in
  "daemon status")
    [ -z "${NM_STATUS_TEXT:-}" ] || printf '%s\n' "$NM_STATUS_TEXT"
    exit "${NM_STATUS_RC:-0}"
    ;;
  "daemon start")
    [ -z "${NM_START_TEXT:-}" ] || printf '%s\n' "$NM_START_TEXT" >&2
    exit "${NM_START_RC:-0}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  : > "$case_dir/nm.log"
  printf '%s\n' "$case_dir"
}

# Run the helper with the case's stub on PATH. Args: <case_dir> <subcommand>
run_nm() {
  local case_dir=$1 sub=$2
  NM_LOG="$case_dir/nm.log" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
  FM_HOME="$case_dir/home" \
    "$NM" "$sub"
}

start_calls() {
  grep -c '^daemon start|' "$1/nm.log" 2>/dev/null || true
}

start_cwd() {
  grep '^daemon start|' "$1/nm.log" 2>/dev/null | head -n 1 | cut -d'|' -f2
}

# --- signal 1 alone: a live pid, with wording the verdict cannot recognize ----

test_live_pid_alone_proves_running() {
  local case_dir pid status_text out
  case_dir=$(make_case live-pid-alone)
  pid=$(start_live_process)
  # Deliberately UNRECOGNIZABLE prose: no "daemon running", no "not running".
  status_text="  supervisor process [pid $pid] attached"
  export NM_STATUS_TEXT="$status_text" NM_STATUS_RC=0
  # Assert the divergence itself, so this case cannot silently degrade into a
  # duplicate of the status-text case if the verdict's wording checks change.
  assert_not_contains "$status_text" "daemon running" \
    "live-pid-alone: fixture text must not carry the affirmative vendor phrase"
  assert_not_contains "$status_text" "not running" \
    "live-pid-alone: fixture text must not carry the negative vendor phrase"

  out=$(run_nm "$case_dir" status)
  unset NM_STATUS_TEXT NM_STATUS_RC
  [ "$out" = running ] || fail "live-pid-alone: expected verdict running, got '$out'"
  pass "a live pid alone proves the daemon running when the rendered wording is unrecognized"
}

# --- signal 2 alone: the vendor's affirmative line, with no pid at all --------

test_status_text_alone_proves_running() {
  local case_dir status_text out
  case_dir=$(make_case status-text-alone)
  status_text="  daemon running"
  export NM_STATUS_TEXT="$status_text" NM_STATUS_RC=0
  # Divergence: there is no pid anywhere, so the kernel signal cannot fire.
  printf '%s\n' "$status_text" | grep -Eqi 'pid' \
    && fail "status-text-alone: fixture must not expose a pid"

  out=$(run_nm "$case_dir" status)
  unset NM_STATUS_TEXT NM_STATUS_RC
  [ "$out" = running ] || fail "status-text-alone: expected verdict running, got '$out'"
  pass "the vendor status line alone proves the daemon running when no pid is reported"
}

# --- idempotence: a healthy daemon is left completely alone ------------------

test_healthy_daemon_is_left_untouched() {
  local case_dir pid rc out err
  case_dir=$(make_case healthy-untouched)
  pid=$(start_live_process)
  export NM_STATUS_TEXT="  ● daemon running (pid $pid)" NM_STATUS_RC=0

  set +e
  out=$(run_nm "$case_dir" ensure 2>"$case_dir/err")
  rc=$?
  set -e
  unset NM_STATUS_TEXT NM_STATUS_RC
  err=$(cat "$case_dir/err")

  expect_code 0 "$rc" "healthy-untouched: ensure must succeed"
  [ -z "$out" ] || fail "healthy-untouched: ensure wrote to stdout: $out"
  [ -z "$err" ] || fail "healthy-untouched: ensure was not silent: $err"
  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "healthy-untouched: ensure started a daemon that was already healthy"
  pass "ensure is a silent no-op against a healthy daemon (idempotent)"
}

# --- recovery: a provably down daemon is started from a safe directory -------

test_down_daemon_is_started_from_the_firstmate_home() {
  local case_dir rc out err
  case_dir=$(make_case down-restored)
  export NM_STATUS_TEXT="  ○ daemon not running" NM_STATUS_RC=0

  set +e
  out=$(run_nm "$case_dir" ensure 2>"$case_dir/err")
  rc=$?
  set -e
  unset NM_STATUS_TEXT NM_STATUS_RC
  err=$(cat "$case_dir/err")

  expect_code 0 "$rc" "down-restored: ensure must succeed after starting the daemon"
  [ -z "$out" ] || fail "down-restored: ensure wrote to stdout: $out"
  [ "$(start_calls "$case_dir")" = 1 ] \
    || fail "down-restored: expected exactly one daemon start, got $(start_calls "$case_dir")"
  [ "$(start_cwd "$case_dir")" = "$(cd "$case_dir/home" && pwd -P)" ] \
    || fail "down-restored: daemon started from '$(start_cwd "$case_dir")', not the firstmate home"
  assert_contains "$err" "started it from" "down-restored: the restart was not reported"
  pass "a provably down daemon is restarted from the firstmate home"
}

# --- the daemon must never be started on anything short of proof it is down ---

test_unprovable_pid_never_triggers_a_start() {
  local case_dir pid rc out err
  case_dir=$(make_case unprovable-pid)
  pid=$(dead_pid)
  # Claims healthy while naming a pid we cannot signal. That is contradictory,
  # not proof of death (a foreign-owned pid fails kill -0 with EPERM too), and
  # starting here would risk refreshing a live daemon out from under live runs.
  export NM_STATUS_TEXT="  ● daemon running (pid $pid)" NM_STATUS_RC=0

  out=$(run_nm "$case_dir" status)
  [ "$out" = unknown ] || fail "unprovable-pid: expected verdict unknown, got '$out'"

  set +e
  run_nm "$case_dir" ensure >/dev/null 2>"$case_dir/err"
  rc=$?
  set -e
  unset NM_STATUS_TEXT NM_STATUS_RC
  err=$(cat "$case_dir/err")

  expect_code 1 "$rc" "unprovable-pid: an indeterminate state must report failure"
  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "unprovable-pid: ensure started a daemon on an indeterminate verdict"
  assert_contains "$err" "indeterminate" "unprovable-pid: the doubt was not reported"
  pass "an unprovable pid yields unknown and starts nothing"
}

test_contradictory_negative_with_a_pid_starts_nothing() {
  local case_dir out stale
  case_dir=$(make_case contradictory-negative)
  stale=$(dead_pid)
  # A negative claim that still names a pid contradicts itself. The pid is a
  # reaped one, so the kernel signal cannot resolve the contradiction either -
  # which is exactly when the safe answer is "do nothing".
  export NM_STATUS_TEXT="  ○ daemon not running (stale record pid $stale)" NM_STATUS_RC=0

  out=$(run_nm "$case_dir" status)
  [ "$out" = unknown ] || fail "contradictory-negative: expected verdict unknown, got '$out'"

  run_nm "$case_dir" ensure >/dev/null 2>&1 || true
  unset NM_STATUS_TEXT NM_STATUS_RC
  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "contradictory-negative: ensure started a daemon on a self-contradictory status"
  pass "a negative status that still names a pid is treated as unknown, not down"
}

# --- homes without no-mistakes behave exactly as before ----------------------

test_missing_no_mistakes_is_a_clean_no_op() {
  local case_dir rc out err verdict
  case_dir=$(make_case no-no-mistakes)
  rm -f "$case_dir/fakebin/no-mistakes"

  verdict=$(NM_LOG="$case_dir/nm.log" PATH="$case_dir/fakebin:$BASE_PATH" \
    FM_HOME="$case_dir/home" "$NM" status)
  [ "$verdict" = absent ] || fail "no-no-mistakes: expected verdict absent, got '$verdict'"

  set +e
  out=$(NM_LOG="$case_dir/nm.log" PATH="$case_dir/fakebin:$BASE_PATH" \
    FM_HOME="$case_dir/home" "$NM" ensure 2>"$case_dir/err")
  rc=$?
  set -e
  err=$(cat "$case_dir/err")

  expect_code 0 "$rc" "no-no-mistakes: ensure must succeed where no-mistakes is absent"
  [ -z "$out" ] || fail "no-no-mistakes: ensure wrote to stdout: $out"
  [ -z "$err" ] || fail "no-no-mistakes: ensure was not silent: $err"
  pass "a home without no-mistakes installed is a clean, silent no-op"
}

test_build_without_a_daemon_surface_is_silent() {
  local case_dir rc out err verdict
  case_dir=$(make_case no-daemon-surface)
  # An installed build that rejects `daemon status` as an unsupported subcommand.
  # That shape is evidence about the SURFACE - there is no daemon status to
  # answer with - so nothing can be done and today's lazy-start behavior is
  # unchanged, and this is the one failing status that stays silent. The case
  # below drives the other shape and must NOT reach absent.
  export NM_STATUS_TEXT='Error: unknown command "daemon" for "no-mistakes"' NM_STATUS_RC=1

  verdict=$(run_nm "$case_dir" status)
  [ "$verdict" = absent ] || fail "no-daemon-surface: expected verdict absent, got '$verdict'"

  set +e
  out=$(run_nm "$case_dir" ensure 2>"$case_dir/err")
  rc=$?
  set -e
  unset NM_STATUS_TEXT NM_STATUS_RC
  err=$(cat "$case_dir/err")

  expect_code 0 "$rc" "no-daemon-surface: ensure must succeed"
  [ -z "$out$err" ] || fail "no-daemon-surface: ensure was not silent: $out$err"
  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "no-daemon-surface: ensure started a daemon it could not reason about"
  pass "an installed build with no usable daemon surface is a silent no-op"
}

test_unrecognized_status_failure_is_reported_not_filed_absent() {
  local case_dir rc out err verdict status_text
  case_dir=$(make_case unrecognized-failure)
  # A `daemon status` that FAILS with wording this verdict cannot classify. That
  # is the shape a genuinely down daemon takes on a build that words its negative
  # differently, so it must not be swallowed as "no surface here" - which would
  # hide the exact outage this script exists to catch. It is still doubt, so it
  # starts nothing; the only guarantee it loses is silence.
  status_text="Error: could not reach the daemon socket"
  export NM_STATUS_TEXT="$status_text" NM_STATUS_RC=1
  # Divergence from the absent case above: no unsupported-subcommand or usage
  # shape anywhere, so the two cannot quietly collapse into one another.
  assert_not_contains "$status_text" "unknown command" \
    "unrecognized-failure: fixture must not look like an unsupported subcommand"
  assert_not_contains "$status_text" "sage:" \
    "unrecognized-failure: fixture must not look like a usage dump"

  verdict=$(run_nm "$case_dir" status)
  [ "$verdict" = unknown ] \
    || fail "unrecognized-failure: expected verdict unknown, got '$verdict'"

  set +e
  out=$(run_nm "$case_dir" ensure 2>"$case_dir/err")
  rc=$?
  set -e
  unset NM_STATUS_TEXT NM_STATUS_RC
  err=$(cat "$case_dir/err")

  expect_code 1 "$rc" "unrecognized-failure: an uninterpretable status must report failure"
  [ -z "$out" ] || fail "unrecognized-failure: ensure wrote to stdout: $out"
  assert_contains "$err" "indeterminate" "unrecognized-failure: the doubt was not reported"
  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "unrecognized-failure: ensure started a daemon it could not reason about"
  pass "a status failure the verdict cannot classify is reported as unknown, never as absent"
}

# --- a wedged daemon socket must not stall teardown or bootstrap -------------

test_hung_status_is_bounded_and_starts_nothing() {
  local case_dir rc err started ended
  case_dir=$(make_case hung-status)
  # A `daemon status` that never returns. Both call sites are on a critical
  # path, so the bound is what keeps a wedged socket from hanging a teardown.
  cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "$(pwd -P)" >> "$NM_LOG"
case "${1:-} ${2:-}" in
  "daemon status") sleep 120 ;;
  "daemon start") exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/no-mistakes"

  started=$(date +%s)
  set +e
  NM_LOG="$case_dir/nm.log" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
  FM_HOME="$case_dir/home" \
  FM_NOMISTAKES_DAEMON_STATUS_TIMEOUT=2 \
    "$NM" ensure >/dev/null 2>"$case_dir/err"
  rc=$?
  set -e
  ended=$(date +%s)
  err=$(cat "$case_dir/err")

  [ "$((ended - started))" -lt 30 ] \
    || fail "hung-status: ensure was not bounded; it took $((ended - started))s"
  expect_code 1 "$rc" "hung-status: a bounded-out status must report failure"
  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "hung-status: ensure started a daemon it could not read the state of"
  assert_contains "$err" "indeterminate" "hung-status: the doubt was not reported"
  pass "a hung daemon status is bounded, reported, and starts nothing"
}

# --- a failed start is reported, never fatal ---------------------------------

test_failed_start_is_reported_not_fatal() {
  local case_dir rc err
  case_dir=$(make_case start-fails)
  export NM_STATUS_TEXT="  ○ daemon not running" NM_STATUS_RC=0 \
    NM_START_RC=1 NM_START_TEXT="permission denied installing the service"

  set +e
  run_nm "$case_dir" ensure >/dev/null 2>"$case_dir/err"
  rc=$?
  set -e
  unset NM_STATUS_TEXT NM_STATUS_RC NM_START_RC NM_START_TEXT
  err=$(cat "$case_dir/err")

  expect_code 1 "$rc" "start-fails: a failed start must be reported as exit 1"
  assert_contains "$err" "could not be started" "start-fails: the failure was not reported"
  assert_contains "$err" "permission denied installing the service" \
    "start-fails: the underlying error was swallowed"
  pass "a daemon that cannot be started is reported with its underlying error"
}

# --- the start directory must never be a returnable worktree -----------------

test_start_directory_avoids_a_linked_worktree() {
  local case_dir safe_home cwd
  case_dir=$(make_case linked-worktree-home)
  # A leased treehouse directory - a crew worktree, or a leased secondmate home -
  # is a LINKED git worktree. Rooting the daemon there is exactly the bug this
  # script prevents, so the start directory must fall through to a safe one.
  fm_git_worktree "$case_dir/repo" "$case_dir/leased" fm/task-x1
  [ -f "$case_dir/leased/.git" ] \
    || fail "linked-worktree-home: fixture is not a linked worktree"
  safe_home="$case_dir/elsewhere"
  export NM_STATUS_TEXT="  ○ daemon not running" NM_STATUS_RC=0

  NM_LOG="$case_dir/nm.log" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
  FM_HOME="$case_dir/leased" \
  HOME="$safe_home" \
    "$NM" ensure 2>/dev/null
  unset NM_STATUS_TEXT NM_STATUS_RC

  cwd=$(start_cwd "$case_dir")
  [ "$cwd" != "$(cd "$case_dir/leased" && pwd -P)" ] \
    || fail "linked-worktree-home: daemon was rooted in a returnable worktree"
  [ "$cwd" = "$(cd "$safe_home" && pwd -P)" ] \
    || fail "linked-worktree-home: expected the daemon started from '$safe_home', got '$cwd'"
  pass "a linked-worktree home is skipped in favor of a directory no return can sweep"
}

# --- the suite-wide neutralizer disables ensure only -------------------------

test_disable_flag_stops_ensure_but_not_status() {
  local case_dir rc verdict
  case_dir=$(make_case disable-flag)
  export NM_STATUS_TEXT="  ○ daemon not running" NM_STATUS_RC=0 \
    FM_NOMISTAKES_DAEMON_DISABLE=1

  set +e
  run_nm "$case_dir" ensure >/dev/null 2>&1
  rc=$?
  set -e
  verdict=$(run_nm "$case_dir" status)
  unset NM_STATUS_TEXT NM_STATUS_RC FM_NOMISTAKES_DAEMON_DISABLE

  expect_code 0 "$rc" "disable-flag: a neutralized ensure must succeed"
  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "disable-flag: ensure started a daemon despite the neutralizer"
  [ "$verdict" = down ] \
    || fail "disable-flag: status must stay truthful, got '$verdict'"
  pass "the test-suite neutralizer stops ensure without blinding status"
}

# --- prevention: bootstrap roots the daemon at the locked session boundary ----

# A fake toolchain complete enough for bootstrap to reach its mutating sweeps
# without emitting unrelated diagnostics.
make_bootstrap_case() {
  local name=$1 case_dir fakebin
  case_dir=$(make_case "$name")
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config"
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi jq curl
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
fi
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.1.1' ;;
  "update --help")
    printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' '0.1.16'
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/treehouse" "$fakebin/tasks-axi" "$fakebin/quota-axi"
  printf '%s\n' "$case_dir"
}

run_bootstrap() {
  local case_dir=$1; shift
  NM_LOG="$case_dir/nm.log" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
  FM_HOME="$case_dir/home" \
  FM_ROOT_OVERRIDE="$case_dir/home" \
  FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=5 \
    env "$@" "$ROOT/bin/fm-bootstrap.sh"
}

test_bootstrap_roots_a_down_daemon_before_any_crewmate_can() {
  local case_dir
  case_dir=$(make_bootstrap_case bootstrap-prevention)
  export NM_STATUS_TEXT="  ○ daemon not running" NM_STATUS_RC=0

  run_bootstrap "$case_dir" >/dev/null 2>&1 || true
  unset NM_STATUS_TEXT NM_STATUS_RC

  [ "$(start_calls "$case_dir")" = 1 ] \
    || fail "bootstrap-prevention: expected bootstrap to start the down daemon exactly once"
  [ "$(start_cwd "$case_dir")" = "$(cd "$case_dir/home" && pwd -P)" ] \
    || fail "bootstrap-prevention: daemon rooted at '$(start_cwd "$case_dir")', not the firstmate home"
  pass "bootstrap roots a down shared daemon in the firstmate home"
}

test_bootstrap_detect_only_never_starts_the_daemon() {
  local case_dir
  case_dir=$(make_bootstrap_case bootstrap-detect-only)
  export NM_STATUS_TEXT="  ○ daemon not running" NM_STATUS_RC=0

  run_bootstrap "$case_dir" FM_BOOTSTRAP_DETECT_ONLY=1 >/dev/null 2>&1 || true
  unset NM_STATUS_TEXT NM_STATUS_RC

  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "bootstrap-detect-only: a lock-refused read-only session started the daemon"
  pass "a read-only bootstrap never starts the shared daemon"
}

test_bootstrap_is_silent_when_the_daemon_is_healthy() {
  local case_dir pid out
  case_dir=$(make_bootstrap_case bootstrap-healthy)
  pid=$(start_live_process)
  export NM_STATUS_TEXT="  ● daemon running (pid $pid)" NM_STATUS_RC=0

  out=$(run_bootstrap "$case_dir" 2>&1) || true
  unset NM_STATUS_TEXT NM_STATUS_RC

  [ "$(start_calls "$case_dir")" = 0 ] \
    || fail "bootstrap-healthy: bootstrap restarted an already-healthy daemon"
  assert_not_contains "$out" "no-mistakes daemon" \
    "bootstrap-healthy: bootstrap was not silent about a healthy daemon"
  pass "bootstrap says nothing when the shared daemon is already healthy"
}

test_live_pid_alone_proves_running
test_status_text_alone_proves_running
test_healthy_daemon_is_left_untouched
test_down_daemon_is_started_from_the_firstmate_home
test_unprovable_pid_never_triggers_a_start
test_contradictory_negative_with_a_pid_starts_nothing
test_missing_no_mistakes_is_a_clean_no_op
test_build_without_a_daemon_surface_is_silent
test_unrecognized_status_failure_is_reported_not_filed_absent
test_hung_status_is_bounded_and_starts_nothing
test_failed_start_is_reported_not_fatal
test_start_directory_avoids_a_linked_worktree
test_disable_flag_stops_ensure_but_not_status
test_bootstrap_roots_a_down_daemon_before_any_crewmate_can
test_bootstrap_detect_only_never_starts_the_daemon
test_bootstrap_is_silent_when_the_daemon_is_healthy
