#!/usr/bin/env bash
# Manage the effective firstmate home's state/.captain-hold.
# Usage: fm-captain-hold.sh set "<reason>" | clear | status
# set writes one line containing the reason and a UTC timestamp atomically.
# clear is authorized only on explicit captain dismissal; session start also
# removes the marker after acquiring the session lock. Neither consumes wakes.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARKER="$STATE/.captain-hold"
case "${1:-}" in
  set)
    [ "$#" -eq 2 ] && [ -n "$2" ] || exit 2
    reason=${2//$'\n'/ }
    reason=${reason//$'\r'/ }
    mkdir -p "$STATE"
    tmp=$(mktemp "$STATE/.captain-hold.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    printf '%s - %s\n' "$reason" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
    mv -f "$tmp" "$MARKER"
    ;;
  clear)
    [ "$#" -eq 1 ] || exit 2
    rm -f "$MARKER"
    ;;
  status)
    [ "$#" -eq 1 ] || exit 2
    if [ -e "$MARKER" ]; then cat "$MARKER"; else printf 'captain hold: inactive\n'; fi
    ;;
  -h|--help)
    printf 'Usage: fm-captain-hold.sh set "<reason>" | clear | status\n'
    ;;
  *) exit 2 ;;
esac
