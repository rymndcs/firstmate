#!/usr/bin/env bash
# Resolve the review base: origin's default after fetching, or the local default
# for repositories without origin. --default reports only the branch name.+# Usage: fm-diff-base.sh <repo> [--default]
set -eu
REPO=${1:?usage: fm-diff-base.sh <repo> [--default]}
DEFAULT=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -n "$DEFAULT" ]; then
  DEFAULT=${DEFAULT#origin/}
else
  for branch in main master; do
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      DEFAULT=$branch
      break
    fi
  done
fi
[ -n "$DEFAULT" ] || { echo "error: cannot determine default branch for $REPO; expected origin/HEAD, main, or master" >&2; exit 1; }
if [ "${2:-}" = --default ]; then
  printf '%s\n' "$DEFAULT"
elif git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  git -C "$REPO" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  printf 'origin/%s\n' "$DEFAULT"
else
  printf '%s\n' "$DEFAULT"
fi
