#!/usr/bin/env bash
# Behavior tests for the bounded remote job queue and worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job)
mkdir -p "$TMP_ROOT"
# `cd ""` succeeds without moving, so an empty root here would canonicalize to
# the current directory and the EXIT trap below would rm -rf this checkout.
[ -n "$TMP_ROOT" ] || exit 1
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
# shellcheck source=tests/remote-job-helpers.sh
. "$ROOT/tests/remote-job-helpers.sh"
fm_test_remote_job_init "$TMP_ROOT" || exit 1
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
RUNTIME_BIN="$TMP_ROOT/runtime-bin"
FAKE_PERL_LOG="$TMP_ROOT/perl.log"
REAL_GIT=$(command -v git)
OTHER_PID=
RECOVERY_WORKER_PID=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$RUNTIME_BIN"
trap 'if [ -n "$OTHER_PID" ]; then kill "$OTHER_PID" 2>/dev/null || true; fi; fm_test_remote_job_cleanup || exit 1; rm -rf -- "$TMP_ROOT"' EXIT

worker_fixture() {
  local dir=$1
  mkdir -p "$dir/root/bin" "$dir/account"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$dir/root/bin/"
  printf 'fixture\n' > "$dir/root/CLAUDE.md"
}

worker_wait_ready() {
  local dir=$1 attempt=0
  while [ "$attempt" -lt 100 ]; do
    [ ! -f "$dir/state/worker.ready" ] || return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  fail "lifetime fixture worker did not become ready"
}

worker_wait_gone() {
  local pid=$1 attempt=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  kill -0 "$pid" 2>/dev/null && fail "worker survived removal of its directories"
  wait "$pid" || fail "worker directory removal did not exit cleanly"
}

preparation_cleanup() {
  local pid start current
  touch "$PREPARATION/release" "$PREPARATION/drain-release"
  while IFS=$'\t' read -r pid start; do
    current=$(ps -p "$pid" -o lstart= 2>/dev/null) || continue
    [ "$current" = "$start" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done < "$PREPARATION/readers"
  if [ -n "${PREPARATION_PID:-}" ]; then
    if fm_test_remote_job_owned_alive "$FM_TEST_REMOTE_JOB_REGISTRY/$PREPARATION_PID"; then
      kill -TERM "$PREPARATION_PID" 2>/dev/null || true
    fi
    wait "$PREPARATION_PID" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2030,SC2031 # Preparation fixture settings are subshell-local.
for PREP_PHASE in validation output output-stdout output-stderr output-drain publication; do
  for WORKER_MODE in serve darwin-main supervisor; do
    case "$PREP_PHASE:$WORKER_MODE" in output-*:darwin-main|output-*:supervisor) continue ;; esac
    for MISSING_DIR in state root; do
      (
        PREPARATION="$TMP_ROOT/preparation-$PREP_PHASE-$WORKER_MODE-$MISSING_DIR"
        worker_fixture "$PREPARATION"
        mkdir -p "$PREPARATION/fakebin" "$PREPARATION/account/.local/bin"
        : > "$PREPARATION/readers"
        PREPARATION_PID=
        trap preparation_cleanup EXIT
        cat > "$PREPARATION/root/bin/fm-empty.sh" <<'SH'
#!/bin/bash
printf 'ran\n'
SH
        chmod +x "$PREPARATION/root/bin/fm-empty.sh"
        git -C "$PREPARATION/root" init -q -b main
        git -C "$PREPARATION/root" add bin
        (
          export FM_REMOTE_JOB_STATE_ROOT="$PREPARATION/state"
          # shellcheck source=bin/fm-remote-job-lib.sh
          . "$PREPARATION/root/bin/fm-remote-job-lib.sh"
          fm_remote_job_stage "$PREPARATION/account" "$PREPARATION/root" "$PREPARATION/account" \
            fm-empty.sh </dev/null >/dev/null || exit 1
          printf '%s\n' "$FM_REMOTE_JOB_ID" > "$PREPARATION/job-id"
        ) || fail "could not stage preparation job"
        if [ "$PREP_PHASE" = validation ]; then
          cat > "$PREPARATION/account/.local/bin/git" <<SH
#!/bin/bash
if [ "\${3:-}" = ls-files ]; then
  : > '$PREPARATION/entered'
  exec sleep 20
fi
exec '$REAL_GIT' "\$@"
SH
          chmod +x "$PREPARATION/account/.local/bin/git"
        elif [ "$PREP_PHASE" = publication ]; then
          cat > "$PREPARATION/account/.local/bin/git" <<SH
#!/bin/bash
if [ "\${3:-}" = ls-files ]; then
  : > '$PREPARATION/validation-refused'
  exit 1
fi
exec '$REAL_GIT' "\$@"
SH
          chmod +x "$PREPARATION/account/.local/bin/git"
          cat > "$PREPARATION/fakebin/mktemp" <<'SH'
#!/bin/bash
case "$*" in
  */.exit.XXXXXX)
    : > "$PREPARATION/entered"
    attempt=0
    while [ ! -f "$PREPARATION/release" ] && [ "$attempt" -lt 100 ]; do
      attempt=$((attempt + 1))
      sleep 0.01
    done
    [ -f "$PREPARATION/release" ] || exit 1
    ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
          chmod +x "$PREPARATION/fakebin/mktemp"
        else
          cat > "$PREPARATION/fakebin/date" <<'SH'
#!/bin/bash
if [ -n "$(find "$FM_REMOTE_JOB_STATE_ROOT/jobs" -name .stdout.pipe -print -quit 2>/dev/null)" ] && [ ! -f "$PREPARATION/entered" ]; then
  : > "$PREPARATION/entered"
  attempt=0
  while [ ! -f "$PREPARATION/release" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ -f "$PREPARATION/release" ] || exit 1
fi
exec "$REAL_DATE" "$@"
SH
          chmod +x "$PREPARATION/fakebin/date"
        fi
        if [ "$PREP_PHASE" = output-drain ]; then
          cat > "$PREPARATION/fakebin/sleep" <<'SH'
#!/bin/bash
if [ -f "$PREPARATION/drain-armed" ] && [ "$PPID" = "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" 2>/dev/null)" ]; then
  : > "$PREPARATION/drain-entered"
  attempt=0
  while [ ! -f "$PREPARATION/drain-release" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    "$REAL_SLEEP" 0.01
  done
  [ -f "$PREPARATION/drain-release" ] || exit 1
fi
exec "$REAL_SLEEP" "$@"
SH
          chmod +x "$PREPARATION/fakebin/sleep"
        fi
        WORKER_ARG=
        PLATFORM=Linux
        case "$WORKER_MODE" in serve) WORKER_ARG=--serve ;; darwin-main) PLATFORM=Darwin ;; esac
        env PREPARATION="$PREPARATION" REAL_DATE="$(command -v date)" REAL_MKTEMP="$(command -v mktemp)" REAL_SLEEP="$(command -v sleep)" PATH="$PREPARATION/fakebin:$PATH" \
          HOME="$PREPARATION/account" FM_ROOT_OVERRIDE="$PREPARATION/root" \
          FM_REMOTE_JOB_STATE_ROOT="$PREPARATION/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE="$PLATFORM" \
          "$FM_TEST_REMOTE_JOB_LAUNCH" "$PREPARATION/root/bin/fm-remote-job-worker.sh" ${WORKER_ARG:+"$WORKER_ARG"} \
          > "$PREPARATION/out" 2> "$PREPARATION/err" &
        PREPARATION_PID=$!
        PREPARATION_ATTEMPT=0
        while [ ! -f "$PREPARATION/entered" ] && [ "$PREPARATION_ATTEMPT" -lt 100 ]; do
          PREPARATION_ATTEMPT=$((PREPARATION_ATTEMPT + 1))
          sleep 0.01
        done
        assert_present "$PREPARATION/entered" "$PREP_PHASE did not reach the removal barrier"
        SERVE_PID=$(cat "$PREPARATION/state/worker.pid")
        if [ "$PREP_PHASE" = publication ]; then
          assert_present "$PREPARATION/validation-refused" "publication barrier did not follow rejected validation"
        fi
        if [ "${PREP_PHASE%%-*}" = output ]; then
          CHILDREN=$(ps -A -o pid=,ppid= | awk -v parent="$SERVE_PID" '$2 == parent {print $1}')
          for CHILD in $CHILDREN; do
            CHILD_COMMAND=$(ps -p "$CHILD" -o command= 2>/dev/null) || continue
            case "$CHILD_COMMAND" in
              *"$PREPARATION/root/bin/fm-remote-job-worker.sh"*)
                CHILD_START=$(ps -p "$CHILD" -o lstart=) || fail "capture reader vanished before removal"
                printf '%s\t%s\n' "$CHILD" "$CHILD_START" >> "$PREPARATION/readers"
                ;;
            esac
          done
          [ "$(wc -l < "$PREPARATION/readers" | tr -d ' ')" = 2 ] || fail "output barrier did not capture both FIFO readers"
          if [ "$PREP_PHASE" = output-drain ]; then
            rm -f -- "$PREPARATION/state/jobs/$(cat "$PREPARATION/job-id")/stdin"
            touch "$PREPARATION/drain-armed" "$PREPARATION/release"
            PREPARATION_ATTEMPT=0
            while [ ! -f "$PREPARATION/drain-entered" ] && [ "$PREPARATION_ATTEMPT" -lt 100 ]; do
              PREPARATION_ATTEMPT=$((PREPARATION_ATTEMPT + 1))
              sleep 0.01
            done
            assert_present "$PREPARATION/drain-entered" "worker did not poll its blocked output readers"
          elif [ "$PREP_PHASE" != output ]; then
            FINISHED_STREAM=${PREP_PHASE#output-}
            printf 'drained\n' > "$PREPARATION/state/jobs/$(cat "$PREPARATION/job-id")/.$FINISHED_STREAM.pipe"
            PREPARATION_ATTEMPT=0
            while [ "$(wc -c < "$PREPARATION/state/jobs/$(cat "$PREPARATION/job-id")/$FINISHED_STREAM" | tr -d ' ')" = 0 ] && [ "$PREPARATION_ATTEMPT" -lt 100 ]; do
              PREPARATION_ATTEMPT=$((PREPARATION_ATTEMPT + 1))
              sleep 0.01
            done
            assert_grep drained "$PREPARATION/state/jobs/$(cat "$PREPARATION/job-id")/$FINISHED_STREAM" "capture reader did not drain the released stream"
            PREPARATION_ATTEMPT=0
            while [ "$PREPARATION_ATTEMPT" -lt 100 ]; do
              LIVE_READERS=0
              while IFS=$'\t' read -r CHILD CHILD_START; do
                CURRENT_START=$(ps -p "$CHILD" -o lstart= 2>/dev/null || true)
                [ "$CURRENT_START" != "$CHILD_START" ] || LIVE_READERS=$((LIVE_READERS + 1))
              done < "$PREPARATION/readers"
              [ "$LIVE_READERS" != 1 ] || break
              PREPARATION_ATTEMPT=$((PREPARATION_ATTEMPT + 1))
              sleep 0.01
            done
            [ "$LIVE_READERS" = 1 ] || fail "released stream did not leave exactly one blocked reader"
          fi
        elif [ "$PREP_PHASE" = validation ]; then
          VALIDATION_GROUP=$(cat "$PREPARATION/state/jobs/$(cat "$PREPARATION/job-id")/.claim/group")
        fi
        # Rename, not rm -rf: a heartbeat written mid-traversal makes rm -rf fail
        # with "Directory not empty" and leaves the directory in place.
        mv -- "${PREPARATION:?}/$MISSING_DIR" "$PREPARATION/removed-$MISSING_DIR"
        touch "$PREPARATION/release" "$PREPARATION/drain-release"
        worker_wait_gone "$PREPARATION_PID"
        PREPARATION_PID=
        if [ "$PREP_PHASE" = validation ]; then
          kill -0 -- "-$VALIDATION_GROUP" 2>/dev/null && fail "validation command survived directory removal"
        elif [ "${PREP_PHASE%%-*}" = output ]; then
          while IFS=$'\t' read -r CHILD CHILD_START; do
            CURRENT_START=$(ps -p "$CHILD" -o lstart= 2>/dev/null || true)
            [ "$CURRENT_START" != "$CHILD_START" ] || fail "capture reader survived directory removal"
          done < "$PREPARATION/readers"
        fi
        assert_absent "${PREPARATION:?}/$MISSING_DIR" "preparation recreated the removed directory"
        pass "$WORKER_MODE exits cleanly after $MISSING_DIR removal during $PREP_PHASE preparation"
      ) || fail "$PREP_PHASE preparation removal failed for $WORKER_MODE ($MISSING_DIR)"
    done
  done
done

HEALTHY="$TMP_ROOT/healthy"
worker_fixture "$HEALTHY"
HOME="$HEALTHY/account" FM_ROOT_OVERRIDE="$HEALTHY/root" \
  FM_REMOTE_JOB_STATE_ROOT="$HEALTHY/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$FM_TEST_REMOTE_JOB_LAUNCH" "$HEALTHY/root/bin/fm-remote-job-worker.sh" \
  > "$HEALTHY/out" 2> "$HEALTHY/err" &
HEALTHY_PID=$!
worker_wait_ready "$HEALTHY"

# shellcheck disable=SC2030,SC2031 # Lifetime fixture settings are subshell-local.
for WORKER_MODE in serve supervisor; do
  for MISSING_DIR in root state; do
    LIFETIME="$TMP_ROOT/lifetime-$WORKER_MODE-$MISSING_DIR"
    worker_fixture "$LIFETIME"
    (
      FM_REMOTE_JOB_STATE_ROOT="$LIFETIME/state"
      # shellcheck source=bin/fm-remote-job-lib.sh
      . "$LIFETIME/root/bin/fm-remote-job-lib.sh"
      fm_remote_job_prepare_state "$LIFETIME/account" || exit 1
    ) || fail "could not prepare the lifetime fixture state"
    mkdir -p "$LIFETIME/fakebin"
    if [ "$MISSING_DIR" = state ]; then
      cat > "$LIFETIME/fakebin/dirname" <<'SH'
#!/bin/bash
if [ "$*" = "$FM_REMOTE_JOB_STATE_ROOT" ] && [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.ready" ]; then
  printf 'entered\n' > "$LIFETIME/maintenance-entered"
  attempt=0
  while [ ! -f "$LIFETIME/maintenance-release" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ -f "$LIFETIME/maintenance-release" ] || exit 1
fi
exec "$REAL_DIRNAME" "$@"
SH
      chmod +x "$LIFETIME/fakebin/dirname"
    fi
    WORKER_ARG=
    [ "$WORKER_MODE" != serve ] || WORKER_ARG=--serve
    env LIFETIME="$LIFETIME" REAL_DIRNAME="$(command -v dirname)" PATH="$LIFETIME/fakebin:$PATH" \
    HOME="$LIFETIME/account" FM_ROOT_OVERRIDE="$LIFETIME/root" \
      FM_REMOTE_JOB_STATE_ROOT="$LIFETIME/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
      "$FM_TEST_REMOTE_JOB_LAUNCH" "$LIFETIME/root/bin/fm-remote-job-worker.sh" ${WORKER_ARG:+"$WORKER_ARG"} \
      > "$LIFETIME/out" 2> "$LIFETIME/err" &
    LIFETIME_PID=$!
    worker_wait_ready "$LIFETIME"
    if [ "$MISSING_DIR" = state ]; then
      MAINTENANCE_ATTEMPT=0
      while [ ! -f "$LIFETIME/maintenance-entered" ] && [ "$MAINTENANCE_ATTEMPT" -lt 100 ]; do
        MAINTENANCE_ATTEMPT=$((MAINTENANCE_ATTEMPT + 1))
        sleep 0.01
      done
      assert_present "$LIFETIME/maintenance-entered" "queue maintenance did not reach the deletion barrier"
    fi
    mv -- "${LIFETIME:?}/$MISSING_DIR" "$LIFETIME/removed-$MISSING_DIR"
    touch "$LIFETIME/maintenance-release"
    worker_wait_gone "$LIFETIME_PID"
    assert_absent "${LIFETIME:?}/$MISSING_DIR" "worker recreated its removed directory"
    kill -0 "$HEALTHY_PID" 2>/dev/null || fail "directory removal disturbed a healthy worker"
    pass "$WORKER_MODE exits cleanly when $MISSING_DIR disappears"
  done
done


# shellcheck disable=SC2030,SC2031 # Active fixture settings are subshell-local.
for MISSING_DIR in root state; do
  ACTIVE="$TMP_ROOT/active-$MISSING_DIR"
  worker_fixture "$ACTIVE"
  cat > "$ACTIVE/root/bin/fm-block.sh" <<'SH'
#!/bin/bash
printf 'started\n' > "$1"
exec sleep 20
SH
  chmod +x "$ACTIVE/root/bin/fm-block.sh"
  git -C "$ACTIVE/root" init -q -b main
  git -C "$ACTIVE/root" config --local commit.gpgsign false
  git -C "$ACTIVE/root" -c user.name=Test -c user.email=test@example.com add CLAUDE.md bin
  git -C "$ACTIVE/root" -c user.name=Test -c user.email=test@example.com commit -qm fixture
  (
    export FM_REMOTE_JOB_STATE_ROOT="$ACTIVE/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ACTIVE/root/bin/fm-remote-job-lib.sh"
    fm_remote_job_stage "$ACTIVE/account" "$ACTIVE/root" "$ACTIVE/account" \
      fm-block.sh "$ACTIVE/started" </dev/null || exit 1
    printf '%s\n' "$FM_REMOTE_JOB_ID" > "$ACTIVE/job-id"
  ) || fail "could not stage active lifetime job"
  HOME="$ACTIVE/account" FM_ROOT_OVERRIDE="$ACTIVE/root" \
    FM_REMOTE_JOB_STATE_ROOT="$ACTIVE/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$FM_TEST_REMOTE_JOB_LAUNCH" "$ACTIVE/root/bin/fm-remote-job-worker.sh" \
    > "$ACTIVE/out" 2> "$ACTIVE/err" &
  ACTIVE_PID=$!
  ACTIVE_ATTEMPT=0
  while [ ! -f "$ACTIVE/started" ] && [ "$ACTIVE_ATTEMPT" -lt 100 ]; do
    ACTIVE_ATTEMPT=$((ACTIVE_ATTEMPT + 1))
    sleep 0.01
  done
  assert_present "$ACTIVE/started" "active lifetime job did not start"
  ACTIVE_GROUP=$(cat "$ACTIVE/state/jobs/$(cat "$ACTIVE/job-id")/.claim/group")
  mv -- "${ACTIVE:?}/$MISSING_DIR" "$ACTIVE/removed-$MISSING_DIR"
  worker_wait_gone "$ACTIVE_PID"
  kill -0 -- "-$ACTIVE_GROUP" 2>/dev/null && fail "directory removal left an active command group"
  assert_absent "${ACTIVE:?}/$MISSING_DIR" "active worker recreated a removed directory"
  pass "active worker stops its command and exits cleanly when $MISSING_DIR disappears"
done

for EXIT_MODE in launch-race immediate success failure HUP INT TERM; do
  REAP_FIXTURE="$TMP_ROOT/reap-$EXIT_MODE"
  worker_fixture "$REAP_FIXTURE"
  mkdir -p "$REAP_FIXTURE/fakebin"
  cat > "$REAP_FIXTURE/fakebin/ps" <<'SH'
#!/bin/bash
printf 'started\n' > "$REAP_FIXTURE/ps-started"
attempt=0
while [ ! -f "$REAP_FIXTURE/ps-release" ] && [ "$attempt" -lt 100 ]; do
  attempt=$((attempt + 1))
  sleep 0.01
done
[ -f "$REAP_FIXTURE/ps-release" ] || exit 1
exec "$REAL_PS" "$@"
SH
  chmod +x "$REAP_FIXTURE/fakebin/ps"
  cat > "$REAP_FIXTURE/test.sh" <<'SH'
#!/bin/bash
set -eu
. "$ROOT/tests/remote-job-helpers.sh"
fm_test_remote_job_init "$REAP_FIXTURE"
trap 'fm_test_remote_job_cleanup || exit 1' EXIT
export HOME="$REAP_FIXTURE/account" FM_ROOT_OVERRIDE="$REAP_FIXTURE/root"
export FM_REMOTE_JOB_STATE_ROOT="$REAP_FIXTURE/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
. "$REAP_FIXTURE/root/bin/fm-remote-job-lib.sh"
if [ "$EXIT_MODE" = launch-race ]; then export PATH="$REAP_FIXTURE/fakebin:$PATH"; fi
fm_remote_job_start_linux_worker "$FM_ROOT_OVERRIDE" "$HOME"
if [ "$EXIT_MODE" = launch-race ]; then
  attempt=0
  while [ ! -f "$REAP_FIXTURE/ps-started" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ -f "$REAP_FIXTURE/ps-started" ] || exit 1
  exit 0
fi
[ "$EXIT_MODE" != immediate ] || exit 0
fm_remote_job_wait_for_probe "$FM_ROOT_OVERRIDE" "$HOME"
printf '\n' >> "$REAP_FIXTURE/root/bin/fm-remote-job-worker.sh"
fm_remote_job_start_linux_worker "$FM_ROOT_OVERRIDE" "$HOME"
fm_remote_job_wait_for_probe "$FM_ROOT_OVERRIDE" "$HOME"
if [ "$EXIT_MODE" = success ]; then
  printf '%s\n' "$HEALTHY_PID" > "$REAP_FIXTURE/state/worker.pid"
else
  rm -f "$REAP_FIXTURE/state/worker.pid"
fi
case "$EXIT_MODE" in
  success) exit 0 ;;
  failure) exit 7 ;;
  *) kill -"$EXIT_MODE" "$$" ;;
esac
SH
  REAP_SCRIPT="$REAP_FIXTURE/test.sh"
  ROOT="$ROOT" REAP_FIXTURE="$REAP_FIXTURE" EXIT_MODE="$EXIT_MODE" HEALTHY_PID="$HEALTHY_PID" REAL_PS="$(command -v ps)" \
    FM_TEST_REMOTE_JOB_REAL_NOHUP="$FM_TEST_REMOTE_JOB_REAL_NOHUP" \
    PATH="${PATH#"$FM_TEST_REMOTE_JOB_BIN:"}" /bin/bash "$REAP_SCRIPT"
  REAP_RC=$?
  touch "$REAP_FIXTURE/ps-release"
  case "$EXIT_MODE" in
    launch-race|immediate|success) expect_code 0 "$REAP_RC" "normal cleanup failed" ;;
    failure) expect_code 7 "$REAP_RC" "cleanup changed the failure status" ;;
    HUP) expect_code 129 "$REAP_RC" "HUP cleanup failed" ;;
    INT) expect_code 130 "$REAP_RC" "INT cleanup failed" ;;
    TERM) expect_code 143 "$REAP_RC" "TERM cleanup failed" ;;
  esac
  REGISTRY_COUNT=$(find "$REAP_FIXTURE/worker-registry" -type f -name '[0-9]*' | wc -l | tr -d ' ')
  [ "$EXIT_MODE" = launch-race ] || [ "$EXIT_MODE" = immediate ] || [ "$REGISTRY_COUNT" -ge 2 ] || fail "replacement launches were not registered"
  REAP_ATTEMPT=0
  while [ "$REAP_ATTEMPT" -lt 100 ]; do
    PROCESS_COMMANDS=$(ps -A -o command=)
    LEFTOVER=$(printf '%s\n' "$PROCESS_COMMANDS" | awk -v worker="$REAP_FIXTURE/root/bin/fm-remote-job-worker.sh" 'index($0, worker) {print}')
    [ -n "$LEFTOVER" ] || break
    REAP_ATTEMPT=$((REAP_ATTEMPT + 1))
    sleep 0.01
  done
  [ -z "$LEFTOVER" ] || fail "test-owned worker survived $EXIT_MODE cleanup"
  kill -0 "$HEALTHY_PID" 2>/dev/null || fail "cleanup signalled a worker it did not start"
  pass "shared cleanup reaps replaced workers independently of worker.pid on $EXIT_MODE"
done

kill -TERM "$HEALTHY_PID"
wait "$HEALTHY_PID" || fail "healthy worker did not shut down cleanly"

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/CLAUDE.md"
ln -s CLAUDE.md "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
set -u
printf 'home=%s\nroot=%s\nactive=%s\npath=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE" "${FM_REMOTE_JOB_ACTIVE:-}" "$PATH"
printf 'args:'
printf ' <%s>' "$@"
printf '\n'
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
exit "${FM_PROBE_EXIT:-0}"
SH
cat > "$REMOTE_ROOT/bin/fm-timeout-job.sh" <<'SH'
#!/bin/bash
sleep 3
SH
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
cat > "$REMOTE_ROOT/bin/fm-shutdown-job.sh" <<'SH'
#!/bin/bash
trap '' HUP INT TERM
printf 'started\n' > "$1"
sleep 3
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-output-job.sh" <<'SH'
#!/bin/bash
set -e
head -c 1200000 < /dev/zero
head -c 1200000 < /dev/zero >&2
exit 23
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
cat > "$RUNTIME_BIN/perl" <<'SH'
#!/bin/bash
printf 'invoked\n' >> "$FM_FAKE_PERL_LOG"
exit 127
SH
chmod +x "$RUNTIME_BIN/perl"

git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config --local commit.gpgsign false
git -C "$REMOTE_ROOT" config --local tag.gpgsign false
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md CLAUDE.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

DEFAULT_STATE="$TMP_ROOT/default-timeout-jobs"
DEFAULT_BOUNDS=$(
  unset FM_REMOTE_JOB_QUEUE_TIMEOUT
  unset FM_REMOTE_JOB_TIMEOUT
  # shellcheck disable=SC2030 # This source intentionally initializes subshell-only defaults.
  FM_REMOTE_JOB_STATE_ROOT="$DEFAULT_STATE"
  export FM_REMOTE_JOB_STATE_ROOT
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$ROOT/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh </dev/null >/dev/null
  printf '%s %s\n' \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/queue_deadline")" \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/timeout")"
)
read -r DEFAULT_QUEUE_DEADLINE DEFAULT_EXECUTION_TIMEOUT <<< "$DEFAULT_BOUNDS"
DEFAULT_QUEUE_REMAINING=$((DEFAULT_QUEUE_DEADLINE - $(date +%s)))
[ "$DEFAULT_QUEUE_REMAINING" -ge 350 ] || fail "the default queue bound is too short"
[ "$DEFAULT_EXECUTION_TIMEOUT" -ge 350 ] || fail "the default execution bound cannot contain a 300-second long poll"
pass "default queue and execution bounds independently cover long polls"

# shellcheck disable=SC2031 # The earlier assignment was confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
# shellcheck disable=SC2031 # Lifetime fixture overrides did not escape their subshells.
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_TIMEOUT=5
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

LOCAL_BIN_PARENT="$ACCOUNT_HOME/.local"
LOCAL_BIN_TARGET="$TMP_ROOT/local-bin-target"
mkdir -p "$LOCAL_BIN_PARENT" "$LOCAL_BIN_TARGET"
ln -s "$LOCAL_BIN_TARGET" "$LOCAL_BIN_PARENT/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$LOCAL_BIN_PARENT/bin:"*|*":$LOCAL_BIN_TARGET:"*) fail "the composed PATH followed a symlinked local bin" ;;
esac
rm -f "$LOCAL_BIN_PARENT/bin"
mkdir "$LOCAL_BIN_PARENT/bin"
pass "operator PATH excludes a symlinked local bin"

NVM_ROOT="$ACCOUNT_HOME/.nvm"
NVM_V20="$NVM_ROOT/versions/node/v20.18.0/bin"
NVM_V24="$NVM_ROOT/versions/node/v24.14.1/bin"
mkdir -p "$NVM_ROOT/alias" "$NVM_V20" "$NVM_V24"
printf '20\n' > "$NVM_ROOT/alias/default"
printf '#!/bin/bash\nprintf "20\\n"\n' > "$NVM_V20/node"
printf '#!/bin/bash\nprintf "24\\n"\n' > "$NVM_V24/node"
chmod +x "$NVM_V20/node" "$NVM_V24/node"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 20 ] || fail "the composed PATH ignored nvm's default alias"
rm -f "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 24 ] || fail "the nvm fallback did not select the highest installed version"
printf 'system\n' > "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NVM_V20:"*|*":$NVM_V24:"*) fail "the composed PATH ignored nvm's system default" ;;
esac
printf '20\n' > "$NVM_ROOT/alias/default"
pass "operator PATH honors nvm defaults with a deterministic fallback"

NIX_PROFILE="$ACCOUNT_HOME/.nix-profile"
NIX_BIN="$TMP_ROOT/nix-profile-bin"
mkdir -p "$NIX_PROFILE" "$NIX_BIN"
ln -s "$NIX_BIN" "$NIX_PROFILE/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NIX_BIN:"*) ;;
  *) fail "the composed PATH omitted a resolved Nix profile bin link" ;;
esac
pass "operator PATH resolves the authorized Nix profile bin link"

HOME="$ACCOUNT_HOME" PATH="$RUNTIME_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_PERL_LOG="$FAKE_PERL_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$FM_TEST_REMOTE_JOB_LAUNCH" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not publish its readiness heartbeat"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

printf 'first line\nsecond line\n' > "$TMP_ROOT/stdin"
# shellcheck disable=SC2016 # Literal shell-looking argv is an injection probe.
TOP_SECRET=must-not-cross fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-probe-job.sh 'two words' '$(not executed)' < "$TMP_ROOT/stdin" > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
[ "$(file_mode "$JOB_DIR")" = 700 ] \
  || fail "staged job directory is not mode 0700"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the completed probe did not preserve exit status"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" "home=$REMOTE_HOME" "the worker did not pass the staged FM_HOME"
assert_contains "$OUT" "root=$REMOTE_ROOT" "the worker did not pass the configured root"
assert_contains "$OUT" 'active=1' "the target did not execute inside the worker environment"
# shellcheck disable=SC2016 # Literal shell-looking expected output is an injection probe.
assert_contains "$OUT" 'args: <two words> <$(not executed)>' "the worker changed argv boundaries"
assert_contains "$OUT" 'stdin=first line' "the worker lost staged stdin"
assert_contains "$OUT" 'stdin=second line' "the worker lost staged stdin"
assert_contains "$OUT" 'secret=absent' "ambient environment crossed into the worker child"
case "$OUT" in *"$REMOTE_ROOT/bin:$ACCOUNT_HOME/.local/bin:"*) : ;; *) fail "worker PATH omitted its fixed root and account head" ;; esac
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the completed job could not be reaped"
assert_absent "$JOB_DIR" "reap retained a completed job record"
assert_absent "$FAKE_PERL_LOG" "the worker invoked an unavailable Perl runtime"
pass "the worker preserves bounded argv and stdin in an empty environment"

ACTIVE_SIDE_EFFECT="$TMP_ROOT/active-side-effect"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 4 "$ACTIVE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the active-job readiness fixture did not begin running"
ACTIVE_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
touch -t 200001010000 "$STATE_ROOT/worker.ready"
for _ in $(seq 1 40); do
  fm_remote_job_probe "$ACCOUNT_HOME" && break
  sleep 0.05
done
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the active worker did not refresh its readiness heartbeat"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$STATE_ROOT/worker.pid")" = "$ACTIVE_WORKER_PID" ] \
  || fail "ensure replaced a healthy worker during an active job"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the active job did not complete after the readiness probe"
assert_present "$ACTIVE_SIDE_EFFECT" "the active job was interrupted by the concurrent readiness check"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the active readiness job could not be reaped"
pass "active jobs keep the worker ready for concurrent requests"

OLD_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
printf '\n' >> "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker running stale code"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "the replacement worker did not publish the current code identity"
pass "ensure replaces a live worker after its code changes"

RELOCATED_ROOT="$TMP_ROOT/relocated-root"
cp -R "$REMOTE_ROOT" "$RELOCATED_ROOT"
OLD_WORKER_PID=$NEW_WORKER_PID
fm_remote_job_ensure_worker "$RELOCATED_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker bound to a different code root"
fm_remote_job_stage "$ACCOUNT_HOME" "$RELOCATED_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the relocated worker rejected its configured code root"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the relocated-root probe could not be reaped"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
pass "worker identity binds the canonical configured code root"

CRASHED_WORKER_PID=$NEW_WORKER_PID
kill -KILL "$CRASHED_WORKER_PID"
wait "$CRASHED_WORKER_PID" 2>/dev/null || true
assert_present "$STATE_ROOT/worker.lock" "an unclean exit did not retain the worker ownership lock"
sleep 20 &
OTHER_PID=$!
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.pid"
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.lock/pid"
touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
kill -0 "$OTHER_PID" 2>/dev/null || fail "stale worker state caused an unrelated process to be signaled"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OTHER_PID" ] || fail "the replacement adopted an unrelated persisted pid"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "stale ownership recovery did not start the current worker"
kill "$OTHER_PID" 2>/dev/null || true
wait "$OTHER_PID" 2>/dev/null || true
OTHER_PID=
pass "stale ownership is reclaimed without signaling a reused pid"

FM_REMOTE_JOB_TIMEOUT=1
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the worker did not terminate an over-time job"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the timed-out job could not be reaped"
pass "the worker enforces the job timeout and publishes its result"

QUEUED_SIDE_EFFECT="$TMP_ROOT/queued-side-effect"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the blocking job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$QUEUED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
printf '%s\n' "$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "an expired queued job did not publish a timeout result"
assert_absent "$QUEUED_SIDE_EFFECT" "the worker executed a queued job after its durable deadline"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the blocking job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the expired queued job could not be reaped"
pass "the worker expires queued jobs before they can mutate"

FIRST_DELAYED_SIDE_EFFECT="$TMP_ROOT/first-delayed-side-effect"
SECOND_DELAYED_SIDE_EFFECT="$TMP_ROOT/second-delayed-side-effect"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
FM_REMOTE_JOB_TIMEOUT=3
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$FIRST_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the first delayed job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$SECOND_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "queue time consumed the second job's execution timeout"
assert_present "$SECOND_DELAYED_SIDE_EFFECT" "the queued job did not receive its full execution timeout"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first delayed job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the second delayed job could not be reaped"
pass "queued jobs receive a fresh bounded execution window"

STARTED="$TMP_ROOT/shutdown-started"
SHUTDOWN_SIDE_EFFECT="$TMP_ROOT/shutdown-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$STARTED" "$SHUTDOWN_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$STARTED" ] && break
  sleep 0.05
done
assert_present "$STARTED" "the shutdown fixture did not begin executing"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$WORKER_PID" 2>/dev/null && fail "the worker did not finish its TERM shutdown"
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=1 \
  "$FM_TEST_REMOTE_JOB_LAUNCH" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the replacement worker did not become ready"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "the interrupted job did not publish an unknown-completion result"
sleep 3
assert_absent "$SHUTDOWN_SIDE_EFFECT" "the active command mutated after worker shutdown"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the interrupted job could not be reaped"
pass "worker shutdown terminates the active command tree before replacement"

CRASH_STARTED="$TMP_ROOT/crash-started"
CRASH_SIDE_EFFECT="$TMP_ROOT/crash-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$CRASH_STARTED" "$CRASH_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$CRASH_STARTED" ] && break
  sleep 0.05
done
assert_present "$CRASH_STARTED" "the crash fixture did not begin executing"
CRASHED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -KILL "$CRASHED_WORKER_PID"
for _ in $(seq 1 200); do
  RESTARTED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid" 2>/dev/null || true)
  [ -n "$RESTARTED_WORKER_PID" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] && break
  sleep 0.05
done
[ -n "${RESTARTED_WORKER_PID:-}" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] \
  || fail "the Linux supervisor did not restart a crashed worker"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "worker crash recovery did not publish unknown completion"
sleep 3
assert_absent "$CRASH_SIDE_EFFECT" "an orphaned command mutated after worker crash recovery"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the crash-recovered job could not be reaped"
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the restarted worker did not remain ready"
pass "Linux supervision recovers crashes and stops orphaned commands"

mkdir -p "$ACCOUNT_HOME/.local/bin"
PREEXEC_STARTED="$TMP_ROOT/preexecution-started"
PREEXEC_FINISHED="$TMP_ROOT/preexecution-finished"
cat > "$ACCOUNT_HOME/.local/bin/git" <<SH
#!/bin/bash
if [ "\${3:-}" = ls-files ]; then
  printf 'started\n' > "$PREEXEC_STARTED"
  sleep 30
  printf 'finished\n' > "$PREEXEC_FINISHED"
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$ACCOUNT_HOME/.local/bin/git"
FM_REMOTE_JOB_TIMEOUT=3
PREEXEC_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
PREEXEC_ELAPSED=$(( $(date +%s) - PREEXEC_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the pre-execution deadline did not publish a timeout result"
assert_present "$PREEXEC_STARTED" "the pre-execution timeout fixture did not enter tracked-command validation"
assert_absent "$PREEXEC_FINISHED" "tracked-command validation continued after the job timeout"
[ "$PREEXEC_ELAPSED" -le 7 ] || fail "tracked-command validation exceeded the job timeout bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the pre-execution timeout leaked output readers or FIFOs"
rm -f -- "$ACCOUNT_HOME/.local/bin/git"
pass "pre-execution validation obeys the job timeout"

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-output-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 23 ] || fail "bounded output changed the command exit status"
OUTPUT_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDOUT" | tr -d ' ')
[ "$OUTPUT_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained output beyond its byte bound"
ERROR_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDERR" | tr -d ' ')
[ "$ERROR_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained stderr beyond its byte bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the bounded-output job could not be reaped"
pass "the worker drains bounded output without changing command results"

SIDE_EFFECT="$TMP_ROOT/side-effect"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
for _ in $(seq 1 100); do
  [ ! -f "$STATE_ROOT/worker.pid" ] && break
  sleep 0.05
done
assert_absent "$STATE_ROOT/worker.pid" "the worker did not stop before the staged-record tamper"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
rm -f -- "$JOB_DIR/argv"
ln -s "$TMP_ROOT/not-an-argv" "$JOB_DIR/argv"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 126 ] || fail "the worker accepted a symlinked argv record"
assert_absent "$SIDE_EFFECT" "the worker executed a job after its argv changed to a symlink"
pass "the worker refuses symlinked job fields before command execution"

QUARANTINE_STARTED="$TMP_ROOT/quarantine-started"
QUARANTINE_SIDE_EFFECT="$TMP_ROOT/quarantine-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$QUARANTINE_STARTED" "$QUARANTINE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ -f "$QUARANTINE_STARTED" ] && break
  sleep 0.05
done
assert_present "$QUARANTINE_STARTED" "the quarantine fixture did not begin executing"
GROUP_PID=$(cat "$JOB_DIR/.claim/group")
printf 'invalid\n' > "$JOB_DIR/.claim/group"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
wait "$WORKER_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.lock/quarantine" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.lock/quarantine" "failed shutdown released worker ownership"
fm_remote_job_probe "$ACCOUNT_HOME" && fail "quarantined worker ownership still reported ready"
set +e
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$FM_TEST_REMOTE_JOB_LAUNCH" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err"
REPLACEMENT_RC=$?
set -e
[ "$REPLACEMENT_RC" -ne 0 ] || fail "a replacement worker ignored quarantined ownership"
assert_present "$STATE_ROOT/worker.lock/quarantine" "a replacement removed quarantined ownership"
kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
sleep 3
assert_absent "$QUARANTINE_SIDE_EFFECT" "the quarantined command mutated after explicit termination"
pass "failed shutdown quarantines ownership against replacement workers"

RECOVERY_HOME="$TMP_ROOT/recovery-account"
RECOVERY_STATE="$TMP_ROOT/recovery-jobs"
RECOVERY_JOB="$RECOVERY_STATE/jobs/job-quarantine"
mkdir -p "$RECOVERY_HOME" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB/.claim"
chmod 700 "$RECOVERY_HOME" "$RECOVERY_STATE" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB" "$RECOVERY_JOB/.claim"
sleep 20 &
QUARANTINED_PROCESS_PID=$!
sleep 0.01 &
QUARANTINE_OWNER_PID=$!
wait "$QUARANTINE_OWNER_PID" 2>/dev/null || true
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_STATE/worker.lock/pid"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/start"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/command"
printf 'active execution could not be confirmed stopped\n' > "$RECOVERY_STATE/worker.lock/quarantine"
printf 'running\n' > "$RECOVERY_JOB/state"
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_JOB/.claim/owner"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/supervisor"
: > "$RECOVERY_JOB/stdout"
: > "$RECOVERY_JOB/stderr"
chmod 600 "$RECOVERY_STATE/worker.lock"/* "$RECOVERY_JOB/state" "$RECOVERY_JOB/.claim"/* \
  "$RECOVERY_JOB/stdout" "$RECOVERY_JOB/stderr"
touch -t 200001010000 "$RECOVERY_STATE/worker.lock"
set +e
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$FM_TEST_REMOTE_JOB_LAUNCH" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-refused.out" 2> "$TMP_ROOT/recovery-refused.err"
RECOVERY_REFUSED_RC=$?
set -e
[ "$RECOVERY_REFUSED_RC" -ne 0 ] || fail "quarantine recovery ignored a recorded live process"
assert_present "$RECOVERY_STATE/worker.lock/quarantine" "a live recorded process lost quarantine protection"
kill "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
wait "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$FM_TEST_REMOTE_JOB_LAUNCH" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-worker.out" 2> "$TMP_ROOT/recovery-worker.err" &
RECOVERY_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$RECOVERY_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$RECOVERY_STATE/worker.ready" "a stopped quarantined execution did not permit worker recovery"
assert_absent "$RECOVERY_STATE/worker.lock/quarantine" "recovered worker retained stale quarantine"
kill -TERM "$RECOVERY_WORKER_PID"
wait "$RECOVERY_WORKER_PID" 2>/dev/null || true
RECOVERY_WORKER_PID=
pass "quarantine clears only after recorded execution has stopped"

echo "ALL TESTS PASSED"
