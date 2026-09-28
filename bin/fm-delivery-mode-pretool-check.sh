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
#   4. bare, forced, deleting, tag, or extra-ref pushes; every named destination must be
#      `main` or `master`, including each push in a chain or a shell -c command
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

# 4. Inspect shell words without evaluating them. Quotes protect prose, but a shell -c
# argument is itself a command and must be inspected recursively. Unknown push options
# are refused rather than guessed: abbreviations and option bundles can change which
# refs Git sends. This is a literal-command seatbelt, not a shell interpreter; it cannot
# resolve aliases, variables, sourced scripts, or remote configuration.
if [ -z "$WHY" ]; then
  WHY="$(printf '%s\n' "$CMD" | awk '
    function deny(reason) { print reason; exit }
    function push(args, n, start,    i,t,remote,refs,options,dest) {
      options=1
      for (i=start; i<=n; i++) {
        t=args[i]
        if (options && t=="--") { options=0; continue }
        if (options && t ~ /^-/) {
          if (t ~ /^--(force|delete|tags|all|mirror|follow-tags)/ || t ~ /^-[^-]*[fd]/)
            deny("forcing, deleting, or sending extra refs with " t " - only explicit non-forced trunk updates are permitted")
          if (t=="--receive-pack" || t=="--exec" || t=="--repo" || t=="-o" || t=="--push-option") {
            if (++i>n) deny("pushing with an option missing its value")
            if (t=="--repo") remote=1
            continue
          }
          if (t ~ /^--(receive-pack|exec|repo|push-option)=/) {
            if (t ~ /^--repo=/) remote=1
            continue
          }
          if (t ~ /^-[quvn]+$/ || t ~ /^--(quiet|verbose|dry-run|porcelain|progress|no-progress|set-upstream|atomic|no-verify|signed|no-signed|no-follow-tags)$/ || t ~ /^--signed=/)
            continue
          deny("pushing with an unrecognised option " t " - its ref scope cannot be verified")
        }
        if (!remote) { remote=1; continue }
        if (t ~ /^\+/) deny("forcing a remote update with " t)
        if (t ~ /^:/) deny("deleting a remote ref with " t)
        if (t=="tag" || t ~ /(^|:)refs\/tags\//) deny("pushing a tag refspec " t)
        dest=t
        sub(/^[^:]*:/, "", dest)
        if (dest!="main" && dest!="master") deny("pushing " t " - only main or master may be pushed")
        refs++
      }
      if (!refs) deny("pushing without naming a branch - name main or master explicitly")
    }
    function command(args,n,depth,    i,t,j) {
      for (i=1; i<=n; i++) {
        t=args[i]
        if (t ~ /^[A-Za-z_][A-Za-z_0-9]*=/ || t ~ /^(command|exec|env|sudo|time|!|if|then|elif|else|do)$/) continue
        if (t=="git" || t ~ /\/git$/) {
          for (j=i+1; j<=n; j++) {
            t=args[j]
            if (t=="-C" || t=="-c" || t=="--git-dir" || t=="--work-tree" || t=="--namespace") { j++; continue }
            if (t ~ /^-/) continue
            if (t=="push") push(args,n,j+1)
            break
          }
        } else if (t ~ /(^|\/)(bash|sh|zsh|dash|ksh)$/) {
          for (j=i+1; j<=n; j++) {
            if (args[j] ~ /^-[^-]*c/) {
              if (depth>=16) deny("shell wrappers nested too deeply to verify push scope")
              scan(args[j+1],depth+1)
              break
            }
          }
        }
        break
      }
    }
    function scan(s,depth,    args,n,i,c,q,word,active,redirect,nextchar) {
      n=0
      for (i=1; i<=length(s)+1; i++) {
        c=substr(s,i,1)
        if (q!="") {
          if (c==q) q=""
          else if (c=="\\" && q=="\"") {
            nextchar=substr(s,i+1,1)
            if (nextchar ~ /[\\"$`]/ || nextchar=="\n") { i++; if (nextchar!="\n") word=word nextchar }
            else word=word c
          } else word=word c
          continue
        }
        if (c=="\\") { i++; c=substr(s,i,1); if (c!="\n") { word=word c; active=1 }; continue }
        if (c=="\"" || c==sprintf("%c",39)) { q=c; active=1; continue }
        if (c=="#" && !active) { while (i<=length(s) && substr(s,i,1)!="\n") i++; c="\n" }
        if (c=="" || c ~ /[[:space:];&|()<>]/) {
          if (active) {
            if (!redirect && !(c ~ /[<>]/ && word ~ /^[0-9]+$/)) args[++n]=word
            if (redirect) redirect=0
            word=""; active=0
          }
          if (c ~ /[<>]/ && c!="") {
            redirect=1
            while (substr(s,i+1,1) ~ /[<>&|]/ && i<length(s)) i++
          } else if (c=="" || c ~ /[;&|()\n]/) {
            command(args,n,depth); n=0; redirect=0
          }
        } else { word=word c; active=1 }
      }
      if (q!="") command(args,n,depth)
    }
    { input=input $0 "\n" }
    END { scan(input,0) }
  ')"
fi

[ -n "$WHY" ] || exit 0

REASON="[no-github] refusing: ${WHY}. The captain's standing instruction of 2026-08-17 is that \
firstmate reaches GitHub for one thing only - \"Skip the PR creation since I also ran out of \
github credits ... so the only time it runs on github is when we push main to github.\" Pushing \
only explicit non-forced, non-deleting main or master updates is permitted and needs no flag; \
extra refs and tags are refused, and there is no environment \
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
