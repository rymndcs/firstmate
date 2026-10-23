#!/usr/bin/env bash
# Behavior tests for detecting omp as firstmate's own primary harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Fake ps whose ancestry is: this script -> bash -> <FM_TEST_PARENT> (pid 4343).
make_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid= prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4343) printf '%s\n' "${FM_TEST_PARENT:?}" ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4343) printf '1\n' ;;
  ppid=:*) printf '4343\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_omp_marker_outranks_claude_marker() {
  local fakebin cfg out
  fakebin=$(fm_fakebin "$TMP_ROOT/marker")
  cfg="$TMP_ROOT/marker/config"
  mkdir -p "$cfg"
  make_ps "$fakebin"
  # omp exports both markers into every bash-tool command.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT OMPCODE=1 CLAUDECODE=1 FM_TEST_PARENT=/bin/zsh \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "omp's marker pair resolved '$out', expected omp"
  out=$(env -u OMPCODE -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 FM_TEST_PARENT=/bin/zsh \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "Claude's own marker resolved '$out', expected claude"
  pass "fm-harness: omp's OMPCODE marker wins over the CLAUDECODE it also exports"
}

test_markerless_omp_is_detected_by_exact_ancestry_name() {
  local fakebin cfg out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry")
  cfg="$TMP_ROOT/ancestry/config"
  mkdir -p "$cfg"
  make_ps "$fakebin"
  # Extension-launched owner scripts inherit omp's process env, not its
  # bash-tool env, so they reach detection without any marker.
  out=$(env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT FM_TEST_PARENT=omp \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "markerless omp parent resolved '$out', expected omp"
  out=$(env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT FM_TEST_PARENT=/usr/local/bin/omptool \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "a process merely named like omp resolved '$out', expected unknown"
  pass "fm-harness: markerless omp ancestry matches only the exact omp name"
}

test_omp_marker_outranks_claude_marker
test_markerless_omp_is_detected_by_exact_ancestry_name
