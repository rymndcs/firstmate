#!/usr/bin/env bash
# Submit the native omp reset command through the existing primary-pane transport.
# Usage: fm-omp-reset-submit.sh check <omp-pid>
#        fm-omp-reset-submit.sh recover-check <omp-pid>
#        fm-omp-reset-submit.sh submit <nonce> <omp-pid>
# This helper never starts a terminal or guesses a primary pane. The extension
# owns fresh readiness and native idle/queue checks; this last transport boundary
# requires the same live home lock, no global hold, normal presence and an empty
# composer. recover-check retains ownership checks without requiring reset
# permission, so an away takeover can still resume supervision.
# The literal private CSI trigger contains no Enter or draft text; the native
# synchronous input listener alone admits the registered command and Enter.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "${1:-}" in
  check|recover-check) [ "$#" -eq 2 ] || exit 2; pid=$2 ;;
  submit) [ "$#" -eq 3 ] || exit 2; nonce=$2; pid=$3 ;;
  --help|-h) sed -n '2,7{s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  *) exit 2 ;;
esac
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 1
[ "${OMPCODE:-}" = 1 ] || exit 1
case "$pid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
[ "$(cat "$STATE/.lock" 2>/dev/null)" = "$pid" ] || exit 1
kill -0 "$pid" 2>/dev/null || exit 1
[ ! -e "$STATE/.captain-hold" ] || exit 1
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
target=$(discover_supervisor_target) || exit 1
backend=$(discover_supervisor_backend) || exit 1
case "$backend" in tmux|herdr) ;; *) exit 1 ;; esac
[ "$1" != recover-check ] || exit 0
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
reset_allowed() {
  [ ! -e "$STATE/.afk" ] && ! fm_afk_omp_owner_selected "$STATE"
}
reset_allowed || exit 1
[ "$1" != check ] || exit 0
[[ "$nonce" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || exit 2
# Reuse the existing primary composer reader and literal transport.
# No daemon or away-mode presence change is needed.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$SCRIPT_DIR/fm-supervise-daemon.sh"
fm_backend_target_exists "$backend" "$target" || exit 1
[ "$(FM_COMPOSER_HARNESS=omp fm_backend_composer_state "$backend" "$target")" = empty ] || exit 1
[ ! -e "$STATE/.captain-hold" ] || exit 1
reset_allowed || exit 1
hex=${nonce//-/}
trigger=$'\033[?9001'
while [ -n "$hex" ]; do
  part=${hex:0:4}
  hex=${hex:4}
  trigger="$trigger;$((16#$part))"
done
trigger="$trigger~"
fm_backend_source "$backend" || exit 1
case "$backend" in
  tmux) fm_backend_tmux_send_literal "$target" "$trigger" ;;
  herdr) fm_backend_herdr_send_literal "$target" "$trigger" ;;
esac
