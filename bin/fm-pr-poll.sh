#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It preserves the exact merged result for PR/MR retirement and publishes
# GitHub check outcomes through fm-pr-ci.sh, once per head/outcome.
# OPEN PRs also publish comments and conflicts through fm-pr-activity.sh,
# independently of CI availability; a closed PR stays silent.
# Missing, pending, malformed or failed check lookups stay silent.
# Usage: fm-pr-poll.sh [--validated <provider> <url> <host> <path> <number>]
# A PR with required checks uses only those (gh pr checks --required --json
# bucket); a PR with none uses all of its reported checks. gh reports "none" only
# as its `no required checks reported on the '<branch>' branch` error, which is
# the only signal that falls back; any other failed or empty required lookup
# stays silent. Skipped checks count as satisfied, canceled checks as failure,
# and an empty set is not all-green.
# Head identity is read before and after checks to reject a concurrent push.
# The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

if [ "${1:-}" = --help ]; then
  sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    [ "$state" = OPEN ] || exit 0
    root=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}
    "$root/bin/fm-pr-activity.sh" "$url" 2>/dev/null || true
    head=$(gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null) || exit 0
    case "$head" in ''|*[!a-fA-F0-9]*) exit 0 ;; esac
    [ "${#head}" -eq 40 ] || exit 0
    checks_rc=0
    buckets=$(gh pr checks "$url" --required --json bucket --jq '.[].bucket' 2>&1) || checks_rc=$?
    case "$checks_rc" in 0|1|8) ;; *) exit 0 ;; esac
    case "$buckets" in
      "no required checks reported on the "*)
        buckets=$(gh pr checks "$url" --json bucket --jq '.[].bucket' 2>/dev/null) || checks_rc=$?
        case "$checks_rc" in 0|1|8) ;; *) exit 0 ;; esac
        ;;
    esac
    outcome=$(printf '%s\n' "$buckets" | awk '
      $0 == "fail" || $0 == "cancel" { failed = 1; next }
      $0 == "pending" { pending = 1; next }
      $0 == "pass" || $0 == "skipping" { next }
      { invalid = 1 }
      END {
        if (invalid) exit;
        if (failed) print "ci-fail";
        else if (!pending) print "ci-pass";
      }
    ')
    [ -n "$outcome" ] || exit 0
    current_head=$(gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null) || exit 0
    [ "$head" = "$current_head" ] || exit 0
    "$root/bin/fm-pr-ci.sh" "$url" "$head" "$outcome" 2>/dev/null || true
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
