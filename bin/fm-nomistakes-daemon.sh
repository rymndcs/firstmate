#!/usr/bin/env bash
# Keep the shared no-mistakes daemon rooted OUTSIDE every disposable worktree.
#
# WHY THIS EXISTS
# `treehouse return` terminates the lingering processes of the worktree it is
# returning, and firstmate cannot exclude anything from that sweep. no-mistakes
# starts its ONE shared daemon lazily, so whichever crewmate first runs a
# pipeline roots that daemon in its own task worktree - and the next teardown of
# that worktree kills the daemon out from under every OTHER lane's in-flight
# validation run ("error: daemon shutting down"). A daemon whose working
# directory is the firstmate home instead is outside every worktree and survives.
# The fix therefore has two halves, both of which call `ensure` here:
#   * prevention - bin/fm-bootstrap.sh roots the daemon from the firstmate home
#     at the locked session boundary, before any crewmate can start it lazily;
#   * recovery   - bin/fm-teardown.sh re-checks it after a treehouse return, so
#     a daemon lost some other way is back before concurrent runs notice.
#
# SAFETY DIRECTION
# A false "the daemon is down" verdict is expensive: `no-mistakes daemon start`
# installs-or-refreshes the managed service, so calling it against a LIVE daemon
# risks the very outage this script prevents. A false "cannot tell" verdict costs
# nothing - it just leaves today's lazy-start behavior in place. So the verdict
# below only ever reports `down` on an explicit, unambiguous negative, and every
# other doubt resolves to `unknown`, which starts nothing.
#
# The verdict reads two INDEPENDENT signals so no single vendor string is
# load-bearing, and either one alone can carry a positive result:
#   1. a kernel fact - a reported pid whose process is alive (`kill -0`);
#   2. the vendor's own rendered status line and exit status.
# A pid that cannot be proven alive is NOT proof of death (a foreign-owned pid
# fails `kill -0` with EPERM), so it yields `unknown`, never `down`.
#
# Both calls sit on teardown's and bootstrap's critical path, so each is bounded
# by FM_NOMISTAKES_DAEMON_STATUS_TIMEOUT (10s) and
# FM_NOMISTAKES_DAEMON_START_TIMEOUT (60s) where coreutils `timeout` exists. A
# status that runs out of time is more doubt, so it reports `unknown`.
#
# Usage:
#   fm-nomistakes-daemon.sh ensure     start the shared daemon from a safe
#                                      directory if - and only if - it is
#                                      provably down. Silent when there is
#                                      nothing to do. Notices go to stderr;
#                                      nothing is ever written to stdout.
#                                      Exit 0 = healthy, no-op, or started.
#                                      Exit 1 = a needed start failed, or the
#                                      state could not be determined.
#   fm-nomistakes-daemon.sh status     print the verdict word and exit 0:
#                                        absent  - no usable no-mistakes daemon
#                                                  surface here (not installed,
#                                                  or a build without it)
#                                        running - proven live
#                                        down    - proven not running
#                                        unknown - indeterminate; do nothing
#   fm-nomistakes-daemon.sh --help
#
# FM_NOMISTAKES_DAEMON_DISABLE=1 makes `ensure` an immediate silent no-op. It
# exists for firstmate's own test suite (tests/lib.sh exports it), which drives
# the real teardown and bootstrap paths repeatedly and must never touch the
# shared daemon; `status` ignores it and stays truthful.
#
# Neither subcommand may ever fail a caller's own work: teardown's unlanded-work
# guarantees take absolute precedence over any daemon problem, so callers invoke
# `ensure` best-effort and a daemon failure is reported, never fatal.
#
# START DIRECTORY
# `ensure` starts the daemon from the first of $FM_HOME, $HOME, / that is not
# itself a LINKED git worktree. The linked-worktree test is git's own on-disk
# format - a linked worktree's toplevel `.git` is a gitfile, a main checkout's is
# a directory - which is what makes a treehouse-leased directory (a crew
# worktree, or a leased secondmate home) recognizable without knowing anything
# about treehouse. Rooting the daemon in one of those would reintroduce the exact
# bug this script exists to prevent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# Both calls sit on teardown's and bootstrap's critical path, so neither may
# stall them on a wedged daemon socket. A timed-out status is just more doubt,
# and doubt starts nothing.
NM_STATUS_TIMEOUT=${FM_NOMISTAKES_DAEMON_STATUS_TIMEOUT:-10}
NM_START_TIMEOUT=${FM_NOMISTAKES_DAEMON_START_TIMEOUT:-60}

usage() {
  local code=${1:-0}
  # An explicit request prints to stdout; a usage error prints to stderr.
  if [ "$code" -eq 0 ]; then
    nm_daemon_usage_text
  else
    nm_daemon_usage_text >&2
  fi
  exit "$code"
}

nm_daemon_usage_text() {
  sed -n '/^# Usage:/,/^# *fm-nomistakes-daemon.sh --help$/p' "${BASH_SOURCE[0]}" \
    | sed 's/^# \{0,1\}//'
}

# True when <dir> sits in a LINKED git worktree, i.e. a directory a worktree
# provider can return (and whose processes it then terminates). A directory
# outside any repo, or in a main checkout, is not linked and is safe to use.
nm_daemon_dir_is_linked_worktree() {
  local dir=$1 top
  command -v git >/dev/null 2>&1 || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -f "$top/.git" ]
}

# Run `no-mistakes "$@"` under <seconds>, or plainly where coreutils timeout is
# unavailable. stdin is closed so a prompt can never wait on a terminal.
nm_daemon_run() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" no-mistakes "$@" </dev/null 2>&1
  else
    no-mistakes "$@" </dev/null 2>&1
  fi
}

nm_daemon_start_dir() {
  local dir
  for dir in "$FM_HOME" "${HOME:-}" /; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    nm_daemon_dir_is_linked_worktree "$dir" && continue
    printf '%s\n' "$dir"
    return 0
  done
  printf '%s\n' /
}

# Echo absent|running|down|unknown. See SAFETY DIRECTION above for why doubt
# always resolves to unknown rather than down.
nm_daemon_verdict() {
  local out rc pid
  command -v no-mistakes >/dev/null 2>&1 || { printf '%s\n' absent; return 0; }
  # errexit is deliberately off for this whole script (set -u only), so a
  # non-zero status here is data, not a failure.
  out=$(nm_daemon_run "$NM_STATUS_TIMEOUT" daemon status)
  rc=$?

  # Signal 1 (kernel): a reported pid whose process is alive proves the daemon
  # is up regardless of how the vendor words the surrounding line.
  pid=$(printf '%s\n' "$out" \
    | sed -n 's/.*[Pp][Ii][Dd][^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' running
    return 0
  fi

  # Signal 2 (vendor text): the explicit negative claim. A pid alongside it is
  # self-contradictory, so refuse to act on it.
  case "$out" in
    *"not running"*)
      if [ -n "$pid" ]; then printf '%s\n' unknown; else printf '%s\n' down; fi
      return 0
      ;;
  esac

  # A pid we could not prove alive is not proof of death (EPERM, a race).
  if [ -n "$pid" ]; then
    printf '%s\n' unknown
    return 0
  fi

  case "$out" in
    *"daemon running"*|*"daemon is running"*)
      if [ "$rc" -eq 0 ]; then printf '%s\n' running; else printf '%s\n' unknown; fi
      return 0
      ;;
  esac

  # A status that ran out of time is real doubt about a possibly-live daemon,
  # not evidence about the surface, so it must not be silently filed as absent.
  if [ "$rc" -eq 124 ]; then
    printf '%s\n' unknown
    return 0
  fi

  # No usable signal at all. A failing command here means this build or
  # environment exposes no daemon status surface - report absent and stay quiet,
  # since the pre-existing lazy-start behavior is unchanged either way.
  if [ "$rc" -ne 0 ]; then printf '%s\n' absent; else printf '%s\n' unknown; fi
}

nm_daemon_ensure() {
  local verdict dir out rc
  # Test-suite neutralizer, the same shape as FM_GATE_REFUSE_BYPASS in
  # tests/lib.sh: firstmate's own suite drives the real fm-teardown.sh and
  # fm-bootstrap.sh dozens of times, and neither the shared daemon nor a
  # running no-mistakes GATE may be touched by that. Tests covering this
  # script unset it explicitly. `status` is read-only and stays truthful.
  [ "${FM_NOMISTAKES_DAEMON_DISABLE:-0}" = 1 ] && return 0
  verdict=$(nm_daemon_verdict)
  case "$verdict" in
    absent|running) return 0 ;;
    unknown)
      echo "warning: no-mistakes daemon state is indeterminate; starting nothing rather than risk restarting a live daemon" >&2
      return 1
      ;;
  esac
  dir=$(nm_daemon_start_dir)
  out=$( cd "$dir" && nm_daemon_run "$NM_START_TIMEOUT" daemon start )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "no-mistakes daemon was down; started it from $dir" >&2
    return 0
  fi
  echo "warning: no-mistakes daemon is down and could not be started from $dir: $out" >&2
  return 1
}

case "${1:-}" in
  ensure) [ "$#" -eq 1 ] || usage 2; nm_daemon_ensure ;;
  status) [ "$#" -eq 1 ] || usage 2; nm_daemon_verdict ;;
  -h|--help) usage 0 ;;
  *) usage 2 ;;
esac
