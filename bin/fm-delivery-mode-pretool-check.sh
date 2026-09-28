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
#   4. pushing anything that is not `main` or `master`, and any forced push
#   5. starting or re-running a GitHub Actions workflow
#
# There is deliberately NO environment override. The captain, 2026-08-30: *"I want you to remove
# that environment variable because you will eventually turn that on then forget that its on."*
# An escape hatch that an agent may set is an escape hatch an agent will leave set, so the
# exemption is written into the rule instead of parked behind a switch. Widening this needs a
# code change, in a diff, which is the point.
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

# 4. A push carrying only `main` or `master` is the sanctioned route. Anything else - another
#    branch, a tag, a bare `push` whose refspec is implicit, or any forced push - is not.
# Only a real `git ... push` invocation, never prose that happens to contain the word - the
# guard's own source and its refusal messages both do.
if [ -z "$WHY" ] && printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+push([[:space:]]|$)'; then
  case "$CMD" in
    *)
      # Everything after `push`, stopping at the first shell operator OR redirection. Without
      # the redirection cut, `push origin main 2>&1 | tail` reads `2>` as a second refspec and
      # a perfectly good push of main is refused.
      PUSH_ARGS="$(printf '%s' "$CMD" | sed -n 's/.*[[:space:]]push[[:space:]]*//p' |
                   sed -E 's/[0-9]*[<>].*//; s/[;&|)].*//')"
      # Tokenised, not substring-matched: `-f` can be the first argument, where a pattern
      # anchored on a leading space never sees it. `+ref` is a forced refspec.
      FORCED=0
      for tok in $PUSH_ARGS; do
        case "$tok" in
          -f|--force|--force-with-lease|--force-with-lease=*|--force-if-includes|+*) FORCED=1 ;;
        esac
      done
      case "$FORCED" in
        1)
          WHY="forcing a remote update. A forced update is never firstmate's to make" ;;
        *)
          # Every ref named must be main or master. `HEAD:main` counts; a bare push names none, so the
          # branch is whatever happens to be checked out and that is not good enough.
          REFS="$(printf '%s' "$PUSH_ARGS" | tr ' ' '\n' | grep -v '^-' | grep -v '^$' |
                  tail -n +2)"
          if [ -z "$REFS" ]; then
            WHY="pushing without naming a branch - name main or master explicitly"
          else
            for ref in $REFS; do
              case "${ref##*:}" in
                main|master) : ;;
                *) WHY="pushing '${ref}' - only main or master may be pushed"; break ;;
              esac
            done
          fi
          ;;
      esac
      ;;
  esac
fi

[ -n "$WHY" ] || exit 0

REASON="[no-github] refusing: ${WHY}. The captain's standing instruction of 2026-08-17 is that \
firstmate reaches GitHub for one thing only - \"Skip the PR creation since I also ran out of \
github credits ... so the only time it runs on github is when we push main to github.\" Pushing \
main or master is permitted and needs no flag; everything else here is not, and there is no environment \
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
