#!/usr/bin/env bash
# shellcheck disable=SC2034 # Verdict globals are consumed by teardown callers.
# Private landed-content implementation; fm-teardown.sh owns the safety contract.
default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Landed-work verdict state, reset by every work_landed_verdict call.
# LANDED_VERDICT is landed|unlanded|unknown; LANDED_UNCERTAIN is set by any check
# that could not reach an answer, and LANDED_UNCERTAIN_REASONS collects one
# operator-readable line per such check. Keeping "could not tell" separate from
# "not there" is what lets the refusal message stay honest about --force.
LANDED_VERDICT=
LANDED_UNCERTAIN=0
LANDED_UNCERTAIN_REASONS=
LANDED_REMAINING=
LANDED_PR_HEAD=
LANDED_DEFAULT_FETCHED=0
DEFAULT_REF=
LANDED_NO_BRANCH_REASON="this worktree is on no named branch (a detached HEAD), so no remote and no branch-discovered pull request could be consulted about this work"

landed_note_uncertain() {
  LANDED_UNCERTAIN=1
  if [ -z "$LANDED_UNCERTAIN_REASONS" ]; then
    LANDED_UNCERTAIN_REASONS="  $1"
    return 0
  fi
  # One line per DISTINCT failed check: the same unmatchable commit is retried
  # against every candidate ref, and repeating its line once per ref would read to
  # the operator as several different checks having failed.
  if printf '%s\n' "$LANDED_UNCERTAIN_REASONS" | grep -qxF "  $1"; then
    return 0
  fi
  LANDED_UNCERTAIN_REASONS=$(printf '%s\n  %s' "$LANDED_UNCERTAIN_REASONS" "$1")
}

# Run a git command that talks to a remote. Teardown is non-interactive, so a
# missing credential must fail immediately instead of blocking a fleet operation
# on a prompt nobody will ever answer.
git_remote_op() {
  GIT_TERMINAL_PROMPT=0 git -C "$WT" "$@"
}

# Bring every remote's copy of <branch> into its remote-tracking ref, so the
# "not on any remote" question is answered by the remote rather than by whatever
# this worktree happened to fetch last. ls-remote's exit 2 is a real answer ("that
# remote does not have this branch"); every other failure means the remote could
# not be consulted, which is uncertainty, not absence.
# A worktree with no resolvable branch (a detached HEAD, e.g. one left mid-rebase)
# gives the remotes nothing to be asked ABOUT, which is uncertainty of the same
# kind: no remote answered, so "on no remote" was never established.
refresh_remote_branch_refs() {
  local branch=$1 remote rc remotes
  if [ -z "$branch" ] || [ "$branch" = HEAD ]; then
    landed_note_uncertain "$LANDED_NO_BRANCH_REASON"
    return 0
  fi
  if ! remotes=$(git -C "$WT" remote 2>/dev/null); then
    landed_note_uncertain "this worktree's remotes could not be listed"
    return 0
  fi
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    if git_remote_op ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
      git_remote_op fetch --quiet "$remote" \
        "+refs/heads/$branch:refs/remotes/$remote/$branch" >/dev/null 2>&1 \
        || landed_note_uncertain "remote $remote has $branch but it could not be fetched for comparison"
    else
      rc=$?
      [ "$rc" -eq 2 ] \
        || landed_note_uncertain "remote $remote could not be reached to ask whether it already has this work"
    fi
  done <<EOF
$remotes
EOF
}

# Each remote's copy of <branch> that exists locally after the refresh.
remote_branch_refs() {
  local branch=$1 remote ref remotes
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 0
  remotes=$(git -C "$WT" remote 2>/dev/null) || return 0
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    ref="refs/remotes/$remote/$branch"
    if git -C "$WT" rev-parse --quiet --verify "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
    fi
  done <<EOF
$remotes
EOF
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number and
# returns 0 on a single match. Returns 2 when gh-axi answered and there is no such
# PR (a real answer), 1 when the lookup itself failed (no answer at all), and 3 when
# there is no branch to look one up by, so the caller can tell "no PR" apart from
# "could not ask" apart from "there was nothing to ask about".
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 3
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 2
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git_remote_op fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# Does <ref> already carry every commit this worktree holds that no remote-tracking
# branch reaches? Compared by patch-id, so a commit replayed under a new hash by a
# rebase or an amend still counts as the same change. A commit whose patch-id
# cannot be computed at all (a merge, or an empty commit) is uncertainty rather
# than proof of absence.
unpushed_patches_are_in_ref() {
  local ref=$1 current base ref_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$ref" 2>/dev/null) || return 1
  ref_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$ref" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$ref_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || patch_id=
    if [ -z "$patch_id" ]; then
      landed_note_uncertain "commit $commit carries no comparable patch (a merge or an empty commit), so its content could not be matched"
      return 1
    fi
    printf '%s\n' "$ref_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is this worktree's work already present in <ref>? Identity first, because that
# is the cheap common case, then content equivalence.
work_content_is_in_ref() {
  local ref=$1 current
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$ref" 2>/dev/null && return 0
  unpushed_patches_are_in_ref "$ref"
}

# Put the forge's copy of this task's PR head into LANDED_PR_HEAD, fetched locally,
# and return 0; return non-zero when there is none. MERGED and OPEN both count: an
# open PR's head lives on the forge, so it is a durable copy of the content just
# like a pushed branch. Resolves the PR from the recorded pr= URL first, then from
# the branch name. A lookup that FAILS - or that has no branch to look one up by -
# is recorded as uncertainty; a lookup that answers "no such PR", or a PR that is
# closed without merging, is a real answer and is not. A recorded pr= still resolves
# without a branch, so a detached worktree can still be PROVEN landed by its PR.
# The answer travels through a variable rather than stdout precisely so that
# uncertainty is recorded in THIS shell instead of a command substitution's subshell.
pr_head_commit() {
  local branch=$1 target view state head rc
  LANDED_PR_HEAD=
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  elif target=$(pr_number_from_branch "$branch"); then
    :
  else
    rc=$?
    case "$rc" in
      2) ;;
      3) landed_note_uncertain "$LANDED_NO_BRANCH_REASON" ;;
      *) landed_note_uncertain "the pull request lookup for $branch failed, so the forge could not be asked whether it already has this work" ;;
    esac
    return 1
  fi
  [ -n "$target" ] || return 1
  if ! view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null); then
    landed_note_uncertain "pull request $target could not be read, so the forge could not be asked whether it already has this work"
    return 1
  fi
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  if [ "$state" = "$view" ] || [ -z "$head" ]; then
    landed_note_uncertain "pull request $target answered without a usable head commit"
    return 1
  fi
  case "$state" in
    MERGED|merged|OPEN|open) ;;
    *) return 1 ;;
  esac
  if ! ensure_commit_object "$target" "$head"; then
    landed_note_uncertain "pull request $target reports head $head, which could not be fetched for comparison"
    return 1
  fi
  LANDED_PR_HEAD=$head
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". A merge CONFLICT is a real answer - the branch changes something the
# default branch changed differently, so its content is not in there - while a
# missing default ref, a failed fetch, or a merge-tree error is uncertainty.
# Put the default branch's comparison ref into DEFAULT_REF, fetching origin's copy
# first unless LANDED_DEFAULT_FETCHED=1 says this pass already refreshed it.
default_ref() {
  local name
  if ! name=$(default_branch); then
    landed_note_uncertain "the project's default branch could not be determined, so its content could not be compared"
    return 1
  fi
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    if [ "$LANDED_DEFAULT_FETCHED" != 1 ] \
      && ! git_remote_op fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1; then
      landed_note_uncertain "origin/$name could not be fetched, so the default branch could not be compared"
      return 1
    fi
    DEFAULT_REF="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    DEFAULT_REF="refs/heads/$name"
  else
    landed_note_uncertain "no copy of $name is reachable locally or on a remote, so its content could not be compared"
    return 1
  fi
}

content_in_default() {
  local name ref default_tree merged_tree rc
  default_ref || return 1
  ref=$DEFAULT_REF
  name=${ref#refs/remotes/origin/}
  name=${name#refs/heads/}
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || default_tree=
  if [ -z "$default_tree" ]; then
    landed_note_uncertain "$name has no readable tree, so its content could not be compared"
    return 1
  fi
  if merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null); then
    merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
    [ "$merged_tree" = "$default_tree" ]
    return
  else
    rc=$?
  fi
  # merge-tree exits 1 for a conflicting merge, which answers the question; any
  # other status means the comparison itself did not run.
  [ "$rc" -eq 1 ] \
    || landed_note_uncertain "the content comparison against $name could not be completed"
  return 1
}

# Decide whether this worktree's work is recoverable without this worktree, and
# say so in LANDED_VERDICT: landed (proven safe), unlanded (proven unsafe), or
# unknown (a check could not run). LANDED_REMAINING holds the commits still
# unaccounted for after the remote refresh, and LANDED_UNCERTAIN_REASONS explains
# every check that could not answer. The proofs and their order are described in
# the script header. Always returns 0; the verdict is the result.
work_landed_verdict() {
  local branch=$1 ref remaining
  LANDED_VERDICT=
  LANDED_UNCERTAIN=0
  LANDED_UNCERTAIN_REASONS=
  LANDED_REMAINING=

  if [ "${2:-}" = default-only ]; then
    if content_in_default; then
      LANDED_VERDICT=landed
    elif [ "$LANDED_UNCERTAIN" -eq 0 ]; then
      LANDED_VERDICT=unlanded
    else
      LANDED_VERDICT=unknown
    fi
    return 0
  fi

  refresh_remote_branch_refs "$branch"

  if remaining=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    # The refresh alone settles the commonest false refusal: a worktree that
    # simply never fetched its own pushed branch.
    if [ -z "$remaining" ]; then
      LANDED_VERDICT=landed
      return 0
    fi
    LANDED_REMAINING=$(printf '%s\n' "$remaining" | head -5)
  else
    landed_note_uncertain "this worktree's commits could not be listed against its remote-tracking branches"
  fi

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if work_content_is_in_ref "$ref"; then
      LANDED_VERDICT=landed
      return 0
    fi
  done <<EOF
$(remote_branch_refs "$branch")
EOF

  if pr_head_commit "$branch" && [ -n "$LANDED_PR_HEAD" ] \
    && work_content_is_in_ref "$LANDED_PR_HEAD"; then
    LANDED_VERDICT=landed
    return 0
  fi

  if content_in_default; then
    LANDED_VERDICT=landed
    return 0
  fi

  if [ "$LANDED_UNCERTAIN" -eq 0 ]; then
    LANDED_VERDICT=unlanded
  else
    LANDED_VERDICT=unknown
  fi
  return 0
}
