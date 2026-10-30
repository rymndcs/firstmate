#!/usr/bin/env bash
# PreToolUse seatbelt: refuse git pushes that rewrite or delete remote history.
#
# REFUSED on every push:
#
#   - force: -f, --force, --force-with-lease, --force-if-includes, or a +refspec
#   - ref deletion: -d, --delete, --prune, --mirror, or a refspec with an empty source
#   - git configuration overrides before `push` (-c, --config-env, any option but -C), which can
#     change what the push does after this check has read it
#
# A push that may reach `main` or `master` also accepts only the small option allowlist below and
# no tag refs. It may reach them when it names either one as a destination, names HEAD or @, uses
# a wildcard, or names no refspec at all (which --all and --branches require), because the
# destination then depends on the checkout or configuration rather than on the command text.
#
# Push checks ignore quotes and shell syntax: a commit message or grep pattern that mentions a
# refused push is refused too. Put such text in a file instead of the command.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-push-pretool-check.sh [--claude]
#   bin/fm-push-pretool-check.sh --command '<cmd>'
#
# Exit/output contract, matching bin/fm-cd-pretool-check.sh:
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2, Claude-shaped deny object on stderr, Grok-shaped object on stdout unless
#           --claude.
#   FAIL OPEN - malformed stdin or missing jq.
set -u
# Command text is matched as bytes, regardless of the caller locale or awk implementation.
export LC_ALL=C

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

# Check every git ... push sequence as plain text, including quoted mentions.
printf '%s\n' "$CMD" | awk '
  function safe(t) { return t ~ /^(-u|--set-upstream|-q|--quiet|-v|--verbose|-n|--dry-run)$/ }
  function rewrites(t) {
    if (t ~ /^--(force|force-with-lease|force-if-includes|delete|prune|mirror)(=|$)/) return 1
    return t ~ /^-[A-Za-z]+$/ && t ~ /[fd]/
  }
  function check(    n,w,g,p,i,t,d,remote,refs,trunk,unsafe) {
    n = split(segment, w, /[[:space:]]+/)
    for (g = 1; g <= n; g++) if (w[g] == "git") {
      for (p = g + 1; p <= n; p++) if (w[p] == "push") {
        for (i = g + 1; i < p; i++) {
          t = w[i]
          if (t == "-C" && i + 1 < p) { i++; continue }
          if (t ~ /^-C./) continue
          if (t ~ /^-/) bad = 1
        }
        remote = refs = trunk = unsafe = 0
        for (i = p + 1; i <= n; i++) {
          t = w[i]
          if (t == "") continue
          if (t ~ /^-/) {
            if (rewrites(t)) bad = 1
            if (!safe(t)) unsafe = 1
            continue
          }
          if (!remote) { remote = 1; continue }
          refs++
          if (t ~ /^\+/ || t ~ /^:/) bad = 1
          if (t ~ /(^|:)refs\/tags\//) unsafe = 1
          d = t; sub(/^.*:/, "", d); sub(/^refs\/heads\//, "", d)
          if (d ~ /^(main|master|HEAD|@)$/ || t ~ /\*/) trunk = 1
        }
        if (!refs) trunk = 1
        if (trunk && unsafe) bad = 1
      }
    }
    segment = ""; depth = 0
  }
  {
    # Quotes and backslashes never protect words or separators. Redirections are not refs,
    # and a file descriptor number belongs to a redirection only at the start of a word.
    gsub(/[\047"`\\]/, "")
    gsub(/(^|[[:space:]])[0-9]+[<>]/, " >")
    gsub(/[<>]+&?[[:space:]]*[^[:space:];&|()<>]+/, " ")
    for (k = 1; k <= length($0); k++) {
      c = substr($0, k, 1)
      if (c ~ /[;&|]/ || (c == ")" && !depth)) check()
      else if (c == "(") { depth++; segment = segment " " }
      else if (c == ")") { depth--; segment = segment " " }
      else segment = segment c
    }
    check()
  }
  END { exit bad ? 1 : 0 }
' && exit 0

REASON="[push-guard] refusing: a git push may not force, delete remote refs or override git \
configuration, and a push that may reach main or master (named, HEAD, a wildcard, or no refspec) \
accepts only -u, --set-upstream, -q, -v, -n and --dry-run, with no tag refs. Quoted mentions \
count, so put prose about such a push in a file rather than in the command."

printf '%s\n' "$REASON" >&2
if [ "$CLAUDE_MODE" -eq 0 ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":%s}\n' \
    "$(printf '%s' "$REASON" | jq -Rs . 2>/dev/null || printf '"%s"' "denied")"
fi
exit 2
