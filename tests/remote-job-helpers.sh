#!/bin/bash
# Test-owned remote worker launch registry; never reads the mutable worker.pid.

if [ "${1:-}" = --launch ]; then
  shift
  worker=
  for arg in "$@"; do
    case "$arg" in */fm-remote-job-worker.sh) worker=$arg ;; esac
  done
  if [ -n "$worker" ]; then
    start=$(ps -p "$$" -o lstart=) || exit 1
    printf '%s\n%s\n' "$start" "$worker" > "$FM_TEST_REMOTE_JOB_REGISTRY/.launch.$$" || exit 1
    mv "$FM_TEST_REMOTE_JOB_REGISTRY/.launch.$$" "$FM_TEST_REMOTE_JOB_REGISTRY/$$" || exit 1
    [ -d "$FM_TEST_REMOTE_JOB_REGISTRY" ] && [ ! -e "$FM_TEST_REMOTE_JOB_REGISTRY/.closing" ] || exit 1
    if [ -n "${FM_TEST_REMOTE_JOB_AUDIT:-}" ]; then
      printf '%s\t%s\t%s\t%s\n' "$$" "$start" "$worker" "$FM_TEST_REMOTE_JOB_REGISTRY" >> "$FM_TEST_REMOTE_JOB_AUDIT" || exit 1
    fi
  fi
  exec "$FM_TEST_REMOTE_JOB_REAL_NOHUP" "$@"
fi

fm_test_remote_job_init() { # <test-temp-root>
  local helper
  helper=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/remote-job-helpers.sh
  FM_TEST_REMOTE_JOB_REAL_NOHUP=$(command -v nohup) || return 1
  FM_TEST_REMOTE_JOB_REGISTRY="$1/worker-registry"
  FM_TEST_REMOTE_JOB_BIN="$1/worker-bin"
  FM_TEST_REMOTE_JOB_LAUNCH="$FM_TEST_REMOTE_JOB_BIN/nohup"
  export FM_TEST_REMOTE_JOB_REGISTRY FM_TEST_REMOTE_JOB_REAL_NOHUP FM_TEST_REMOTE_JOB_BIN FM_TEST_REMOTE_JOB_LAUNCH
  mkdir -p "$FM_TEST_REMOTE_JOB_REGISTRY" "$FM_TEST_REMOTE_JOB_BIN" || return 1
  cat > "$FM_TEST_REMOTE_JOB_LAUNCH" <<EOF
#!/bin/bash
exec /bin/bash '$helper' --launch "\$@"
EOF
  chmod +x "$FM_TEST_REMOTE_JOB_LAUNCH" || return 1
  export FM_REMOTE_JOB_POLL_SECONDS=0.01
  PATH="$FM_TEST_REMOTE_JOB_BIN:$PATH"
  export PATH
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

fm_test_remote_job_owned_alive() { # <registry-file>
  local file=$1 pid start worker actual_start command
  pid=${file##*/}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  { IFS= read -r start && IFS= read -r worker; } < "$file" || return 1
  actual_start=$(ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ "$start" = "$actual_start" ] || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$command" in *"$worker"*) ;; *) return 1 ;; esac
  FM_TEST_REMOTE_JOB_OWNED_PID=$pid
}

fm_test_remote_job_cleanup() {
  local file attempt=0 alive
  [ -d "$FM_TEST_REMOTE_JOB_REGISTRY" ] || return 0
  : > "$FM_TEST_REMOTE_JOB_REGISTRY/.closing" || return 1
  for file in "$FM_TEST_REMOTE_JOB_REGISTRY"/*; do
    [ -f "$file" ] || continue
    fm_test_remote_job_owned_alive "$file" || continue
    kill -TERM "$FM_TEST_REMOTE_JOB_OWNED_PID" 2>/dev/null || true
  done
  while [ "$attempt" -lt 100 ]; do
    alive=0
    for file in "$FM_TEST_REMOTE_JOB_REGISTRY"/*; do
      [ -f "$file" ] || continue
      if fm_test_remote_job_owned_alive "$file"; then
        alive=1
      else
        wait "${file##*/}" 2>/dev/null || true
      fi
    done
    [ "$alive" -eq 1 ] || return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  printf 'not ok - test-owned remote worker did not stop\n' >&2
  return 1
}
