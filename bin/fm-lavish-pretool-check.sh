#!/usr/bin/env bash
# PreToolUse seatbelt: a Lavish artifact must be built by the mockup kit.
#
# `data/lavish/mockup.py` owns the review shell so every mockup wears the same
# one and only the app specimen inside it changes (data/captain.md, "Lavish
# artifacts follow the sectioned-document pattern by default"). That standard
# survived only as prose, and prose is re-read only by an agent that remembers
# to - which is exactly how a hand-authored artifact reached the captain twice.
#
# This denies opening or publishing an artifact that `mockup.build` did not
# produce. The kit stamps `<!-- fm-lavish-kit -->` into every document it
# returns; a file without it was authored some other way. The check is on the
# OPEN, not on the write: a scratch file is fine, showing one to the captain is
# not.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-lavish-pretool-check.sh [--claude]
#   bin/fm-lavish-pretool-check.sh --command '<cmd>'
#
# Exit/output contract, matching bin/fm-cd-pretool-check.sh:
#   ALLOW - exit 0, no output. Any command that is not a lavish-axi open, and
#           every subcommand that does not put an artifact in front of the
#           captain (poll, end, stop, export, playbook, design, share).
#   DENY  - exit 2, Claude-shaped deny object on stderr, Grok-shaped object on
#           stdout unless --claude.
#   FAIL OPEN - malformed stdin, missing jq, or an unreadable target. A guard
#           that cannot read the file says so by standing aside; it never
#           blocks work on its own uncertainty.
set -u

STAMP="fm-lavish-kit"
CMD=""
CMD_SET=0
CLAUDE_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --claude) CLAUDE_MODE=1 ;;
    --command) shift; [ $# -gt 0 ] || exit 0; CMD="$1"; CMD_SET=1 ;;
    *) : ;;
  esac
  shift
done

if [ "$CMD_SET" -eq 0 ]; then
  command -v jq >/dev/null 2>&1 || exit 0
  PAYLOAD="$(cat 2>/dev/null || true)"
  [ -n "$PAYLOAD" ] || exit 0
  CMD="$(printf '%s' "$PAYLOAD" |
    jq -r '(.tool_input.command // .toolInput.command // "")' 2>/dev/null || true)"
fi

[ -n "$CMD" ] || exit 0
case "$CMD" in *lavish-axi*) : ;; *) exit 0 ;; esac

# Only the subcommands that put an artifact in front of the captain. `poll`,
# `end`, `stop`, `export`, `share`, `playbook` and `design` either act on a
# session that already passed this gate or draw nothing.
TARGET="$(printf '%s' "$CMD" | awk '
  { for (i = 1; i <= NF; i++) if ($i ~ /lavish-axi$/) { start = i + 1; break } }
  start {
    for (i = start; i <= NF; i++) {
      if ($i ~ /^(poll|end|stop|export|share|playbook|design|--.*)$/) next
      if ($i ~ /\.(html|md)$/) { print $i; exit }
    }
  }')"

[ -n "$TARGET" ] || exit 0
case "$CMD" in
  *" poll "*|*" end "*|*" stop"*|*" export "*|*" share "*) exit 0 ;;
esac

TARGET="${TARGET%\"}"; TARGET="${TARGET#\"}"
TARGET="${TARGET%\'}"; TARGET="${TARGET#\'}"
[ -r "$TARGET" ] || exit 0
grep -qF "$STAMP" "$TARGET" 2>/dev/null && exit 0

REASON="[lavish-kit] $TARGET was not built by the mockup kit, so it does not carry the review \
shell every mockup shares. Build it with data/lavish/mockup.py - read data/lavish/README.md and \
copy data/lavish/examples/daily-sales-report.py - then open it again. Only the app specimen \
inside the shell changes between mockups; the shell itself is never re-authored. Set \
FM_ALLOW_LAVISH_UNSTAMPED=1 for a deliberate exception."

if [ "${FM_ALLOW_LAVISH_UNSTAMPED:-0}" = "1" ]; then exit 0; fi

printf '%s\n' "$REASON" >&2
if [ "$CLAUDE_MODE" -eq 0 ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":%s}\n' \
    "$(printf '%s' "$REASON" | jq -Rs . 2>/dev/null || printf '"%s"' "denied")"
fi
exit 2
