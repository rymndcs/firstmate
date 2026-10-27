#!/usr/bin/env bash
# Resolve the review base: origin's default after fetching, or the local default
# for repositories without origin. Origin's default is origin/HEAD, else origin's
# advertised HEAD, else origin/main, else origin/master. A failed fetch refuses
# rather than fall back to a stale base.
# Usage: fm-diff-base.sh <repo>
set -eu
REPO=${1:?usage: fm-diff-base.sh <repo>}
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  DEFAULT=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  DEFAULT=${DEFAULT#origin/}
  if [ -z "$DEFAULT" ]; then
    DEFAULT=$(git -C "$REPO" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2 }' || true)
  fi
  if [ -z "$DEFAULT" ]; then
    for branch in main master; do
      if git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        DEFAULT=$branch
        break
      fi
    done
  fi
  [ -n "$DEFAULT" ] || { echo "error: cannot determine origin's default branch for $REPO; run 'git -C $REPO remote set-head origin <branch>' and retry" >&2; exit 1; }
  git -C "$REPO" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet 2>/dev/null \
    || { echo "error: cannot fetch origin's $DEFAULT for $REPO; origin must be reachable to submit, review or land task work, because the comparison base is the merge-base with origin's current $DEFAULT; run 'git -C $REPO fetch origin' to see why" >&2; exit 1; }
  printf 'origin/%s\n' "$DEFAULT"
  exit 0
fi
for branch in main master; do
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s\n' "$branch"
    exit 0
  fi
done
echo "error: cannot determine default branch for $REPO; expected main or master" >&2
exit 1
