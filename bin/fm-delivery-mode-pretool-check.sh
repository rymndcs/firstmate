#!/usr/bin/env bash
# PreToolUse seatbelt: firstmate may send only `main` or `master` to GitHub.
#
# The captain, 2026-08-17, standing until he says otherwise:
#
#   "Skip the PR creation since I also ran out of github credits. If possible perform the
#    checks that github actions is running locally. once that's done starting from now on
#    perform those checks locally to save on github credits. so the only time it runs on
#    github is when we push main to github."
#
# `data/projects.md` still carries `wms [no-mistakes]`, and reading that flag without reading
# the instruction that overrides it is how this went wrong on 2026-08-30: two workers were
# dispatched `--mode no-mistakes`, one opened PR 183 and spent ten GitHub Actions jobs on an
# allowance the captain had raised a budget for that same morning.
#
# The flag was not the authority and prose did not stop it, so this does.
#
# ALLOWED, permanently and with no flag to set:
#
#   - pushing `main` or `master` to a remote. That is the captain's sanctioned route and the one time
#     GitHub is meant to run anything.
#
# REFUSED, permanently and with no way to lift it from here:
#
#   1. a spawn or brief on a mode that ends in a pull request
#   2. a validation run whose skip list does not disable push AND pr AND ci
#   3. creating, merging or reverting a pull request - no exceptions, ever
#   4. pushes without explicit main/master refs, deletes, force, extra refs or unsafe options
#   5. starting or re-running a GitHub Actions workflow
#
# There is deliberately NO environment override. The captain, 2026-08-30: *"I want you to remove
# that environment variable because you will eventually turn that on then forget that its on."*
# An escape hatch that an agent may set is an escape hatch an agent will leave set, so the
# exemption is written into the rule instead of parked behind a switch. Widening this needs a
# code change, in a diff, which is the point.
# Push checks ignore quotes and shell syntax: even a commit message or grep pattern mentioning
# a refused push is refused. Put such text in a file instead of the command. Options are limited
# to the small allowlist below plus git -C <dir> or -C<dir>; configuration overrides are refused.
#
# Review rigor is NOT what is being dropped: the pipeline still runs as `--skip push,pr,ci`,
# keeping review, fixes, tests, lint and documentation. Only the remote is off limits.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-delivery-mode-pretool-check.sh [--claude]
#   bin/fm-delivery-mode-pretool-check.sh --command '<cmd>'
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

WHY=""

# 1. A dispatch on a mode that ends in a pull request. A scout writes a report and a secondmate
#    is a home; neither ships a branch, so neither is in scope.
case "$CMD" in
  *fm-spawn.sh*|*fm-brief.sh*)
    case "$CMD" in
      *--scout*|*--secondmate*) : ;;
      *)
        MODE="$(printf '%s' "$CMD" | sed -n 's/.*--mode[= ]\{1,\}\([A-Za-z-]\{1,\}\).*/\1/p' | head -1)"
        if [ -n "$MODE" ] && [ "$MODE" != "local-only" ]; then
          WHY="dispatching --mode ${MODE}, which ends in a pull request. Ship work is --mode local-only"
        fi
        ;;
    esac
    ;;
esac

# 2. A validation run that has not disabled all three remote steps. `pr,ci` alone leaves the
#    pipeline's own push step ARMED, which is why each of the three is checked by name.
# `run` as a whole word, not a prefix: `*" run"*` also matches "running", which blocked a
# read-only `axi status` whose pipeline happened to grep for the word.
if [ -z "$WHY" ] && printf '%s' "$CMD" |
     grep -qE 'no-mistakes([[:space:]]+[^[:space:]]+)*[[:space:]]+run([[:space:]]|$)'; then
  case "$CMD" in
    *)
      for step in push pr ci; do
        case "$CMD" in
          *--skip*"$step"*) : ;;
          *) WHY="starting a validation run without --skip push,pr,ci (missing '${step}')"; break ;;
        esac
      done
      ;;
  esac
fi

# 3. Pull requests, and GitHub Actions started by hand. No exemption.
if [ -z "$WHY" ]; then
  case "$CMD" in
    *"pr create"*)    WHY="creating a pull request" ;;
    *"pr merge"*)     WHY="merging a pull request" ;;
    *"pr revert"*)    WHY="reverting a pull request" ;;
    *fm-pr-merge.sh*) WHY="merging a pull request" ;;
    *"workflow run"*) WHY="starting a GitHub Actions workflow" ;;
    *"run rerun"*)    WHY="re-running a GitHub Actions workflow" ;;
  esac
fi

# 4. Check every git ... push sequence as plain text, including quoted mentions.
if [ -z "$WHY" ] && ! printf '%s\n' "$CMD" | awk '
  function safe(t) { return t ~ /^(-u|--set-upstream|-q|--quiet|-v|--verbose|-n|--dry-run)$/ }
  function check(    n,w,g,p,i,t,remote,refs) {
    n = split(segment, w, /[[:space:]]+/)
    for (g = 1; g <= n; g++) if (w[g] == "git") {
      for (p = g + 1; p <= n; p++) if (w[p] == "push") {
        for (i = g + 1; i < p; i++) {
          t = w[i]
          if (t == "-C" && i + 1 < p) { i++; continue }
          if (t ~ /^-C./) continue
          if (t ~ /^-/ && !safe(t)) bad = 1
        }
        remote = refs = 0
        for (i = p + 1; i <= n; i++) {
          t = w[i]
          if (t == "") continue
          if (t ~ /^-/) { if (!safe(t)) bad = 1; continue }
          if (!remote) { remote = 1; continue }
          refs++
          if (t ~ /^\+/ || t ~ /(^|:)refs\/tags\// ||
              t !~ /^(main|master|[^:]+:(main|master))$/) bad = 1
        }
        if (!refs) bad = 1
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
'; then
  WHY="push text must name only main or master with a non-empty source, no force, delete, tags, extra refs or configuration overrides, and only known-safe options (quoted mentions count; put prose in a file)"
fi

[ -n "$WHY" ] || exit 0

REASON="[no-github] refusing: ${WHY}. The captain's standing instruction of 2026-08-17 is that \
firstmate reaches GitHub for one thing only - \"Skip the PR creation since I also ran out of \
github credits ... so the only time it runs on github is when we push main to github.\" Pushing \
only main or master with safe options is permitted; everything else here is not, and there is no environment \
variable to lift it, deliberately. Ship work runs --mode local-only: the worker stops at a clean \
ready branch and you land it with bin/fm-merge-local.sh. Review rigor is not dropped with the \
pull request - run the validation pipeline as --skip push,pr,ci (all three; 'pr,ci' alone leaves \
the push step armed). The [no-mistakes] flag in data/projects.md does NOT override this: see \"No \
pull requests; the CI checks run locally\" in data/captain.md."

printf '%s\n' "$REASON" >&2
if [ "$CLAUDE_MODE" -eq 0 ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":%s}\n' \
    "$(printf '%s' "$REASON" | jq -Rs . 2>/dev/null || printf '"%s"' "denied")"
fi
exit 2
