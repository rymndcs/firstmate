#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means some durable copy already
# holds this CONTENT: a remote's copy of the branch (asked of the remote itself, not
# of stale local remote-tracking refs), the task's pull request head on the forge
# whether merged or open, or the up-to-date default branch. Content, never commit
# identity - rebasing, amending, and squash-merging all change hashes without
# changing what would be lost. bin/fm-teardown.sh's header owns the full contract.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (q1) supplied branch name + merged PR discoverable only by that name -> ALLOW
#   (q2) supplied branch name + genuinely unlanded work                  -> REFUSE
#
# The false-refusal shapes reproduced on 2026-08-07, plus the true positive from the
# same day that proves the fix did not simply loosen the check:
#   (a1) branch pushed to origin, remote-tracking ref never fetched -> ALLOW
#   (a2) branch republished by a rebase under new hashes           -> ALLOW
#   (a3) work contained in an OPEN pull request head               -> ALLOW
#   (a4) one local commit differing from what landed by a line break -> REFUSE
# And the remedy the refusal prints, which is itself a safety surface:
#   (a5) proven-unlanded refusal    -> names --force behind the captain's explicit OK
#   (a6) undecidable refusal        -> reports what could not be checked, never --force
#   (a7) detached HEAD, no pr=, content not in default -> undecidable, never --force
#        (no branch means no remote and no branch-discovered PR was ever asked)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
# And, separately from the lock path, a return that reports failure with no error
# text at all - which in production had actually succeeded:
#   (y1) diagnostic-free return failure -> re-run once, teardown completes
#   (y2) return failure with a real diagnostic -> abort at once, no re-run
#   (y3) return failure whose diagnostic is on the NEXT line -> abort at once, no re-run
#
# And the durability of the wedge context stuck-crewmate-recovery captures before it
# terminates a crewmate:
#   (z) data/<id>/recovery-context.md across a completed teardown -> survives
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_PARENT=$(fm_test_tmproot fm-teardown-tests)
TMP_ROOT="$TMP_PARENT/cases"
mkdir -p "$TMP_ROOT"
EXTERNAL_PARENT=$(mktemp -d /var/tmp/fm-cleanup-external.XXXXXX)
remove_test_roots() {
  if [ -f "$TMP_ROOT/writer-pids" ]; then xargs kill -KILL < "$TMP_ROOT/writer-pids" 2>/dev/null || true; fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null
  rm -rf "${TMP_PARENT:?}"/cases
  rmdir "${TMP_PARENT:?}"
  rm -rf "${EXTERNAL_PARENT:?}"/symlinks "${EXTERNAL_PARENT:?}"/external-links
  rmdir "${EXTERNAL_PARENT:?}"
}
trap 'remove_test_roots; fm_test_cleanup' EXIT
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {  # <name> [<task-branch>]
  local name=$1 task_branch=${2:-fm/task-x1} case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" config --local commit.gpgsign false
  git -C "$case_dir/origin.git" config --local tag.gpgsign false
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" config --local commit.gpgsign false
  git -C "$case_dir/_seed" config --local tag.gpgsign false
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" config --local commit.gpgsign false
  git -C "$case_dir/project" config --local tag.gpgsign false
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate
  # commits. Defaults to the fm/<task-id> shape; a caller passes a tracker-supplied
  # name to prove the landed-work test never depends on that shape.
  git -C "$case_dir/project" worktree add -q -b "$task_branch" "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/fork.git" config --local commit.gpgsign false
  git -C "$case_dir/fork.git" config --local tag.gpgsign false
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" config --local commit.gpgsign false
  git -C "$tmp" config --local tag.gpgsign false
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Like add_gh_pr_merged_for_head, but the PR is still OPEN. The forge holds an open
# PR's head just as durably as a merged one, so it is an equally good answer to
# "does a copy of this content survive without the worktree?".
add_gh_pr_open_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,open" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: open" ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'OPEN' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# `treehouse return` fails its FIRST attempt with the diagnostic-free signature seen
# in production - a named git command followed by an empty error - and succeeds on
# the next one. Counts attempts in $TREEHOUSE_ATTEMPT_FILE.
add_diagnostic_free_failure_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  n=$(( $(cat "$TREEHOUSE_ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$TREEHOUSE_ATTEMPT_FILE"
  if [ "$n" = 1 ]; then
    echo "failed to return worktree: git checkout --detach --force refs/remotes/origin/main:" >&2
    exit 1
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# `treehouse return` fails with a real diagnostic every time. Counts attempts in
# $TREEHOUSE_ATTEMPT_FILE so the test can prove teardown did not retry.
add_diagnosed_failure_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  n=$(( $(cat "$TREEHOUSE_ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$TREEHOUSE_ATTEMPT_FILE"
  echo "failed to return worktree: git checkout --detach --force refs/remotes/origin/main: fatal: not a valid object name" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Like add_diagnosed_failure_treehouse, but the diagnostic arrives on the line AFTER
# the failed command - the same words, wrapped differently. It is still a real
# diagnostic, so it must not be mistaken for the diagnostic-free shape.
add_next_line_diagnosed_failure_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  n=$(( $(cat "$TREEHOUSE_ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$TREEHOUSE_ATTEMPT_FILE"
  echo "failed to return worktree: git checkout --detach --force refs/remotes/origin/main:" >&2
  echo "fatal: not a valid object name" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Like add_gh_pr_merged_for_head, but the PR is only discoverable when the branch
# name actually asked for is <branch>. Any other --head value answers "no PR", so a
# consumer that derived the branch from the task id instead of reading the real one
# gets nothing back.
add_gh_pr_merged_for_branch() {
  local case_dir=$1 branch=$2 head=$3
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list")
    for a in "\$@"; do
      if [ "\$a" = '$branch' ]; then
        printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged"
        exit 0
      fi
    done
    printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"
    exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *" 7 "*)
        case " \$* " in
          *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
          *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
        esac
        ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" config --local commit.gpgsign false
  git -C "$tmp" config --local tag.gpgsign false
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

add_gate_store() {
  local case_dir=$1 gate_repo
  gate_repo="$case_dir/.no-mistakes/repos/gate.git"
  mkdir -p "$(dirname "$gate_repo")"
  git clone -q --bare "$case_dir/origin.git" "$gate_repo"
  git -C "$gate_repo" config --local commit.gpgsign false
  git -C "$gate_repo" config --local tag.gpgsign false
  git -C "$case_dir/project" remote add no-mistakes "$gate_repo"
  printf '%s\n' "$gate_repo"
}

test_landed_task_clears_only_its_gate_backups() {
  local case_dir gate_repo head ref rc
  case_dir=$(make_case gate-backup-cleanup)
  write_meta "$case_dir" no-mistakes ship
  gate_repo=$(add_gate_store "$case_dir")
  head=$(git -C "$gate_repo" rev-parse HEAD)
  for ref in \
    refs/backup/task-x1-pipeline-head \
    refs/backup/task-x1-pre-rebase-gate-head \
    refs/backup/task-x1-gate-head-123456 \
    refs/backup/task-x10-pipeline-head \
    refs/backup/task-x10-pre-rebase-gate-head \
    refs/backup/task-x10-gate-head-123456 \
    refs/backup/rac187-pushed-head; do
    git -C "$gate_repo" update-ref "$ref" "$head"
  done
  git -C "$case_dir/project" update-ref refs/backup/task-x1-pipeline-head "$head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gate-backup-cleanup: teardown should succeed"
  for ref in \
    refs/backup/task-x1-pipeline-head \
    refs/backup/task-x1-pre-rebase-gate-head \
    refs/backup/task-x1-gate-head-123456; do
    ! git -C "$gate_repo" show-ref --verify --quiet "$ref" \
      || fail "gate-backup-cleanup: task backup survived in gate store: $ref"
  done
  for ref in \
    refs/backup/task-x10-pipeline-head \
    refs/backup/task-x10-pre-rebase-gate-head \
    refs/backup/task-x10-gate-head-123456 \
    refs/backup/rac187-pushed-head; do
    git -C "$gate_repo" show-ref --verify --quiet "$ref" \
      || fail "gate-backup-cleanup: unrelated backup was removed: $ref"
  done
  git -C "$case_dir/project" show-ref --verify --quiet refs/backup/task-x1-pipeline-head \
    || fail "gate-backup-cleanup: project clone backup was removed"
  pass "landed task removes only its attributable gate-store backup refs"
}

test_missing_gate_store_does_not_block_teardown() {
  local case_dir rc
  case_dir=$(make_case missing-gate-store)
  write_meta "$case_dir" no-mistakes ship
  git -C "$case_dir/project" remote add no-mistakes "$case_dir/.no-mistakes/repos/missing.git"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-gate-store: teardown should succeed"
  assert_grep 'gate store missing or unreadable' "$case_dir/stderr" \
    "missing-gate-store: missing store was not reported"
  [ ! -e "$case_dir/state/task-x1.meta" ] \
    || fail "missing-gate-store: teardown did not remove task metadata"
  pass "missing gate store is reported without interrupting teardown"
}

# --- shared no-mistakes daemon recovery after a treehouse return -------------
#
# `treehouse return` terminates the returned worktree's lingering processes, so a
# shared daemon a crewmate started lazily from inside that worktree dies with it
# and every OTHER lane's in-flight validation run fails with "daemon shutting
# down". Teardown re-checks the daemon the moment a return succeeds. The verdict
# and start-directory contract itself is pinned in
# tests/fm-nomistakes-daemon.test.sh; these cases pin the wiring plus the
# absolute rule that a daemon problem can never fail a teardown.
#
# lib.sh neutralizes the ensure path suite-wide so the other cases here never
# reach the machine's real shared daemon; these four re-enable it against a
# `no-mistakes` PATH stub.

# Install a `no-mistakes` stub that logs "<argv>|<cwd>" and answers `daemon
# status` from the environment. Args: case_dir
add_no_mistakes_daemon_stub() {
  local case_dir=$1
  cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "$(pwd -P)" >> "$NM_LOG"
case "${1:-} ${2:-}" in
  "daemon status")
    [ -z "${NM_STATUS_TEXT:-}" ] || printf '%s\n' "$NM_STATUS_TEXT"
    exit 0
    ;;
  "daemon start") exit "${NM_START_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
  : > "$case_dir/nm.log"
}

# Run teardown with the daemon ensure path live. Args: case_dir [extra args...]
run_teardown_with_live_daemon_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_NOMISTAKES_DAEMON_DISABLE=0 \
  NM_LOG="$case_dir/nm.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

nm_start_calls() {
  grep -c '^daemon start|' "$1/nm.log" 2>/dev/null || true
}

test_shared_daemon_restored_after_a_successful_return() {
  local case_dir rc
  case_dir=$(make_case daemon-restored-after-return)
  write_meta "$case_dir" no-mistakes ship
  add_no_mistakes_daemon_stub "$case_dir"
  export NM_STATUS_TEXT="  ○ daemon not running"

  set +e
  run_teardown_with_live_daemon_check "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset NM_STATUS_TEXT

  expect_code 0 "$rc" "daemon-restored-after-return: teardown should succeed"
  [ "$(nm_start_calls "$case_dir")" = 1 ] \
    || fail "daemon-restored-after-return: expected exactly one daemon start, got $(nm_start_calls "$case_dir")"
  pass "teardown restores a shared daemon the worktree return swept away"
}

test_shared_daemon_left_untouched_when_healthy() {
  local case_dir rc pid
  case_dir=$(make_case daemon-healthy-untouched)
  write_meta "$case_dir" no-mistakes ship
  add_no_mistakes_daemon_stub "$case_dir"
  # A real live process, so the verdict's kernel signal is exercised rather than
  # assumed. Backgrounded with its own redirects so it never holds a pipe open.
  sleep 120 >/dev/null 2>&1 &
  pid=$!
  export NM_STATUS_TEXT="  ● daemon running (pid $pid)"

  set +e
  run_teardown_with_live_daemon_check "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset NM_STATUS_TEXT
  kill "$pid" 2>/dev/null

  expect_code 0 "$rc" "daemon-healthy-untouched: teardown should succeed"
  [ "$(nm_start_calls "$case_dir")" = 0 ] \
    || fail "daemon-healthy-untouched: teardown restarted an already-healthy shared daemon"
  assert_no_grep "no-mistakes daemon" "$case_dir/stderr" \
    "daemon-healthy-untouched: teardown was not silent about a healthy daemon"
  pass "teardown leaves a healthy shared daemon completely alone (idempotent)"
}

test_shared_daemon_absent_is_a_clean_no_op() {
  local case_dir rc
  case_dir=$(make_case daemon-absent-noop)
  write_meta "$case_dir" no-mistakes ship
  add_no_mistakes_daemon_stub "$case_dir"
  rm -f "$case_dir/fakebin/no-mistakes"

  set +e
  # PATH is deliberately reduced to the case's fakebin plus the standard system
  # dirs, so a no-mistakes installed on the developer's PATH cannot leak in and
  # make "not installed" untestable. git is re-exposed explicitly.
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_NOMISTAKES_DAEMON_DISABLE=0 \
  NM_LOG="$case_dir/nm.log" \
  PATH="$case_dir/fakebin:$(dirname "$REAL_GIT_FOR_TEST"):/usr/bin:/bin:/usr/sbin:/sbin" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "daemon-absent-noop: teardown should succeed without no-mistakes installed"
  assert_no_grep "no-mistakes daemon" "$case_dir/stderr" \
    "daemon-absent-noop: teardown complained about a daemon that is not installed"
  pass "a home without no-mistakes installed tears down exactly as before"
}

test_shared_daemon_failure_never_fails_teardown() {
  local case_dir rc
  case_dir=$(make_case daemon-failure-nonfatal)
  write_meta "$case_dir" no-mistakes ship
  add_no_mistakes_daemon_stub "$case_dir"
  export NM_STATUS_TEXT="  ○ daemon not running" NM_START_RC=1

  set +e
  run_teardown_with_live_daemon_check "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset NM_STATUS_TEXT NM_START_RC

  expect_code 0 "$rc" "daemon-failure-nonfatal: a daemon problem must never fail teardown"
  assert_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "daemon-failure-nonfatal: teardown did not run to completion"
  assert_grep "could not be started" "$case_dir/stderr" \
    "daemon-failure-nonfatal: the daemon failure was not reported"
  pass "a shared daemon that cannot be restarted is reported without failing teardown"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

# Teardown decides whether work has LANDED, and treehouse return hard-resets the
# worktree, so a false "unlanded" is the costly answer here and a false "landed" is
# the dangerous one. Both directions must hold for a branch carrying a tracker's own
# published name rather than the fm/<task-id> shape.
#
# Landed direction: the branch's own commits are on no remote (squash-merged, head
# branch deleted) and its content is NOT in the default branch, so the merged PR -
# discoverable only by asking GitHub for THIS branch's name - is the sole signal
# that the work landed. A consumer deriving fm/<task-id> would ask about a branch
# that never existed, find no PR, and refuse work that is already merged.
test_supplied_branch_name_merged_pr_is_recognized_as_landed() {
  local case_dir rc linear pr_head
  linear="rcs/rac-105-purchase_order_params-permits-status-bypassing-the-state"
  case_dir=$(make_case linear-branch-landed "$linear")
  write_meta "$case_dir" no-mistakes ship
  printf 'branch=%s\n' "$linear" >> "$case_dir/state/task-x1.meta"
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_branch "$case_dir" "$linear" "$pr_head"

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "linear-branch-landed: test setup bug, meta unexpectedly records a PR"
  git -C "$case_dir/wt" rev-parse --verify --quiet refs/heads/fm/task-x1 >/dev/null \
    && fail "linear-branch-landed: test setup bug, the fm/<task-id> branch exists"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "linear-branch-landed: landed work on a supplied branch name was not torn down"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "linear-branch-landed: teardown reported a merged supplied-name branch as unlanded"
  pass "teardown recognizes a merged PR on a branch that is not fm/<task-id> as landed"
}

# Safety direction for the same shape: with no merged PR and nothing in the default
# branch, a supplied-name branch's work is genuinely unlanded and teardown must
# still refuse, so the shape change cannot have weakened the guard into a pass.
test_supplied_branch_name_unlanded_work_still_refuses() {
  local case_dir rc linear
  linear="rcs/rac-105-purchase_order_params-permits-status-bypassing-the-state"
  case_dir=$(make_case linear-branch-unlanded "$linear")
  write_meta "$case_dir" no-mistakes ship
  printf 'branch=%s\n' "$linear" >> "$case_dir/state/task-x1.meta"
  wt_commit_file "$case_dir" feature.txt hello "add feature"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "linear-branch-unlanded: teardown discarded genuinely unlanded work"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "linear-branch-unlanded: teardown did not refuse loudly"
  assert_present "$case_dir/wt" "linear-branch-unlanded: refused teardown removed the worktree"
  pass "teardown still refuses unlanded work on a branch that is not fm/<task-id>"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_unfetched_pushed_branch_is_landed() {
  local case_dir rc
  case_dir=$(make_case unfetched-remote-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  # The branch IS on origin. Dropping the remote-tracking ref reproduces a worktree
  # that never fetched its own branch, which is the only state the old check could
  # see - so it reported pushed work as "not on any remote". No PR exists (default
  # gh mock), so only asking the remote itself can answer this.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" update-ref -d refs/remotes/origin/fm/task-x1

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unfetched-remote-ref: teardown should succeed for work the remote already has"
  ! grep -q REFUSED "$case_dir/stderr" || fail "unfetched-remote-ref: teardown printed a REFUSED line"
  pass "work pushed to a remote this worktree never fetched is recognized as landed"
}

test_rebased_branch_republished_under_new_hashes_is_landed() {
  local case_dir rc
  case_dir=$(make_case rebased-new-hashes)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  # origin's copy of the SAME branch carries the same change under a different
  # commit, exactly as a rebase-and-force-push leaves it. Nothing about commit
  # identity matches, and there is no PR (default gh mock): only content can answer.
  land_equivalent_patch_on_origin_branch "$case_dir" fm/task-x1 feature.txt hello \
    "add feature (replayed by rebase)" >/dev/null

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "rebased-new-hashes: teardown should succeed when the remote branch carries the same patch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "rebased-new-hashes: teardown printed a REFUSED line"
  pass "a rebased branch republished under new hashes is recognized as landed"
}

test_open_pr_head_containing_the_work_is_landed() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case open-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "pipeline follow-up")
  # The branch is not on any remote-tracking ref, and the PR has not merged yet. The
  # forge still holds this content on the PR head, so the worktree is redundant.
  add_gh_pr_open_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "open-pr-head: teardown should succeed when an open PR head already holds the work"
  ! grep -q REFUSED "$case_dir/stderr" || fail "open-pr-head: teardown printed a REFUSED line"
  pass "work contained in an open pull request head is recognized as landed"
}

test_one_line_difference_from_landed_content_still_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case one-line-difference)
  write_meta "$case_dir" no-mistakes ship
  # The true positive from 2026-08-07 that the fix must not swallow: the PR landed,
  # its content is in main, and ONE local commit still differs from it - here by a
  # single trailing line break. Nothing durable holds that commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  land_on_origin_main "$case_dir" feature.txt hello
  # Written inline rather than through wt_commit_file: the whole point of this case
  # is that the local file differs from what landed by exactly one line break.
  printf 'hello\n\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add -- feature.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "reformat: trailing blank line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "one-line-difference: teardown must still refuse work that differs from what landed"
  assert_grep "unlanded commits" "$case_dir/stderr" \
    "one-line-difference: refusal did not name the unlanded commits"
  assert_not_contains "$(cat "$case_dir/stderr")" "cannot establish" \
    "one-line-difference: teardown reported uncertainty for a case it can decide"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "one-line-difference: teardown erased task records despite refusing"
  pass "work that differs from what landed by a single line is still refused (true positive kept)"
}

test_proven_unlanded_refusal_names_force_as_the_captain_s_call() {
  local case_dir rc
  case_dir=$(make_case unlanded-remedy)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unlanded-remedy: teardown should refuse genuinely unlanded work"
  assert_grep "unlanded commits" "$case_dir/stderr" \
    "unlanded-remedy: refusal did not name the unlanded commits"
  assert_grep "--force" "$case_dir/stderr" \
    "unlanded-remedy: a proven-unlanded refusal should still name the captain-authorized discard"
  assert_grep "captain's explicit OK" "$case_dir/stderr" \
    "unlanded-remedy: refusal offered --force without naming who must authorize it"
  pass "a proven-unlanded refusal names --force only behind the captain's explicit OK"
}

test_undecidable_landing_refuses_without_offering_force() {
  local case_dir rc
  case_dir=$(make_case undecidable-remedy)
  write_meta "$case_dir" no-mistakes ship
  append_pr_meta_url "$case_dir"
  # The content is nowhere teardown can see, but the forge cannot be reached, so
  # "not landed" is not something teardown actually knows.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "undecidable-remedy: teardown should refuse when it cannot decide"
  assert_grep "cannot establish" "$case_dir/stderr" \
    "undecidable-remedy: refusal did not say the landing could not be established"
  assert_grep "what could not be checked" "$case_dir/stderr" \
    "undecidable-remedy: refusal did not report which check failed"
  assert_no_grep "--force" "$case_dir/stderr" \
    "undecidable-remedy: teardown suggested discarding work it cannot tell apart from safe work"
  pass "an undecidable landing refuses and never suggests --force"
}

test_every_failed_check_is_reported_on_its_own_line() {
  local case_dir rc reasons
  case_dir=$(make_case undecidable-multi-reason)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  # Nothing teardown would consult is reachable: the remote is gone and the forge
  # errors. Every one of those failures has to reach the operator, each readable on
  # its own line, because together they are the reason the verdict is withheld.
  git -C "$case_dir/project" remote set-url origin "$case_dir/no-such-remote.git"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "undecidable-multi-reason: teardown should refuse when nothing can be consulted"
  assert_grep "cannot establish" "$case_dir/stderr" \
    "undecidable-multi-reason: refusal did not say the landing could not be established"
  reasons=$(sed -n '/what could not be checked:/,$p' "$case_dir/stderr" | grep -c '^  [a-z]')
  [ "$reasons" -ge 2 ] \
    || fail "undecidable-multi-reason: expected each failed check on its own line, got $reasons"
  assert_no_grep "--force" "$case_dir/stderr" \
    "undecidable-multi-reason: teardown suggested a discard it cannot justify"
  pass "every check that could not answer is reported on its own line"
}

test_detached_head_refuses_without_offering_force() {
  local case_dir rc
  case_dir=$(make_case detached-head-remedy)
  write_meta "$case_dir" no-mistakes ship
  # A crewmate worktree left detached mid-rebase: HEAD is on no named branch, so no
  # remote and no branch-discovered PR can be asked about this work at all. With no
  # pr= recorded either, the default-branch comparison is the ONLY check that ran,
  # and it cannot by itself prove the work would not be destroyed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/wt" checkout -q --detach HEAD

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "detached-head-remedy: teardown should refuse work it never managed to check"
  assert_grep "cannot establish" "$case_dir/stderr" \
    "detached-head-remedy: refusal claimed a verdict it never reached"
  assert_grep "detached HEAD" "$case_dir/stderr" \
    "detached-head-remedy: refusal did not name the check that could not run"
  assert_no_grep "--force" "$case_dir/stderr" \
    "detached-head-remedy: teardown suggested discarding work whose remotes were never consulted"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "detached-head-remedy: teardown erased task records despite refusing"
  pass "a detached worktree whose checks could not run refuses without suggesting --force"
}

test_diagnostic_free_return_failure_is_rerun_and_completes() {
  local case_dir rc attempt_file
  case_dir=$(make_case return-empty-diagnostic)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_diagnostic_free_failure_treehouse "$case_dir"
  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "return-empty-diagnostic: teardown should finish rather than abort on an unevidenced failure"
  assert_grep "no error text" "$case_dir/stderr" \
    "return-empty-diagnostic: teardown did not report why it re-ran the return"
  assert_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "return-empty-diagnostic: teardown did not run to completion"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "return-empty-diagnostic: expected exactly 2 return attempts, got $(cat "$attempt_file")"
  pass "a return that reports failure with no diagnostic is re-run instead of stranding the worktree"
}

test_diagnosed_return_failure_still_aborts_without_retrying() {
  local case_dir rc attempt_file
  case_dir=$(make_case return-real-diagnostic)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_diagnosed_failure_treehouse "$case_dir"
  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "return-real-diagnostic: a genuine return failure must still abort"
  assert_grep "teardown aborted" "$case_dir/stderr" \
    "return-real-diagnostic: teardown did not abort loudly"
  [ "$(cat "$attempt_file")" = 1 ] \
    || fail "return-real-diagnostic: expected exactly 1 return attempt, got $(cat "$attempt_file")"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "return-real-diagnostic: teardown erased task records despite aborting"
  pass "a return failure that carries a real diagnostic still aborts immediately"
}

test_return_failure_diagnosed_on_the_next_line_still_aborts_without_retrying() {
  local case_dir rc attempt_file
  case_dir=$(make_case return-wrapped-diagnostic)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  # The diagnostic is on the line after the failed command. Judged line by line that
  # command line looks diagnostic-free and would earn a destructive re-run; the
  # boundary is that ANY real diagnostic aborts at once.
  add_next_line_diagnosed_failure_treehouse "$case_dir"
  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "return-wrapped-diagnostic: a genuine return failure must still abort"
  assert_grep "teardown aborted" "$case_dir/stderr" \
    "return-wrapped-diagnostic: teardown did not abort loudly"
  [ "$(cat "$attempt_file")" = 1 ] \
    || fail "return-wrapped-diagnostic: expected exactly 1 return attempt, got $(cat "$attempt_file")"
  pass "a return failure whose diagnostic lands on the next line still aborts without a re-run"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  assert_no_grep "--force" "$case_dir/stderr" \
    "gh-error: teardown suggested a discard for a landing it could not determine"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" config --local commit.gpgsign false
  git -C "$case_dir/wt" config --local tag.gpgsign false
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      ;;
  esac
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

configure_secondmate_with_herdr_child() {  # <case-dir> [projected]
  local case_dir=$1 projected=${2:-} home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  if [ "$projected" = projected ]; then
    printf '%s\n' \
      'herdr_worktree_tab_id=wC:t9' \
      'herdr_worktree_pane_id=wC:p9' >> "$home/state/child-herdr.meta"
  fi
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wF","active_tab_id":"wF:t1","label":"captain","focused":true},{"workspace_id":"wC","active_tab_id":"wC:t1","label":"child","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wF"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wF:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane get")
    if grep -qxF "\${3:-}" "\${FM_FAKE_HERDR_CLOSED:?}" 2>/dev/null; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ] \
         || [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN_PANE:-}" = "\${3:-}" ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    elif [ "\${3:-}" = wC:p9 ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p9","tab_id":"wC:t9","workspace_id":"wC"}}}'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") printf '%s\n' "\${3:-}" >> "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

test_forced_secondmate_projected_child_retains_records_when_worktree_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-worktree-unconfirmed)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir" projected
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_PRESENCE_UNKNOWN_PANE=wC:p9 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-child-worktree-unconfirmed: forced cleanup erased a projected child whose worktree pane is still live"
  [ -n "$(herdr_log_close_index "$log" wC:p9)" ] \
    || fail "herdr-child-worktree-unconfirmed: the regression did not exercise an attempted child worktree-pane close"
  [ -e "$home/state/child-herdr.meta" ] \
    || fail "herdr-child-worktree-unconfirmed: an unconfirmed worktree close erased the only record of the worktree pane"
  [ -e "$home/state/child-herdr.status" ] \
    || fail "herdr-child-worktree-unconfirmed: an unconfirmed worktree close erased the child status record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-child-worktree-unconfirmed: the failed child cleanup erased the parent record"
  [ -d "$home" ] \
    || fail "herdr-child-worktree-unconfirmed: the failed child cleanup removed the secondmate home"
  [ -z "$(herdr_log_close_index "$log" wC:p1)" ] \
    || fail "herdr-child-worktree-unconfirmed: the refusal destroyed the child's task pane before checking the worktree tab, leaving it half torn down"
  assert_grep "worktree tab pane wC:p9 for child child-herdr is not confirmed gone" "$case_dir/stderr" \
    "herdr-child-worktree-unconfirmed: the refusal did not name the child's unconfirmed worktree pane"
  pass "forced secondmate teardown leaves a projected child's task pane and records intact until its worktree pane is confirmed gone"
}

test_forced_secondmate_projected_child_closes_worktree_pane_before_task_pane() {
  local case_dir home log closed thlog wt_at task_at
  case_dir=$(make_case herdr-child-worktree-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir" projected
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-child-worktree-close: forced cleanup failed for a fully confirmed projected child"
  wt_at=$(herdr_log_close_index "$log" wC:p9)
  task_at=$(herdr_log_close_index "$log" wC:p1)
  [ -n "$wt_at" ] \
    || fail "herdr-child-worktree-close: forced cleanup erased the child meta without closing its worktree pane"
  [ -n "$task_at" ] || fail "herdr-child-worktree-close: forced cleanup never closed the child task pane"
  [ "$wt_at" -lt "$task_at" ] \
    || fail "herdr-child-worktree-close: the worktree pane must close before the task pane so the task pane's own close still empties the workspace"
  [ ! -e "$home/state/child-herdr.meta" ] \
    || fail "herdr-child-worktree-close: a fully confirmed close left the child's durable metadata behind"
  [ ! -d "$home" ] \
    || fail "herdr-child-worktree-close: a fully confirmed close left the secondmate home behind"
  pass "forced secondmate teardown closes a projected child's worktree pane before its task pane and then completes"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir> [projected] [journal-token]
  local case_dir=$1 projected=${2:-} token=${3:-AbCdEfGhIjKlMnOpQrStUv}
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  if [ "$projected" = projected ]; then
    printf '%s\n' \
      'herdr_worktree_tab_id=w1:t9' \
      'herdr_worktree_pane_id=w1:p9' >> "$case_dir/state/task-x1.meta"
  fi
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    printf '%s\n' "${3:-}" >> "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if grep -qxF "${3:-}" "${FM_FAKE_HERDR_CLOSED:?}" 2>/dev/null; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ] \
         || [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN_PANE:-}" = "${3:-}" ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    if [ "${3:-}" = w1:p9 ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p9","tab_id":"w1:t9","workspace_id":"w1"}}}'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    fi
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  [ "$(grep -c '^pane close ' "$log")" = 1 ] \
    || fail "a task with no recorded worktree pane must still issue exactly one pane close"
  assert_contains "$(cat "$log")" "pane close w1:p2" \
    "the single close did not target the recorded task pane"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

herdr_log_close_index() {  # <log> <pane-id>
  grep -n "^pane close $2 " "$1" | head -1 | cut -d: -f1
}

test_herdr_projection_teardown_closes_worktree_pane_before_task_pane() {
  local case_dir log closed restored wt_at task_at
  case_dir=$(make_case herdr-projection-worktree-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir" projected
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-worktree-close: forced teardown failed"
  wt_at=$(herdr_log_close_index "$log" w1:p9)
  task_at=$(herdr_log_close_index "$log" w1:p2)
  [ -n "$wt_at" ] || fail "projected teardown never closed the recorded worktree pane"
  [ -n "$task_at" ] || fail "projected teardown never closed the recorded task pane"
  [ "$wt_at" -lt "$task_at" ] \
    || fail "the worktree pane must close before the task pane so the task pane's own close still empties the workspace"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "a confirmed two-pane close did not retire the presentation journal"
  [ ! -e "$case_dir/state/task-x1.meta" ] \
    || fail "a confirmed two-pane close did not remove the durable endpoint metadata"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  pass "herdr projection teardown closes the worktree pane before the task pane and then retires every record"
}

test_herdr_projection_teardown_retains_records_when_worktree_close_unconfirmed() {
  local case_dir log closed restored rc
  case_dir=$(make_case herdr-projection-worktree-unconfirmed)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir" projected
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    FM_FAKE_HERDR_PRESENCE_UNKNOWN_PANE=w1:p9 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an unknown worktree-pane presence must refuse teardown, not report success"
  [ -n "$(herdr_log_close_index "$log" w1:p9)" ] \
    || fail "the regression did not exercise an attempted worktree-pane close"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "an unconfirmed worktree close erased the only record of the worktree pane"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "an unconfirmed worktree close retired the presentation journal"
  assert_grep "worktree tab pane w1:p9 for task-x1 is not confirmed gone" "$case_dir/stderr" \
    "the refusal did not name the worktree pane whose close could not be confirmed"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "an unconfirmed worktree close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when the worktree pane close is unconfirmed"
}

test_herdr_quarantined_journal_teardown_still_closes_worktree_pane() {
  local case_dir log closed restored wt_at task_at
  case_dir=$(make_case herdr-projection-worktree-quarantined)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir" projected ZzZzZzZzZzZzZzZzZzZzZz
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-worktree-quarantined: forced teardown failed"
  assert_grep "remains quarantined" "$case_dir/stderr" \
    "the fixture did not exercise the quarantined-journal fallback path"
  wt_at=$(herdr_log_close_index "$log" w1:p9)
  task_at=$(herdr_log_close_index "$log" w1:p2)
  [ -n "$wt_at" ] \
    || fail "the quarantined-journal fallback deleted the metadata without closing the recorded worktree pane"
  [ -n "$task_at" ] || fail "the quarantined-journal fallback never closed the task pane"
  [ "$wt_at" -lt "$task_at" ] \
    || fail "the quarantined-journal fallback must also close the worktree pane first"
  [ ! -e "$case_dir/state/task-x1.meta" ] \
    || fail "a confirmed quarantined-journal close did not remove the durable endpoint metadata"
  pass "herdr quarantined-journal teardown closes the worktree pane before erasing its only record"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

# --- captured wedge context outlives the terminated crewmate -----------------
#
# `stuck-crewmate-recovery` writes why a worker failed to data/<id>/recovery-context.md
# BEFORE exiting the wedged agent, because the pane dies with the process and is the
# only other place that context exists. That choice of location is only sound if the
# file survives teardown the way a scout's data/<id>/report.md does - state/<id>.* and
# anything left inside the worktree do not.

# `treehouse return --force <wt>`: give the working copy back to the pool, so the
# directory the crewmate was living in is gone once teardown completes. The default
# mock in make_case just exits 0, which would leave the worktree standing and let a
# survives-teardown assertion pass for the wrong reason.
add_returning_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  [ -n "$wt" ] && [ -d "$wt" ] && rm -rf -- "$wt"
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Run teardown with the case's own data dir, so data/<id>/ writes stay in the sandbox.
run_teardown_with_data() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_captured_recovery_context_survives_teardown() {
  local case_dir rc wt_head
  case_dir=$(make_case recovery-context-survives)
  write_meta "$case_dir" local-only ship
  add_returning_treehouse "$case_dir"
  printf '%s\n' 'working: rerunning the migration' > "$case_dir/state/task-x1.status"

  # What the recovery playbook captures before it exits the wedged agent.
  mkdir -p "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/recovery-context.md" <<'MD'
Attempt 1: tried rerunning the schema migration twice after a redirect; got as far as
dumping the pre-migration schema; kept hitting `PG::UndefinedTable: relation
"shipments" does not exist`.
MD
  # The same note committed inside the worktree instead - the location the playbook
  # rejects, because the worktree goes back to the pool with the task.
  wt_commit_file "$case_dir" recovery-context.md \
    'Attempt 1: same note, parked in the worktree' "park note in worktree"

  wt_commit "$case_dir" "work so far"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown_with_data "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "recovery-context-survives: teardown should succeed on landed work"
  [ ! -e "$case_dir/state/task-x1.meta" ] \
    || fail "recovery-context-survives: state/<id>.meta outlived teardown"
  [ ! -e "$case_dir/state/task-x1.status" ] \
    || fail "recovery-context-survives: state/<id>.status outlived teardown"
  [ ! -e "$case_dir/wt/recovery-context.md" ] \
    || fail "recovery-context-survives: worktree copy outlived the return (regression is not exercised)"
  [ -f "$case_dir/data/task-x1/recovery-context.md" ] \
    || fail "recovery-context-survives: data/<id>/recovery-context.md was discarded by teardown"
  assert_grep 'PG::UndefinedTable' "$case_dir/data/task-x1/recovery-context.md" \
    "recovery-context-survives: the captured failure reason did not survive intact"
  pass "captured data/<id>/recovery-context.md survives teardown that erases state and the worktree"
}

cleanup_fixture() {
  local name=$1 case_dir
  case_dir=$(make_case "cleanup-$name")
  printf '%s\n' 'target' '.build/' 'build/' '*.log' '.evidence/' 'scratch/' '*.tmp' \
    'node_modules/' 'vendor/' '.venv/' 'venv/' '.bundle/' '.env' > "$case_dir/wt/.gitignore"
  mkdir -p "$case_dir/wt/build"
  printf 'tracked\n' > "$case_dir/wt/build/source"
  git -C "$case_dir/wt" add -f .gitignore build/source
  git -C "$case_dir/wt" commit -qm 'fixture ignores and tracked build source'
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  write_meta "$case_dir" local-only ship
  printf '%s\n' "$case_dir"
}

cleanup_free_fixture() {
  local case_dir=$1
  mkdir -p "$case_dir/pool"
  printf '{"version":4,"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' \
    "$case_dir/wt" > "$case_dir/pool/treehouse-state.json"
  : > "$case_dir/pool/treehouse-state.lock"
  printf '[{"name":"1","path":"%s","status":"available","lease_id":"","processes":[]}]\n' \
    "$case_dir/wt" > "$case_dir/status.json"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  cat "$CLEANUP_CASE/status.json"
  exit 0
fi
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

run_cleanup_free() {
  local case_dir=$1; shift
  CLEANUP_CASE="$case_dir" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" --clean-free-slot "$case_dir/project" "$case_dir/pool" 1 "$@"
}

test_cleanup_outputs() {
  local c name
  c=$(cleanup_fixture outputs)
  for name in target .build build scratch .evidence; do
    mkdir -p "$c/wt/$name/nested"
    printf 'compiler output\n' > "$c/wt/$name/nested/old"
  done
  printf 'old log\n' > "$c/wt/fri24-previous.log"
  printf 'temp\n' > "$c/wt/file.tmp"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail "cleanup outputs: teardown failed"
  for name in target .build scratch .evidence build/nested fri24-previous.log file.tmp; do
    [ ! -e "$c/wt/$name" ] || fail "cleanup outputs: ignored $name survived"
  done
  [ "$(cat "$c/wt/build/source")" = tracked ] || fail 'cleanup removed tracked build source'
  grep -Eq '^cleanup: removed .+; freed ~[1-9][0-9]* bytes' "$c/out" || fail 'missing one-line cleanup size report'
  pass 'teardown removes ignored output and scratch and reports allocated space'
}

test_cleanup_keep() {
  local c name
  c=$(cleanup_fixture keep)
  printf '%s\n' deps/ .yarn/ Pods/ .terraform/ .gradle/ bower_components/ .lavish/ \
    '.env*' .claude/ .codex/ .agents/ CLAUDE.local.md \
    >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  for name in node_modules vendor/bundle .venv venv .bundle deps .yarn/cache Pods .terraform \
    .gradle bower_components .lavish .claude .codex .agents; do
    mkdir -p "$c/wt/$name"
    printf 'dependency\n' > "$c/wt/$name/installed"
  done
  mkdir -p "$c/wt/vendor/cache" "$c/wt/scratch/node_modules" "$c/wt/.yarn/build"
  printf 'keep\n' > "$c/wt/scratch/node_modules/installed"
  printf 'scratch\n' > "$c/wt/vendor/cache/old.log"
  printf 'scratch\n' > "$c/wt/.yarn/build/old"
  printf 'secret config\n' > "$c/wt/.env"
  printf 'secret config\n' > "$c/wt/.env.local"
  printf 'local notes\n' > "$c/wt/CLAUDE.local.md"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'cleanup keep: teardown failed'
  for name in node_modules vendor/bundle .venv venv .bundle scratch/node_modules deps .yarn/cache \
    Pods .terraform .gradle bower_components .lavish .claude .codex .agents; do
    [ -f "$c/wt/$name/installed" ] || fail "cleanup removed dependency $name"
  done
  [ -f "$c/wt/.env" ] || fail 'cleanup removed private environment configuration'
  [ -f "$c/wt/.env.local" ] || fail 'cleanup removed private .env.local configuration'
  [ -f "$c/wt/CLAUDE.local.md" ] || fail 'cleanup removed local agent notes'
  [ ! -e "$c/wt/.yarn/build" ] || fail 'yarn cache keep widened to all of .yarn'
  [ ! -e "$c/wt/vendor/cache/old.log" ] || fail 'dependency keep widened to all vendor'
  pass 'one keep-list preserves dependency installs, private configuration, review sessions and agent notes'
}

test_cleanup_unlanded() {
  local c
  c=$(cleanup_fixture unlanded)
  wt_commit_file "$c" new-source 'unlanded'
  mkdir -p "$c/wt/target"
  printf 'output\n' > "$c/wt/target/old"
  if run_teardown "$c" > "$c/out" 2> "$c/err"; then fail 'cleanup allowed unlanded work'; fi
  [ -f "$c/wt/target/old" ] || fail 'cleanup ran before landed-work refusal'
  [ -f "$c/state/task-x1.meta" ] || fail 'unlanded refusal removed task state'
  pass 'unlanded refusal precedes ignored cleanup'
}

test_cleanup_symlinks() {
  local c external
  c=$(cleanup_fixture symlinks)
  mkdir -p "$c/task-temp/target" "$c/external"
  printf 'build\n' > "$c/task-temp/target/old"
  printf 'external\n' > "$c/external/source"
  printf 'tasktmp=%s\n' "$c/task-temp" >> "$c/state/task-x1.meta"
  ln -s "$c/task-temp/target" "$c/wt/target"
  external="$EXTERNAL_PARENT/symlinks"
  mkdir "$external"
  printf 'external\n' > "$external/source"
  ln -s "$external" "$c/wt/build/elsewhere.log"
  ln -s "$c/task-temp/missing" "$c/wt/dangling.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'symlink teardown failed'
  [ ! -L "$c/wt/target" ] || fail 'build symlink survived'
  [ ! -e "$c/task-temp/target" ] || fail 'temporary build target survived'
  [ ! -L "$c/wt/dangling.log" ] || fail 'dangling link survived'
  [ ! -L "$c/wt/build/elsewhere.log" ] || fail 'external link survived'
  [ -f "$external/source" ] || fail 'followed non-temporary symlink'
  rm -rf "${EXTERNAL_PARENT:?}"/symlinks
  pass 'temporary build targets removed; external and dangling links only unlinked'
}

test_cleanup_force() {
  local c
  c=$(cleanup_fixture force)
  wt_commit_file "$c" new-source 'unlanded'
  printf 'untracked\n' > "$c/wt/untracked-source"
  printf 'modified\n' > "$c/wt/build/source"
  printf 'old\n' > "$c/wt/build/old.log"
  mkdir -p "$c/wt/scratch"
  printf 'evidence\n' > "$c/wt/scratch/evidence.md"
  if run_teardown "$c" > "$c/out" 2> "$c/err"; then fail 'force fixture was not unlanded and dirty'; fi
  run_teardown "$c" --force > "$c/out" 2> "$c/err" || fail 'forced teardown failed'
  [ -f "$c/wt/untracked-source" ] || fail 'force widened cleanup to non-ignored source'
  [ "$(cat "$c/wt/build/source")" = modified ] || fail 'force widened cleanup to tracked source'
  [ -f "$c/wt/build/old.log" ] || fail 'forced discard removed ignored output'
  [ -f "$c/wt/scratch/evidence.md" ] || fail 'forced discard removed ignored evidence'
  ! grep -q '^cleanup:' "$c/out" || fail 'forced discard ran ignored cleanup'
  pass 'a forced discard bypasses the landed guards and never runs ignored cleanup'
}

test_cleanup_scout() {
  local c
  c=$(cleanup_fixture scout)
  write_meta "$c" local-only scout
  printf 'decisions_reviewed=1\n' >> "$c/state/task-x1.meta"
  mkdir -p "$c/data/task-x1" "$c/wt/scratch"
  printf 'report\n' > "$c/data/task-x1/report.md"
  add_compatible_tasks_axi "$c"
  mv "$c/fakebin/tasks-axi" "$c/fakebin/tasks-axi-base"
  cat > "$c/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" != 'hold --help' ] || { printf '%s\n' '  --kind captain'; exit 0; }
exec "$(dirname "$0")/tasks-axi-base" "$@"
SH
  chmod +x "$c/fakebin/tasks-axi"
  printf 'notes\n' > "$c/wt/scratch/notes.md"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'scout teardown failed'
  [ ! -e "$c/state/task-x1.meta" ] || fail 'scout teardown did not finish'
  [ -f "$c/wt/scratch/notes.md" ] || fail 'scout discard removed ignored notes without a landed proof'
  pass 'a scout discard has no landed proof and never runs ignored cleanup'
}

test_cleanup_free() {
  local c
  c=$(cleanup_fixture free)
  cleanup_free_fixture "$c"
  printf 'source\n' > "$c/wt/untracked-source"
  mkdir -p "$c/wt/target"
  printf 'old\n' > "$c/wt/target/output"
  run_cleanup_free "$c" > "$c/out" 2> "$c/err" || fail 'free-slot cleanup failed'
  [ ! -e "$c/wt/target" ] || fail 'free-slot cleanup left target'
  [ -f "$c/wt/untracked-source" ] || fail 'free-slot cleanup touched non-ignored source'
  [ -f "$c/wt/build/source" ] || fail 'free-slot cleanup touched tracked source'
  pass 'free-slot mode applies the same cleanup without returning or resetting the slot'
}

test_cleanup_leased() {
  local c
  c=$(cleanup_fixture leased)
  cleanup_free_fixture "$c"
  printf 'old\n' > "$c/wt/old.log"
  python3 - "$c/pool/treehouse-state.json" <<'PYCODE'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s['worktrees'][0]['leased'] = True
open(p, 'w').write(json.dumps(s))
PYCODE
  if run_cleanup_free "$c" > "$c/out" 2> "$c/err"; then fail 'free-slot mode allowed a leased slot'; fi
  grep -q 'leased' "$c/err" || fail 'leased-slot refusal did not explain lease'
  [ -f "$c/wt/old.log" ] || fail 'leased slot was cleaned'
  pass 'free-slot mode refuses a lease even if status claims available'
}

test_cleanup_protected_targets() {
  local c destination
  for destination in ancestor root descendant; do
    c=$(cleanup_fixture "protected-$destination")
    case "$destination" in
      ancestor) ln -s "$c" "$c/wt/target" ;;
      root) ln -s "$c/wt" "$c/wt/target" ;;
      descendant) ln -s "$c/wt/build" "$c/wt/target" ;;
    esac
    "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "$TMP_ROOT" > "$c/out" 2> "$c/err" \
      || fail 'worktree target prevented safe unlink'
    [ -f "$c/wt/build/source" ] || fail "temporary $destination target destroyed tracked source"
    [ -f "$c/state/task-x1.meta" ] || fail "temporary $destination target destroyed task state"
    [ ! -L "$c/wt/target" ] || fail 'worktree link was not unlinked'
    ! grep -q 'kept temporary' "$c/out" || fail "cleanup offered the $destination worktree path for removal"
  done
  c=$(cleanup_fixture git-target)
  fm_git_init_commit "$c/other-repo"
  mkdir -p "$c/other-repo/target"
  printf 'source\n' > "$c/other-repo/target/source"
  git -C "$c/other-repo" add target/source
  git -C "$c/other-repo" commit -qm 'other tracked build source'
  ln -s "$c/other-repo/target" "$c/wt/target"
  "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "$c" > "$c/out" 2> "$c/err" \
    || fail 'git target prevented safe unlink'
  [ -f "$c/other-repo/target/source" ] || fail 'temporary target destroyed another repository source'
  [ ! -L "$c/wt/target" ] || fail 'git target link was not unlinked'
  pass 'temporary targets cannot erase the worktree ancestor or another repository'
}

test_cleanup_link_cycle() {
  local c
  c=$(cleanup_fixture link-cycle)
  ln -s target "$c/wt/target"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'symlink cycle prevented teardown'
  [ ! -L "$c/wt/target" ] || fail 'cyclic symlink survived'
  pass 'cyclic ignored build link is unlinked without traversal'
}

test_cleanup_reservations() {
  local c flag
  for flag in owner_pid destroying lease_id recovery_error; do
    c=$(cleanup_fixture "reserved-$flag")
    cleanup_free_fixture "$c"
    printf 'output\n' > "$c/wt/old.log"
    python3 - "$c/pool/treehouse-state.json" "$flag" <<'PYCODE'
import json, sys
p, flag = sys.argv[1:]
s = json.load(open(p))
s['worktrees'][0][flag] = 123 if flag == 'owner_pid' else True
open(p, 'w').write(json.dumps(s))
PYCODE
    if run_cleanup_free "$c" > "$c/out" 2> "$c/err"; then fail "free-slot mode allowed reservation $flag"; fi
    [ -f "$c/wt/old.log" ] || fail "reserved slot $flag was cleaned"
  done
  pass 'free-slot mode refuses outstanding reservations and recovery state'
}

test_cleanup_unavailable() {
  local c state
  for state in leased in-use dirty unverified damaged; do
    c=$(cleanup_fixture "unavailable-$state")
    cleanup_free_fixture "$c"
    printf 'output\n' > "$c/wt/old.log"
    printf '[{"name":"1","path":"%s","status":"%s"}]\n' "$c/wt" "$state" > "$c/status.json"
    if run_cleanup_free "$c" > "$c/out" 2> "$c/err"; then fail "free-slot mode allowed status $state"; fi
    [ -f "$c/wt/old.log" ] || fail "unavailable slot $state was cleaned"
  done
  pass 'free-slot mode refuses every non-available status'
}

test_cleanup_changed_pool() {
  local c
  c=$(cleanup_fixture changed-pool)
  cleanup_free_fixture "$c"
  printf 'output\n' > "$c/wt/old.log"
  cat > "$c/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '\n' >> "$CLEANUP_CASE/pool/treehouse-state.json"
cat "$CLEANUP_CASE/status.json"
SH
  if run_cleanup_free "$c" > "$c/out" 2> "$c/err"; then fail 'cleanup allowed changed pool snapshot'; fi
  [ -f "$c/wt/old.log" ] || fail 'cleanup ran after pool changed'
  pass 'free-slot cleanup refuses a pool that changed during inspection'
}

test_cleanup_lock() {
  local c
  c=$(cleanup_fixture locked-pool)
  cleanup_free_fixture "$c"
  printf 'output\n' > "$c/wt/old.log"
  if ! CLEANUP_CASE="$c" PATH="$c/fakebin:$PATH" python3 - "$c" "$TEARDOWN" <<'PYCODE'
import fcntl, pathlib, subprocess, sys
c, teardown = sys.argv[1:]
with open(c + '/pool/treehouse-state.lock', 'r+') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    result = subprocess.run([teardown, '--clean-free-slot', c + '/project', c + '/pool', '1'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0, 'cleanup ignored the native pool lock'
assert pathlib.Path(c + '/wt/old.log').exists(), 'contended pool was cleaned'
PYCODE
  then
    fail 'native pool lock regression'
  fi
  pass 'free-slot cleanup holds the native pool lock and refuses contention'
}

test_cleanup_free_unlanded() {
  local c
  c=$(cleanup_fixture free-unlanded)
  cleanup_free_fixture "$c"
  wt_commit_file "$c" new-source 'not landed'
  printf 'output\n' > "$c/wt/old.log"
  if run_cleanup_free "$c" > "$c/out" 2> "$c/err"; then fail 'free-slot mode allowed unlanded branch'; fi
  [ -f "$c/wt/old.log" ] || fail 'free-slot mode cleaned unlanded branch'
  pass 'free-slot cleanup independently verifies content landed on the local default'
}

test_cleanup_nested_repository() {
  local c
  c=$(cleanup_fixture nested-repo)
  mkdir -p "$c/wt/scratch"
  fm_git_init_commit "$c/wt/scratch/other-repo"
  printf 'old\n' > "$c/wt/scratch/old.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'nested repository teardown failed'
  [ -f "$c/wt/scratch/other-repo/README.md" ] || fail 'cleanup destroyed nested tracked source'
  [ ! -e "$c/wt/scratch/old.log" ] || fail 'nested repository prevented sibling scratch cleanup'
  pass 'ignored scratch preserves nested repository source'
}

test_cleanup_unattributed_target() {
  local c
  c=$(cleanup_fixture unattributed-target)
  mkdir -p "$c/shared-temp/target"
  printf 'other task\n' > "$c/shared-temp/target/output"
  ln -s "$c/shared-temp/target" "$c/wt/target"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'unattributed target teardown failed'
  [ -f "$c/shared-temp/target/output" ] || fail 'cleanup destroyed a temp target with no task ownership record'
  [ ! -L "$c/wt/target" ] || fail 'unattributed build link survived'
  grep -Fq "; kept temporary targets: '$(real_path "$c/shared-temp/target")' (~" "$c/out" \
    || fail 'cleanup line did not name the unattributed temporary target'
  grep -Eq "kept temporary targets: '[^']+' \(~[1-9][0-9]* bytes\)" "$c/out" \
    || fail 'cleanup line did not size the unattributed temporary target'
  pass 'unattributed temporary targets are preserved while their ignored links are removed'
}

test_cleanup_external_links() {
  local c external
  c=$(cleanup_fixture external-links)
  external="$EXTERNAL_PARENT/external-links"
  mkdir "$external"
  printf 'unrelated\n' > "$external/source"
  ln -s "$external" "$c/wt/target"
  "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" /var/tmp > "$c/out" 2> "$c/err" \
    || fail 'non-temporary build target prevented unlink'
  [ -f "$external/source" ] || fail 'cleanup followed build target outside permitted temp roots'
  rm -rf "${EXTERNAL_PARENT:?}"/external-links
  c=$(cleanup_fixture nested-links)
  mkdir -p "$c/task-temp/target" "$c/task-temp/shared"
  printf 'unrelated\n' > "$c/task-temp/shared/source"
  ln -s "$c/task-temp/shared" "$c/task-temp/target/build"
  ln -s "$c/task-temp/target" "$c/wt/target"
  "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "$c/task-temp" > "$c/out" 2> "$c/err" \
    || fail 'nested symlink prevented cleanup'
  [ -f "$c/task-temp/shared/source" ] || fail 'cleanup followed a link inside the temp target'
  [ ! -e "$c/task-temp/target" ] || fail 'owned build target survived'
  c=$(cleanup_fixture nonbuild-links)
  mkdir -p "$c/task-temp/shared"
  printf 'unrelated\n' > "$c/task-temp/shared/source"
  ln -s "$c/task-temp/shared" "$c/wt/old.log"
  "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "$c/task-temp" > "$c/out" 2> "$c/err" \
    || fail 'non-build link prevented cleanup'
  [ -f "$c/task-temp/shared/source" ] || fail 'cleanup followed a non-build symlink'
  pass 'external build links and links inside a temp target are never followed'
}

test_cleanup_slot_identity() {
  local c variant
  for variant in missing duplicate wrong-path; do
    c=$(cleanup_fixture "slot-identity-$variant")
    cleanup_free_fixture "$c"
    printf 'output\n' > "$c/wt/old.log"
    python3 - "$c/pool/treehouse-state.json" "$c/status.json" "$variant" <<'PYCODE'
import json, sys
p, status_path, variant = sys.argv[1:]
s = json.load(open(p))
if variant == 'missing':
    s['worktrees'] = []
elif variant == 'duplicate':
    s['worktrees'].append(s['worktrees'][0])
else:
    status = json.load(open(status_path))
    status[0]['path'] += '/other'
    open(status_path, 'w').write(json.dumps(status))
open(p, 'w').write(json.dumps(s))
PYCODE
    if run_cleanup_free "$c" > "$c/out" 2> "$c/err"; then fail "free-slot mode allowed $variant identity"; fi
    [ -f "$c/wt/old.log" ] || fail "free-slot mode cleaned $variant identity"
    grep -q '^REFUSED: ignored cleanup:' "$c/err" || fail "missing $variant identity diagnostic"
  done
  pass 'free-slot mode requires one matching state and status identity'
}

test_cleanup_hardlinks() {
  local c
  c=$(cleanup_fixture hardlinks)
  printf 'shared blocks\n' > "$c/external-source"
  ln "$c/external-source" "$c/wt/old.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'hardlink teardown failed'
  [ -f "$c/external-source" ] || fail 'hardlink source was removed'
  [ ! -e "$c/wt/old.log" ] || fail 'ignored hardlink survived'
  grep -q '; freed ~0 bytes$' "$c/out" || fail 'cleanup counted still-shared hardlink blocks as freed'
  pass 'cleanup does not claim freed blocks while another hardlink retains them'
}

test_cleanup_gate() {
  local c rc=0
  c=$(cleanup_fixture gate)
  cleanup_free_fixture "$c"
  printf 'output\n' > "$c/wt/old.log"
  FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 run_cleanup_free "$c" > "$c/out" 2> "$c/err" || rc=$?
  expect_code 3 "$rc" 'free-slot mode must retain the gate-agent lifecycle refusal'
  [ -f "$c/wt/old.log" ] || fail 'gate agent cleaned the free slot'
  pass 'free-slot mode retains the gate-agent lifecycle refusal before mutation'
}

test_cleanup_dangling_build() {
  local c
  c=$(cleanup_fixture dangling-build)
  mkdir -p "$c/task-temp"
  printf 'tasktmp=%s\n' "$c/task-temp" >> "$c/state/task-x1.meta"
  ln -s "$c/task-temp/missing" "$c/wt/target"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'dangling build link prevented teardown'
  [ ! -L "$c/wt/target" ] || fail 'dangling build link survived'
  pass 'owned temporary build link is unlinked when its target is already missing'
}

real_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

mode_of() {
  python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"
}

# Start a detached process whose working directory is the case worktree (or the
# given directory), as a worker's dev server or watcher is. flush recreates
# scratch/dev.log when asked to stop; stubborn ignores SIGTERM. Prints the pid
# once the handler is armed.
start_worktree_writer() {
  local case_dir=$1 behavior=$2 directory=${3:-$1/wt} pid
  pid=$(python3 - "$directory" "$behavior" <<'PYCODE'
import os, signal, sys
worktree, behavior = sys.argv[1:]
ready_read, ready_write = os.pipe()
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        os.close(ready_read)
        null = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(null, fd)
        os.chdir(worktree)
        def flush(*_):
            os.makedirs("scratch", exist_ok=True)
            with open("scratch/dev.log", "a") as log:
                log.write("flushed on shutdown\n")
            os._exit(0)
        signal.signal(signal.SIGTERM, flush if behavior == "flush" else signal.SIG_IGN)
        os.write(ready_write, str(os.getpid()).encode())
        os.close(ready_write)
        while True:
            signal.pause()
    os._exit(0)
os.close(ready_write)
os.wait()
print(os.read(ready_read, 64).decode())
PYCODE
  )
  printf '%s\n' "$pid" >> "$TMP_ROOT/writer-pids"
  printf '%s\n' "$pid" > "$case_dir/writer.pid"
  printf '%s\n' "$pid"
}

process_running() {
  local stat
  stat=$(ps -o stat= -p "$1" 2>/dev/null || true)
  case "$stat" in ''|Z*) return 1 ;; esac
}

add_selection_probe() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ls-files --others --ignored "*)
    if [ -f "$CLEANUP_CASE/writer.pid" ]; then
      stat=$(ps -o stat= -p "$(cat "$CLEANUP_CASE/writer.pid")" 2>/dev/null || true)
      case "$stat" in ''|Z*) echo stopped ;; *) echo running ;; esac >> "$CLEANUP_CASE/writer-at-selection"
    fi
    if [ -f "$CLEANUP_CASE/pool/treehouse-state.lock" ]; then
      python3 -c 'import fcntl, sys
lock = open(sys.argv[1], "r+")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("acquired")
except OSError:
    print("held")' "$CLEANUP_CASE/pool/treehouse-state.lock" >> "$CLEANUP_CASE/lock-at-selection"
    fi
    ;;
esac
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/git"
}

add_return_probe() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  if [ -e "$CLEANUP_CASE/wt/scratch" ]; then echo present; else echo absent; fi >> "$CLEANUP_CASE/scratch-at-return"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

test_cleanup_writers() {
  local c pid
  c=$(cleanup_fixture writers)
  add_selection_probe "$c"
  add_return_probe "$c"
  mkdir -p "$c/wt/scratch"
  printf 'old\n' > "$c/wt/scratch/dev.log"
  pid=$(start_worktree_writer "$c" flush)
  CLEANUP_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'writer teardown failed'
  [ "$(cat "$c/writer-at-selection")" = stopped ] || fail 'cleanup selected output while a worktree writer still ran'
  ! process_running "$pid" || fail 'worktree writer survived teardown'
  [ ! -e "$c/wt/scratch" ] || fail 'output a stopping writer flushed survived cleanup'
  [ "$(cat "$c/scratch-at-return")" = absent ] || fail 'slot was returned before ignored cleanup finished'
  pass 'worktree writers stop before cleanup, and cleanup finishes before the slot is released'
}

test_cleanup_stubborn_writer() {
  local c pid
  c=$(cleanup_fixture stubborn-writer)
  mkdir -p "$c/wt/scratch"
  printf 'old\n' > "$c/wt/scratch/dev.log"
  pid=$(start_worktree_writer "$c" stubborn)
  FM_WORKTREE_CLEANUP_STOP_GRACE_SECS=0.2 run_teardown "$c" > "$c/out" 2> "$c/err" \
    || fail 'stubborn writer teardown failed'
  ! process_running "$pid" || fail 'writer that ignores SIGTERM survived'
  [ ! -e "$c/wt/scratch" ] || fail 'cleanup skipped output of a writer that ignored SIGTERM'
  pass 'a writer that ignores SIGTERM is killed before cleanup'
}

test_cleanup_caller_in_worktree() {
  local c
  c=$(cleanup_fixture caller-in-worktree)
  printf 'old\n' > "$c/wt/old.log"
  ( cd "$c/wt" && run_teardown "$c" ) > "$c/out" 2> "$c/err" || fail 'teardown run from inside the worktree failed'
  [ ! -e "$c/state/task-x1.meta" ] || fail 'teardown run from inside the worktree did not finish'
  [ ! -e "$c/wt/old.log" ] || fail 'teardown run from inside the worktree left ignored output'
  pass 'stopping worktree writers never signals teardown or its callers'
}

# A worker can commit a module named like one the helper imports. Teardown runs
# with firstmate's authority, so that module must never load from the caller's
# working directory, whether Python adds it as '' or through an empty
# PYTHONPATH element.
cleanup_planted_modules() {
  local c=$1 name
  for name in fnmatch json; do
    printf 'open(%s, "w").close()\n' "'$c/imported-$name'" > "$c/wt/$name.py"
  done
  git -C "$c/wt" add fnmatch.py json.py
  git -C "$c/wt" -c user.email=t@t -c user.name=t commit -qm 'worker modules'
  git -C "$c/project" update-ref refs/heads/main "$(git -C "$c/wt" rev-parse HEAD)"
  printf 'old\n' > "$c/wt/old.log"
}

test_cleanup_caller_modules() {
  local c name rc=0
  c=$(cleanup_fixture caller-modules)
  cleanup_planted_modules "$c"
  ( cd "$c/wt" && run_teardown "$c" ) > "$c/out" 2> "$c/err" || rc=$?
  for name in fnmatch json; do
    [ ! -e "$c/imported-$name" ] || fail "cleanup imported $name.py from teardown's working directory"
  done
  [ "$rc" -eq 0 ] || fail 'teardown with worker modules in its working directory failed'
  [ ! -e "$c/wt/old.log" ] || fail 'cleanup beside worker modules left ignored output'
  pass "cleanup never imports modules from teardown's working directory"
}

test_cleanup_caller_modules_pythonpath() {
  local c name rc=0
  c=$(cleanup_fixture caller-modules-pythonpath)
  cleanup_planted_modules "$c"
  ( cd "$c/wt" && PYTHONPATH="$c/no-such-dir:" run_teardown "$c" ) > "$c/out" 2> "$c/err" || rc=$?
  for name in fnmatch json; do
    [ ! -e "$c/imported-$name" ] || fail "cleanup imported $name.py through an empty PYTHONPATH element"
  done
  [ "$rc" -eq 0 ] || fail 'teardown with an empty PYTHONPATH element failed'
  [ ! -e "$c/wt/old.log" ] || fail 'cleanup with an empty PYTHONPATH element left ignored output'
  pass 'cleanup never imports modules from an empty PYTHONPATH element'
}

test_cleanup_caller_dir_deleted() {
  local c
  c=$(cleanup_fixture caller-dir-deleted)
  printf 'old\n' > "$c/wt/old.log"
  mkdir "$c/gone"
  ( cd "$c/gone" && rmdir "${c:?}"/gone && run_teardown "$c" ) > "$c/out" 2> "$c/err" \
    || fail 'teardown from a deleted working directory failed'
  [ ! -e "$c/wt/old.log" ] || fail 'cleanup from a deleted working directory left ignored output'
  pass 'cleanup still runs when the caller'"'"'s working directory was deleted'
}

test_cleanup_scan_denied() {
  local c rc=0
  command -v sandbox-exec >/dev/null 2>&1 || { echo 'skip: sandbox-exec not found (process scan denial)'; return 0; }
  c=$(cleanup_fixture scan-denied)
  printf 'old\n' > "$c/wt/old.log"
  sandbox-exec -p '(version 1)(allow default)(deny process-info-listpids)' \
    "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "" > "$c/out" 2> "$c/err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'cleanup reported success without inspecting worktree processes'
  [ -f "$c/wt/old.log" ] || fail 'cleanup deleted output without inspecting worktree processes'
  grep -q 'cannot inspect' "$c/err" || fail 'missing process inspection diagnostic'
  pass 'cleanup refuses when it cannot see which processes use the worktree'
}

test_cleanup_unkillable_writer() {
  local c pid rc=0
  command -v sandbox-exec >/dev/null 2>&1 || { echo 'skip: sandbox-exec not found (signal denial)'; return 0; }
  c=$(cleanup_fixture unkillable-writer)
  printf 'old\n' > "$c/wt/old.log"
  pid=$(start_worktree_writer "$c" stubborn)
  FM_WORKTREE_CLEANUP_STOP_GRACE_SECS=0.1 sandbox-exec -p '(version 1)(allow default)(deny signal (target others))' \
    "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "" > "$c/out" 2> "$c/err" || rc=$?
  kill -KILL "$pid" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail 'cleanup reported success with a live worktree writer'
  [ -f "$c/wt/old.log" ] || fail 'cleanup deleted output while a worktree writer survived'
  grep -q "survived" "$c/err" || fail 'missing surviving-writer diagnostic'
  pass 'cleanup refuses while a worktree writer survives termination'
}

# The helper's clock is driven by the test: each sleep reports on fd 9 and ends
# only when the test ticks, so the grace wait is observed without real time.
# The writer is a direct child, so `wait` proves it is gone before the tick.
test_cleanup_grace_wait() {
  local c writer helper line rc=0 writer_rc=0 writer_reaped=0
  c=$(cleanup_fixture grace-wait)
  printf 'old\n' > "$c/wt/old.log"
  mkfifo "$c/started" "$c/release" "$c/sleeps" "$c/tick"
  mkdir "$c/clock"
  cat > "$c/clock/sitecustomize.py" <<'PYCODE'
import os, time
def sleep(_seconds):
    os.write(9, b"sleep\n")
    with open(os.environ["GRACE_TEST_TICK"]) as tick:
        tick.readline()
time.sleep = sleep
PYCODE
  exec 5<>"$c/release"
  ( cd "$c/wt" && exec python3 -c 'import os, signal, sys
def term(*_):
    print("term-started", flush=True)
    with open(os.path.join(sys.argv[1], "release")) as release:
        release.readline()
    with open(os.path.join(sys.argv[1], "term-done"), "w") as done:
        done.write("done\n")
    os._exit(0)
signal.signal(signal.SIGTERM, term)
print("armed", flush=True)
while True:
    signal.pause()' "$c" ) > "$c/started" &
  writer=$!
  printf '%s\n' "$writer" >> "$TMP_ROOT/writer-pids"
  exec 7<"$c/started"
  read -r line <&7 && [ "$line" = armed ] || fail 'grace-wait writer never armed its SIGTERM handler'
  FM_WORKTREE_CLEANUP_STOP_GRACE_SECS=30 GRACE_TEST_TICK="$c/tick" PYTHONPATH="$c/clock" \
    "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "" > "$c/out" 2> "$c/err" 9> "$c/sleeps" &
  helper=$!
  printf '%s\n' "$helper" >> "$TMP_ROOT/writer-pids"
  exec 4<"$c/sleeps"
  if read -r line <&4; then
    read -r line <&7 && [ "$line" = term-started ] || fail 'cleanup waited before signalling the writer'
    printf 'go\n' >&5
    wait "$writer" || writer_rc=$?
    writer_reaped=1
    printf 'tick\n' > "$c/tick"
    ! read -r line <&4 || fail 'cleanup kept waiting after the writer exited'
  fi
  wait "$helper" || rc=$?
  [ "$writer_reaped" -eq 1 ] || wait "$writer" 2>/dev/null || writer_rc=$?
  exec 4<&- 5<&- 7<&-
  [ -f "$c/term-done" ] || fail 'writer was killed before its SIGTERM handler finished'
  [ "$writer_rc" -eq 0 ] || fail "writer did not exit on its own (status $writer_rc)"
  [ "$rc" -eq 0 ] || fail 'grace-wait cleanup failed'
  [ ! -e "$c/wt/old.log" ] || fail 'grace-wait cleanup left output'
  pass 'SIGTERM gets its grace, and the wait ends as soon as the writer exits'
}

test_cleanup_readonly() {
  local c
  c=$(cleanup_fixture readonly)
  mkdir -p "$c/wt/build/gomod/pkg@v1" "$c/wt/scratch/ro/node_modules" "$c/outside-ro"
  printf 'package a\n' > "$c/wt/build/gomod/pkg@v1/a.go"
  printf 'log\n' > "$c/wt/build/aaa.log"
  printf 'keep\n' > "$c/wt/scratch/ro/node_modules/installed"
  printf 'keep\n' > "$c/outside-ro/source"
  ln -s "$c/outside-ro" "$c/wt/scratch/link"
  chmod 0555 "$c/wt/build/gomod/pkg@v1" "$c/wt/scratch/ro" "$c/outside-ro"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'read-only scratch blocked teardown'
  chmod -R u+w "$c/wt" "$c/outside-ro"
  [ ! -e "$c/wt/build/gomod" ] || fail 'read-only ignored directory survived'
  [ ! -e "$c/wt/build/aaa.log" ] || fail 'sibling ignored output survived'
  [ -f "$c/wt/build/source" ] || fail 'read-only cleanup removed tracked source'
  [ -f "$c/wt/scratch/ro/node_modules/installed" ] || fail 'read-only cleanup removed a kept dependency'
  [ -f "$c/outside-ro/source" ] || fail 'read-only cleanup followed a link'
  [ ! -L "$c/wt/scratch/link" ] || fail 'link into a read-only directory survived'
  pass 'read-only ignored scratch inside the worktree is made writable and removed'
}

test_cleanup_readonly_modes() {
  local c
  c=$(cleanup_fixture readonly-modes)
  mkdir -p "$c/wt/scratch/ro/node_modules" "$c/outside-ro"
  printf 'keep\n' > "$c/wt/scratch/ro/node_modules/installed"
  printf 'keep\n' > "$c/outside-ro/source"
  ln -s "$c/outside-ro" "$c/wt/scratch/link"
  chmod 0555 "$c/wt/scratch/ro" "$c/outside-ro"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'read-only modes teardown failed'
  [ "$(mode_of "$c/wt/scratch/ro")" = 555 ] || fail 'retained read-only directory kept a widened mode'
  [ "$(mode_of "$c/outside-ro")" = 555 ] || fail 'cleanup changed permissions through a link'
  chmod -R u+w "$c/wt" "$c/outside-ro"
  pass 'permission changes stay inside removed worktree scratch and never follow links'
}

test_cleanup_partial_failure() {
  local c made
  c=$(cleanup_fixture partial-failure)
  made="$c/made-by-task"
  mkdir -p "$made/ro"
  printf 'object\n' > "$made/ro/obj"
  printf 'removable\n' > "$made/zz-removable"
  chmod 0555 "$made/ro"
  printf '%s\n' "$made" > "$c/state/task-x1.temp-targets"
  ln -s "$made" "$c/wt/target"
  printf 'old\n' > "$c/wt/zzz.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'partial cleanup failure blocked teardown'
  [ "$(mode_of "$made/ro")" = 555 ] || fail 'cleanup changed permissions outside the worktree'
  chmod -R u+w "$made"
  [ -f "$made/ro/obj" ] || fail 'read-only fixture outside the worktree was removed'
  [ ! -e "$made/zz-removable" ] || fail 'cleanup stopped at the first failure'
  [ ! -e "$c/wt/zzz.log" ] || fail 'cleanup skipped entries after a failure'
  [ ! -e "$c/state/task-x1.meta" ] || fail 'cleanup failure blocked the rest of teardown'
  grep -Eq "^cleanup: removed [1-9][0-9]* ignored entries .*; freed ~[1-9][0-9]* bytes; failed: '[^']*/made-by-task/ro/obj' \\(" "$c/out" \
    || fail 'partial failure did not report completed removals, freed space and the failing path'
  [ "$(grep -o 'made-by-task/ro/obj' "$c/out" | wc -l | tr -d ' ')" = 1 ] || fail "partial failure reported the failing path more than once: $(cat "$c/out")"
  ! grep -q 'kept temporary' "$c/out" || fail 'partial failure also reported the recorded directory as kept'
  grep -q 'ignored cleanup incomplete' "$c/err" || fail 'teardown did not warn about incomplete cleanup'
  pass 'a failed path is reported with completed removals and freed space, and teardown continues'
}

test_cleanup_recorded_target() {
  local c made
  c=$(cleanup_fixture recorded-target)
  made="$c/made-by-task"
  mkdir -p "$made/deep"
  printf 'build\n' > "$made/deep/object"
  printf '%s\n' "$made" > "$c/state/task-x1.temp-targets"
  ln -s "$made" "$c/wt/target"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'recorded target teardown failed'
  [ ! -e "$made" ] || fail 'temporary target the task recorded survived'
  [ ! -L "$c/wt/target" ] || fail 'recorded build link survived'
  [ ! -e "$c/state/task-x1.temp-targets" ] || fail 'temporary-target record survived teardown'
  grep -Eq '; freed ~[1-9][0-9]* bytes$' "$c/out" || fail 'recorded target space was not reported'
  pass 'a temporary target recorded by the task is removed with its link'
}

test_cleanup_record_bounds() {
  local c made
  c=$(cleanup_fixture record-root)
  made="$c/made-by-task"
  mkdir -p "$made"
  printf 'build\n' > "$made/object"
  ln -s "$made" "$c/wt/target"
  printf '%s\n' /var/folders /tmp > "$c/record"
  "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "" "$c/record" > "$c/out" 2> "$c/err" \
    || fail 'temporary-root record prevented cleanup'
  [ -f "$made/object" ] || fail 'a whole temporary root was accepted as a task record'
  c=$(cleanup_fixture record-relative)
  made="$c/made-by-task"
  mkdir -p "$made"
  printf 'build\n' > "$made/object"
  ln -s "$made" "$c/wt/target"
  printf '%s\n' made-by-task > "$c/record"
  ( cd "$c" && "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "" "$c/record" ) > "$c/out" 2> "$c/err" \
    || fail 'relative record prevented cleanup'
  [ -f "$made/object" ] || fail 'a relative record entry attributed a temporary target'
  pass 'task records must name an absolute path inside a temporary root'
}

test_cleanup_lock_lifetime() {
  local c
  c=$(cleanup_fixture lock-lifetime)
  cleanup_free_fixture "$c"
  add_selection_probe "$c"
  printf 'output\n' > "$c/wt/old.log"
  run_cleanup_free "$c" > "$c/out" 2> "$c/err" || fail 'lock-lifetime free-slot cleanup failed'
  [ "$(cat "$c/lock-at-selection")" = held ] || fail 'another process acquired the pool lock during free-slot cleanup'
  [ ! -e "$c/wt/old.log" ] || fail 'lock-lifetime cleanup left output'
  pass 'free-slot deletion runs while Treehouse pool lock is held'
}

test_cleanup_rust_deps() {
  local c
  c=$(cleanup_fixture rust-deps)
  printf '%s\n' deps/ >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  mkdir -p "$c/wt/deps/plug" "$c/wt/target/debug/deps" "$c/wt/target/debug/incremental" \
    "$c/wt/build/cargo/debug/deps"
  printf 'dependency\n' > "$c/wt/deps/plug/installed"
  printf 'rlib\n' > "$c/wt/target/debug/deps/libold-0123.rlib"
  printf 'test binary\n' > "$c/wt/build/cargo/debug/deps/fri37_test-abcd"
  printf 'state\n' > "$c/wt/target/debug/incremental/state"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'rust deps teardown failed'
  [ ! -e "$c/wt/target" ] || fail 'cleanup kept Rust compiler deps in target/debug/deps'
  [ ! -e "$c/wt/build/cargo" ] || fail 'cleanup kept Rust compiler deps in build/cargo/debug/deps'
  [ -f "$c/wt/deps/plug/installed" ] || fail 'cleanup removed the root deps dependency install'
  [ -f "$c/wt/build/source" ] || fail 'rust deps cleanup removed tracked build source'
  pass 'compiler deps inside build output are removed while a root deps install stays'
}

test_cleanup_nested_deps() {
  local c
  c=$(cleanup_fixture nested-deps)
  printf '%s\n' deps/ >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  mkdir -p "$c/wt/apps/service/deps/plug" "$c/wt/apps/service/target/debug/deps"
  printf 'dependency\n' > "$c/wt/apps/service/deps/plug/installed"
  printf 'rlib\n' > "$c/wt/apps/service/target/debug/deps/libold-0123.rlib"
  printf 'secret config\n' > "$c/wt/build/.env"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'nested deps teardown failed'
  [ -f "$c/wt/apps/service/deps/plug/installed" ] || fail 'cleanup removed the nested apps/service/deps dependency install'
  [ ! -e "$c/wt/apps/service/target" ] || fail 'cleanup kept Rust compiler deps in a nested target/debug/deps'
  [ -f "$c/wt/build/.env" ] || fail 'the compiler-output exception for deps removed other kept entries inside build'
  pass 'a nested deps install stays while compiler deps inside nested build output go'
}

test_cleanup_recorded_unlinked() {
  local c made
  c=$(cleanup_fixture recorded-unlinked)
  made="$c/made-by-task"
  mkdir -p "$made/debug"
  printf 'build\n' > "$made/debug/object"
  printf '%s\n' "$made" > "$c/state/task-x1.temp-targets"
  printf 'old\n' > "$c/wt/old.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'recorded unlinked teardown failed'
  [ ! -e "$made" ] || fail 'a recorded temporary directory no link reaches survived'
  [ ! -e "$c/wt/old.log" ] || fail 'recorded unlinked cleanup left worktree output'
  grep -Fq "'$(real_path "$c")/made-by-task'" "$c/out" || fail 'cleanup line did not name the removed recorded directory'
  pass 'a recorded temporary directory is removed even when no worktree link reaches it'
}

test_cleanup_recorded_parent() {
  local c made
  c=$(cleanup_fixture recorded-parent)
  made="$c/friday-search-updates-scope"
  mkdir -p "$made/target/debug" "$made/notes"
  printf 'build\n' > "$made/target/debug/object"
  printf 'notes\n' > "$made/notes/scratch.bin"
  printf '%s\n' "$made" > "$c/state/task-x1.temp-targets"
  ln -s "$made/target" "$c/wt/target"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'recorded parent teardown failed'
  [ ! -e "$made" ] || fail 'the recorded parent of a linked target survived'
  [ ! -L "$c/wt/target" ] || fail 'link into the recorded parent survived'
  ! grep -q 'kept temporary' "$c/out" || fail 'cleanup reported a removed recorded directory as kept'
  pass 'a recorded parent holding a linked target and notes is removed whole'
}

test_cleanup_recorded_protections() {
  local c
  c=$(cleanup_fixture recorded-protections)
  fm_git_init_commit "$c/cloned-repo"
  printf 'unpushed\n' > "$c/cloned-repo/work"
  mkdir -p "$c/wt/node_modules"
  printf 'dependency\n' > "$c/wt/node_modules/installed"
  printf '%s\n' "$c/cloned-repo" "$c" "$c/wt" "$c/wt/node_modules" > "$c/state/task-x1.temp-targets"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'recorded protections teardown failed'
  [ -f "$c/cloned-repo/work" ] || fail 'cleanup removed a recorded git repository'
  [ -f "$c/wt/node_modules/installed" ] || fail 'cleanup removed a kept worktree path through the record'
  [ -f "$c/wt/build/source" ] || fail 'cleanup removed tracked worktree source through the record'
  grep -Fq "kept temporary targets: '$(real_path "$c/cloned-repo")' (~" "$c/out" \
    || fail 'cleanup line did not name the kept recorded repository'
  ! sed 's/; freed.*//' "$c/out" | grep -Fq 'cloned-repo' || fail 'cleanup line named a kept recorded repository as removed'
  pass 'recorded directories keep the temporary-root, worktree and repository protections'
}

test_cleanup_record_user_temp() {
  local c
  c=$(cleanup_fixture record-user-temp)
  mkdir -p "$c/user-temp/T/other-task"
  printf 'other\n' > "$c/user-temp/T/other-task/data"
  printf '%s\n' "$c/user-temp/T" > "$c/state/task-x1.temp-targets"
  TMPDIR="$c/user-temp/T/" run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'user temp record teardown failed'
  [ -f "$c/user-temp/T/other-task/data" ] || fail 'a record naming TMPDIR removed the whole user temporary directory'
  c=$(cleanup_fixture record-user-temp-parent)
  mkdir -p "$c/user-temp/T/other-task"
  printf 'other\n' > "$c/user-temp/T/other-task/data"
  printf '%s\n' "$c/user-temp" > "$c/state/task-x1.temp-targets"
  TMPDIR="$c/user-temp/T" run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'user temp parent record teardown failed'
  [ -f "$c/user-temp/T/other-task/data" ] || fail 'a record naming a parent of TMPDIR removed the user temporary directory'
  c=$(cleanup_fixture record-no-tmpdir)
  mkdir -p "$c/made-by-task"
  printf 'build\n' > "$c/made-by-task/object"
  printf '%s\n' "$c/made-by-task" > "$c/state/task-x1.temp-targets"
  ( unset TMPDIR; run_teardown "$c" ) > "$c/out" 2> "$c/err" || fail 'record teardown without TMPDIR failed'
  [ ! -e "$c/made-by-task" ] || fail 'a recorded directory survived when TMPDIR is unset'
  pass 'a record never removes the user temporary directory or a directory holding it'
}

test_cleanup_recorded_writer() {
  local c made pid
  c=$(cleanup_fixture recorded-writer)
  made="$c/made-by-task"
  mkdir -p "$made/work"
  printf 'object\n' > "$made/work/object"
  printf '%s\n' "$made" > "$c/state/task-x1.temp-targets"
  pid=$(start_worktree_writer "$c" flush "$made/work")
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'recorded writer teardown failed'
  ! process_running "$pid" || fail 'a process working inside a recorded temporary directory survived teardown'
  [ ! -e "$made" ] || fail 'output a recorded-directory writer flushed on shutdown survived cleanup'
  pass 'processes inside a recorded temporary directory stop before it is removed'
}

test_cleanup_recorded_writer_protections() {
  local c repo holder user_temp
  c=$(cleanup_fixture recorded-writer-protections)
  fm_git_init_commit "$c/cloned-repo"
  printf '%s\n' "$c/cloned-repo" "$c" > "$c/state/task-x1.temp-targets"
  repo=$(start_worktree_writer "$c" stubborn "$c/cloned-repo")
  holder=$(start_worktree_writer "$c" stubborn "$c")
  FM_WORKTREE_CLEANUP_STOP_GRACE_SECS=0.2 run_teardown "$c" > "$c/out" 2> "$c/err" \
    || fail 'recorded writer protections teardown failed'
  process_running "$repo" || fail 'cleanup stopped a process inside a recorded repository it keeps'
  process_running "$holder" || fail 'cleanup stopped a process inside a recorded directory holding the worktree'
  kill -KILL "$repo" "$holder"
  c=$(cleanup_fixture recorded-writer-user-temp)
  mkdir -p "$c/user-temp/T/other-task"
  printf '%s\n' "$c/user-temp/T" > "$c/state/task-x1.temp-targets"
  user_temp=$(start_worktree_writer "$c" stubborn "$c/user-temp/T/other-task")
  TMPDIR="$c/user-temp/T" FM_WORKTREE_CLEANUP_STOP_GRACE_SECS=0.2 run_teardown "$c" > "$c/out" 2> "$c/err" \
    || fail 'recorded user temp writer teardown failed'
  process_running "$user_temp" || fail 'cleanup stopped a process inside the user temporary directory'
  kill -KILL "$user_temp"
  pass 'cleanup never stops processes in recorded paths it does not remove'
}

test_cleanup_ignored_only_directory() {
  local c
  c=$(cleanup_fixture ignored-only-directory)
  mkdir -p "$c/wt/evidence"
  printf 'run\n' > "$c/wt/evidence/run.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'ignored-only directory teardown failed'
  [ ! -e "$c/wt/evidence" ] || fail 'untracked directory of ignored files survived'
  ! grep -q 'failed:' "$c/out" || fail "cleanup reported a path it had already removed as failed: $(cat "$c/out")"
  ! grep -q 'ignored cleanup incomplete' "$c/err" || fail 'teardown warned about leftovers after a complete cleanup'
  pass 'a directory git lists with its own ignored files is removed once and reported clean'
}

test_cleanup_kept_listed_children() {
  local c
  c=$(cleanup_fixture kept-listed-children)
  printf '%s\n' .claude/notes.local.md 'Pods/*.lock' >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  mkdir -p "$c/wt/.claude" "$c/wt/Pods"
  printf 'local config\n' > "$c/wt/.claude/notes.local.md"
  printf 'pods\n' > "$c/wt/Pods/Manifest.lock"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'kept listed children teardown failed'
  [ -f "$c/wt/.claude/notes.local.md" ] || fail 'cleanup removed ignored local agent config inside a kept directory'
  [ -f "$c/wt/Pods/Manifest.lock" ] || fail 'cleanup removed ignored files inside a kept dependency install'
  pass 'ignored files git lists inside a kept directory stay with it'
}

# A tracked file makes git list the ignored entries beside it one by one.
cleanup_track() {
  local c=$1; shift
  git -C "$c/wt" add -f -- "$@"
  git -C "$c/wt" commit -qm 'track a file inside a kept directory'
  git -C "$c/project" update-ref refs/heads/main "$(git -C "$c/wt" rev-parse HEAD)"
}

test_cleanup_rails_keys() {
  local c mode name
  for mode in worktree free-slot; do
    c=$(cleanup_fixture "rails-keys-$mode")
    printf '%s\n' config/master.key 'config/credentials/*.key' config/settings.local.yml tmp/other.key \
      >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
    mkdir -p "$c/wt/config/credentials" "$c/wt/log" "$c/wt/tmp"
    printf 'encrypted development\n' > "$c/wt/config/credentials/development.yml.enc"
    printf 'encrypted production\n' > "$c/wt/config/credentials/production.yml.enc"
    cleanup_track "$c" config/credentials/development.yml.enc config/credentials/production.yml.enc
    for name in master.key credentials/development.key credentials/production.key; do
      printf 'fixture key\n' > "$c/wt/config/$name"
    done
    printf 'old log\n' > "$c/wt/log/test.log"
    printf 'fixture setting\n' > "$c/wt/config/settings.local.yml"
    printf 'fixture other key\n' > "$c/wt/tmp/other.key"
    if [ "$mode" = worktree ]; then
      "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$c/wt" "" > "$c/out" 2> "$c/err" \
        || fail 'Rails keys worktree cleanup failed'
    else
      cleanup_free_fixture "$c"
      run_cleanup_free "$c" > "$c/out" 2> "$c/err" || fail 'Rails keys free-slot cleanup failed'
    fi
    for name in master.key credentials/development.key credentials/production.key; do
      [ "$(cat "$c/wt/config/$name" 2>/dev/null)" = 'fixture key' ] \
        || fail "$mode cleanup removed or changed config/$name"
    done
    for name in log/test.log config/settings.local.yml tmp/other.key; do
      [ ! -e "$c/wt/$name" ] || fail "$mode Rails keys cleanup left ignored $name"
    done
  done
  pass 'both cleanup modes keep only Rails keys and remove ignored logs, config siblings and other keys'
}

test_cleanup_tracked_agent_config() {
  local c
  c=$(cleanup_fixture tracked-agent-config)
  printf '%s\n' .claude >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  mkdir -p "$c/wt/.claude/hooks" "$c/wt/.claude/skills/mine" "$c/wt/.claude/skills/shared"
  printf '{}\n' > "$c/wt/.claude/settings.json"
  printf 'shared skill\n' > "$c/wt/.claude/skills/shared/SKILL.md"
  cleanup_track "$c" .claude/settings.json .claude/skills/shared/SKILL.md
  printf 'hook\n' > "$c/wt/.claude/hooks/local-hook.sh"
  printf 'skill\n' > "$c/wt/.claude/skills/mine/SKILL.md"
  printf 'old\n' > "$c/wt/old.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'tracked agent config teardown failed'
  [ -f "$c/wt/.claude/hooks/local-hook.sh" ] || fail 'cleanup removed a local hook beside tracked .claude/settings.json'
  [ -f "$c/wt/.claude/skills/mine/SKILL.md" ] || fail 'cleanup removed a local skill beside a tracked .claude skill'
  [ -f "$c/wt/.claude/settings.json" ] || fail 'cleanup removed tracked .claude/settings.json'
  [ ! -e "$c/wt/old.log" ] || fail 'tracked agent config cleanup left worktree output'
  pass 'local agent config beside a tracked .claude file stays'
}

test_cleanup_tracked_codex_config() {
  local c
  c=$(cleanup_fixture tracked-codex-config)
  printf '%s\n' .codex >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  mkdir -p "$c/wt/.codex"
  printf 'model = "x"\n' > "$c/wt/.codex/config.toml"
  cleanup_track "$c" .codex/config.toml
  printf 'notes\n' > "$c/wt/.codex/local-notes.md"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'tracked codex config teardown failed'
  [ -f "$c/wt/.codex/local-notes.md" ] || fail 'cleanup removed local notes beside tracked .codex/config.toml'
  [ -f "$c/wt/.codex/config.toml" ] || fail 'cleanup removed tracked .codex/config.toml'
  pass 'local notes beside a tracked .codex file stay'
}

test_cleanup_tracked_dependency_install() {
  local c
  c=$(cleanup_fixture tracked-dependency-install)
  mkdir -p "$c/wt/node_modules/pkg" "$c/wt/node_modules/other"
  printf '{}\n' > "$c/wt/node_modules/pkg/package.json"
  cleanup_track "$c" node_modules/pkg/package.json
  printf 'module\n' > "$c/wt/node_modules/other/index.js"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'tracked dependency install teardown failed'
  [ -f "$c/wt/node_modules/other/index.js" ] || fail 'cleanup removed a dependency beside tracked node_modules/pkg/package.json'
  [ -f "$c/wt/node_modules/pkg/package.json" ] || fail 'cleanup removed tracked node_modules/pkg/package.json'
  pass 'a dependency install beside a tracked node_modules file stays'
}

test_cleanup_tracked_nested_project() {
  local c
  c=$(cleanup_fixture tracked-nested-project)
  printf '%s\n' .claude >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  mkdir -p "$c/wt/apps/web/.claude/hooks" "$c/wt/apps/web/node_modules/pkg" "$c/wt/apps/web/node_modules/other"
  printf '{}\n' > "$c/wt/apps/web/.claude/settings.json"
  printf '{}\n' > "$c/wt/apps/web/node_modules/pkg/package.json"
  cleanup_track "$c" apps/web/.claude/settings.json apps/web/node_modules/pkg/package.json
  printf 'hook\n' > "$c/wt/apps/web/.claude/hooks/h.sh"
  printf 'notes\n' > "$c/wt/apps/web/.claude/notes.md"
  printf 'module\n' > "$c/wt/apps/web/node_modules/other/index.js"
  printf 'old\n' > "$c/wt/old.log"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'tracked nested project teardown failed'
  [ -f "$c/wt/apps/web/.claude/hooks/h.sh" ] || fail 'cleanup removed a local hook beside tracked apps/web/.claude/settings.json'
  [ -f "$c/wt/apps/web/.claude/notes.md" ] || fail 'cleanup removed local notes beside tracked apps/web/.claude/settings.json'
  [ -f "$c/wt/apps/web/node_modules/other/index.js" ] || fail 'cleanup removed a dependency beside tracked apps/web/node_modules/pkg/package.json'
  [ -f "$c/wt/apps/web/.claude/settings.json" ] || fail 'cleanup removed tracked apps/web/.claude/settings.json'
  [ -f "$c/wt/apps/web/node_modules/pkg/package.json" ] || fail 'cleanup removed tracked apps/web/node_modules/pkg/package.json'
  [ ! -e "$c/wt/old.log" ] || fail 'tracked nested project cleanup left worktree output'
  pass 'local files beside tracked files in a nested project stay'
}

test_cleanup_deps_contexts() {
  local c
  c=$(cleanup_fixture deps-contexts)
  mkdir -p "$c/wt/build/node/deps" "$c/wt/build/node/cargo/deps" "$c/wt/tools/build/deps" \
    "$c/wt/tools/build/cargo/debug/deps"
  printf 'dependency\n' > "$c/wt/build/node/deps/installed"
  printf 'dependency\n' > "$c/wt/build/node/cargo/deps/installed"
  printf 'dependency\n' > "$c/wt/tools/build/deps/installed"
  printf 'test binary\n' > "$c/wt/tools/build/cargo/debug/deps/fri37_test-abcd"
  run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'deps contexts teardown failed'
  [ -f "$c/wt/build/node/deps/installed" ] || fail 'cleanup removed build/node/deps, which is not a named compiler context'
  [ -f "$c/wt/tools/build/deps/installed" ] || fail 'cleanup removed tools/build/deps, which is not a named compiler context'
  [ -f "$c/wt/build/node/cargo/deps/installed" ] || fail 'cleanup removed build/node/cargo/deps, which is not below build/cargo'
  [ ! -e "$c/wt/tools/build/cargo" ] || fail 'cleanup kept compiler deps in a nested build/cargo/debug/deps'
  pass 'deps goes only below target or build/cargo'
}

nested_fixture() {
  local c
  c=$(make_case "nested-$1")
  c=$(cd "$c" && pwd -P)
  write_meta "$c" no-mistakes ship
  printf '%s\n' '.claude/worktrees/' 'tmp/' >> "$(git -C "$c/wt" rev-parse --git-path info/exclude)"
  git -C "$c/project" worktree add -q -b nested "$c/wt/.claude/worktrees/inner copy" main
  cat > "$c/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NESTED_CASE:?}/returns"
if [ -e "$NESTED_CASE/wt/.claude/worktrees/inner copy/.git" ]; then
  echo 'nested worktree still present at return' >&2
  exit 1
fi
SH
  chmod +x "$c/fakebin/treehouse"
  printf '%s\n' "$c"
}

test_nested_landed() {
  local c inner deep sibling
  c=$(nested_fixture landed)
  nested_tracked_fixture "$c"
  inner="$c/wt/.claude/worktrees/inner copy"
  deep="$inner/tmp/deeper"
  sibling="$c/wt-other"
  git -C "$inner" worktree add -q --detach "$deep" main
  git -C "$c/project" worktree add -q --detach "$sibling" main
  cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-} ${4:-}" = 'worktree remove' ]; then
  printf '%s\n' "$6" >> "${NESTED_CASE:?}/removals"
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$c/fakebin/git"
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'landed nested worktrees prevented return'
  [ ! -e "$inner" ] && [ ! -e "$deep" ] || fail 'landed nested paths survived'
  [ -f "$sibling/.git" ] || fail 'prefix sibling was removed'
  git -C "$c/project" worktree list --porcelain > "$c/list"
  if grep -F "$inner" "$c/list"; then fail 'nested registration survived'; fi
  [ -s "$c/returns" ] || fail 'slot was not returned'
  printf '%s\n%s\n' "$deep" "$inner" > "$c/expected-removals"
  cmp -s "$c/expected-removals" "$c/removals" || {
    diff -u "$c/expected-removals" "$c/removals"
    fail 'nested copies were not removed deepest first'
  }
  pass 'landed nested copies are removed deepest first before return; sibling stays'
}

test_nested_squash() {
  local c inner unique rc=0
  c=$(nested_fixture squash)
  inner="$c/wt/.claude/worktrees/inner copy"
  printf 'landed\n' > "$inner/feature"
  git -C "$inner" add feature
  git -C "$inner" commit -qm 'nested feature'
  unique=$(git -C "$inner" rev-parse HEAD)
  land_on_origin_main "$c" feature landed
  "$TEARDOWN" --check-default-content "$c/project" "$inner" || fail 'nested squash content proof changed'
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'nested squash-only history unexpectedly allowed return'
  [ -f "$inner/.git" ] && [ ! -e "$c/returns" ] || fail 'nested squash-only history was discarded'
  grep -F "$unique" "$c/err" >/dev/null || fail 'squash-only history refusal did not name retained commit'
  pass 'nested squash content remains proven but history outside default reachability refuses'
}

test_nested_refusal() {
  local variant=$1 c inner rc=0
  c=$(nested_fixture "$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  case "$variant" in
    unlanded|pushed|forced)
      printf 'unique\n' > "$inner/feature"
      git -C "$inner" add feature
      git -C "$inner" commit -qm 'nested only'
      if [ "$variant" = pushed ]; then git -C "$inner" push -q origin nested; fi
      ;;
    dirty) printf 'notes\n' > "$inner/notes" ;;
    agent-dirty) mkdir -p "$inner/.claude"; printf 'notes\n' > "$inner/.claude/notes" ;;
    unknown) git -C "$c/project" remote set-url origin "$c/unreachable.git" ;;
    locked) git -C "$c/project" worktree lock "$inner" ;;
    missing) mv "$inner" "$c/moved-inner" ;;
    mixed)
      git -C "$c/project" worktree add -q --detach "$c/wt/.claude/worktrees/a-landed" main
      printf 'unique\n' > "$inner/feature"
      git -C "$inner" add feature
      git -C "$inner" commit -qm 'nested only'
      ;;
    inventory)
      cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'worktree list --porcelain -z'*) exit 1 ;;
esac
exec "$REAL_GIT_FOR_TEST" "$@"
SH
      chmod +x "$c/fakebin/git"
      ;;
  esac
  if [ "$variant" = forced ]; then
    NESTED_CASE="$c" run_teardown "$c" --force > "$c/out" 2> "$c/err" || rc=$?
  else
    NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "nested $variant unexpectedly allowed return"
  [ -f "$c/state/task-x1.meta" ] || fail "nested $variant erased task identity"
  [ ! -e "$c/returns" ] || fail "nested $variant attempted slot return"
  if [ "$variant" = inventory ]; then
    grep -F 'cannot list nested worktrees' "$c/err" >/dev/null || fail 'inventory failure was not explained'
  elif [ "$variant" = mixed ]; then
    if ! grep -F "REFUSED: nested worktree $inner" "$c/err" >/dev/null \
      && ! grep -F "REFUSED: nested worktree $c/wt/.claude/worktrees/a-landed" "$c/err" >/dev/null; then
      fail 'nested mixed refusal did not name an inspected copy'
    fi
  else
    grep -F "$inner" "$c/err" >/dev/null || fail "nested $variant refusal did not name path"
  fi
  if [ "$variant" = mixed ]; then [ -f "$c/wt/.claude/worktrees/a-landed/.git" ] || fail 'removed a landed peer before all verdicts passed'; fi
  if [ "$variant" != missing ]; then [ -f "$inner/.git" ] || fail "nested $variant was discarded"; fi
  case "$variant" in
    dirty|agent-dirty)
      grep -F "REFUSED: nested worktree $inner has uncommitted changes." "$c/err" >/dev/null \
        || fail 'nested dirty changes reached removal instead of the safety refusal'
      ;;
  esac
  if [ "$variant" = unknown ]; then
    grep -F 'could not be fetched' "$c/err" >/dev/null || fail 'unknown default did not explain failed check'
  fi
  pass "nested $variant refuses and preserves task before return"
}

nested_tracked_fixture() {
  local c=$1 inner
  inner="$c/wt/.claude/worktrees/inner copy"
  printf 'base\n' > "$inner/tracked"
  git -C "$inner" add tracked
  git -C "$inner" commit -qm 'landed tracked file'
  git -C "$inner" push -q origin HEAD:main
}

test_nested_private() {
  local variant=$1 c inner rc=0
  c=$(nested_fixture "$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  case "$variant" in
    skip-worktree|assume-unchanged)
      nested_tracked_fixture "$c"
      git -C "$inner" update-index "--$variant" tracked
      printf 'unpublished tracked bytes\n' > "$inner/tracked"
      ;;
    env|notes|rails-key|dependency|empty-dependency)
      printf '%s\n' '.env' '.claude/' 'config/' 'node_modules/' >> "$(git -C "$inner" rev-parse --git-path info/exclude)"
      case "$variant" in
        env) printf 'private fixture\n' > "$inner/.env" ;;
        notes) mkdir -p "$inner/apps/web/.claude"; printf 'private fixture\n' > "$inner/apps/web/.claude/notes.md" ;;
        rails-key) mkdir -p "$inner/config/credentials"; printf 'private fixture\n' > "$inner/config/credentials/development.key" ;;
        dependency) mkdir -p "$inner/node_modules/pkg"; printf 'private fixture\n' > "$inner/node_modules/pkg/index.js" ;;
        empty-dependency) mkdir -p "$inner/node_modules/pkg" ;;
      esac
      ;;
    status-unreadable|flags-unreadable|ignored-unreadable|head-unreadable)
      cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = "$NESTED_CASE/wt/.claude/worktrees/inner copy" ]; then
  case "$NESTED_VARIANT:$*" in
    status-unreadable:*'status --porcelain'*|flags-unreadable:*'ls-files -v -z'*|ignored-unreadable:*'ls-files --others --ignored'*|head-unreadable:*'rev-parse --verify HEAD'*) exit 1 ;;
  esac
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
      chmod +x "$c/fakebin/git"
      ;;
  esac
  [ -z "$(git -C "$inner" status --porcelain)" ] || fail "nested $variant fixture is visibly dirty"
  NESTED_CASE="$c" NESTED_VARIANT="$variant" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "nested $variant unexpectedly allowed return"
  [ -f "$inner/.git" ] || fail "nested $variant copy was discarded"
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail "nested $variant changed task or returned slot"
  grep -F "$inner" "$c/err" >/dev/null || fail "nested $variant refusal did not name copy"
  case "$variant" in
    skip-worktree|assume-unchanged) [ "$(cat "$inner/tracked")" = 'unpublished tracked bytes' ] || fail 'hidden edit changed' ;;
    env) [ "$(cat "$inner/.env")" = 'private fixture' ] || fail 'private env changed' ;;
    notes) [ "$(cat "$inner/apps/web/.claude/notes.md")" = 'private fixture' ] || fail 'private notes changed' ;;
    rails-key) [ "$(cat "$inner/config/credentials/development.key")" = 'private fixture' ] || fail 'private key changed' ;;
    dependency) [ "$(cat "$inner/node_modules/pkg/index.js")" = 'private fixture' ] || fail 'dependency changed' ;;
    empty-dependency) [ -d "$inner/node_modules/pkg" ] || fail 'empty retained directory changed' ;;
  esac
  pass "nested $variant refuses and preserves unpublished or uninspectable copy"
}

test_nested_disposable() {
  local c inner
  c=$(nested_fixture disposable)
  inner="$c/wt/.claude/worktrees/inner copy"
  printf '*.log\n' >> "$(git -C "$inner" rev-parse --git-path info/exclude)"
  printf 'discardable\n' > "$inner/build.log"
  git init -q "$c/linked-repository"
  printf 'private linked data\n' > "$c/linked-repository/.env"
  ln -s "$c/linked-repository" "$inner/tmp-link"
  printf 'tmp-link\n' >> "$(git -C "$inner" rev-parse --git-path info/exclude)"
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || fail 'disposable ignored output blocked nested cleanup'
  [ ! -e "$inner" ] && [ -s "$c/returns" ] || fail 'disposable ignored output prevented return'
  [ "$(cat "$c/linked-repository/.env")" = 'private linked data' ] || fail 'nested inspection followed or changed a symlink target'
  pass 'nested disposable ignored output follows existing retention contract without following links'
}

test_nested_changed() {
  local variant=$1 c inner rc=0
  c=$(nested_fixture "changed-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  nested_tracked_fixture "$c"
  git -C "$inner" checkout -q --detach
  printf '.env\n' >> "$(git -C "$inner" rev-parse --git-path info/exclude)"
  cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
inner="$NESTED_CASE/wt/.claude/worktrees/inner copy"
if [ "${2:-}" = "$inner" ] && [ "${3:-} ${4:-}" = 'merge-tree --write-tree' ] && [ ! -e "$NESTED_CASE/interleaved" ]; then
  "$REAL_GIT_FOR_TEST" "$@" || exit $?
  "$REAL_GIT_FOR_TEST" -C "$inner" rev-parse HEAD > "$NESTED_CASE/proven-head"
  case "$NESTED_VARIANT" in
    head)
      printf 'late unpublished content\n' > "$inner/late-feature"
      "$REAL_GIT_FOR_TEST" -C "$inner" add late-feature
      "$REAL_GIT_FOR_TEST" -C "$inner" commit -qm 'late nested work'
      ;;
    dirty) printf 'late unpublished content\n' > "$inner/tracked" ;;
    skip-worktree|assume-unchanged)
      "$REAL_GIT_FOR_TEST" -C "$inner" update-index "--$NESTED_VARIANT" tracked
      printf 'late unpublished content\n' > "$inner/tracked"
      ;;
    ignored) printf 'late unpublished content\n' > "$inner/.env" ;;
    hidden-untracked)
      "$REAL_GIT_FOR_TEST" -C "$inner" config status.showUntrackedFiles no
      printf 'late unpublished content\n' > "$inner/notes.txt"
      ;;
    repository)
      "$REAL_GIT_FOR_TEST" init -q "$inner/tmp/foreign"
      printf 'late unpublished content\n' > "$inner/tmp/foreign/data"
      ;;
  esac
  "$REAL_GIT_FOR_TEST" -C "$inner" rev-parse HEAD > "$NESTED_CASE/late-head"
  touch "$NESTED_CASE/interleaved"
  exit 0
fi
if [ "${2:-}" = "$inner" ] && [ -e "$NESTED_CASE/interleaved" ] && [ "$NESTED_VARIANT" = head-unreadable ] && [ "${3:-} ${4:-} ${5:-}" = 'rev-parse --verify HEAD' ]; then
  exit 1
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$c/fakebin/git"
  NESTED_CASE="$c" NESTED_VARIANT="$variant" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ -f "$c/interleaved" ] || fail "nested changed $variant did not reach controlled interleaving"
  [ "$rc" -ne 0 ] || fail "nested changed $variant unexpectedly allowed return"
  [ -f "$inner/.git" ] || fail "nested changed $variant copy was discarded"
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail "nested changed $variant changed task or returned slot"
  grep -F "REFUSED: nested worktree $inner" "$c/err" >/dev/null || fail "nested changed $variant missed early refusal"
  case "$variant" in
    head)
      [ "$(cat "$c/proven-head")" != "$(cat "$c/late-head")" ] || fail 'controlled commit did not advance HEAD'
      [ "$(git -C "$inner" rev-parse HEAD)" = "$(cat "$c/late-head")" ] || fail 'late detached HEAD lost'
      [ "$(cat "$inner/late-feature")" = 'late unpublished content' ] || fail 'late file lost'
      [ -n "$(git -C "$inner" reflog --format=%H)" ] || fail 'late detached reflog lost'
      if git -C "$c/project" merge-base --is-ancestor "$(cat "$c/late-head")" origin/main; then fail 'late commit unexpectedly landed'; fi
      ;;
    dirty|skip-worktree|assume-unchanged) [ "$(cat "$inner/tracked")" = 'late unpublished content' ] || fail 'late tracked bytes lost' ;;
    ignored) [ "$(cat "$inner/.env")" = 'late unpublished content' ] || fail 'late ignored bytes lost' ;;
    hidden-untracked) [ "$(cat "$inner/notes.txt")" = 'late unpublished content' ] || fail 'late hidden untracked bytes lost' ;;
    repository) [ "$(cat "$inner/tmp/foreign/data")" = 'late unpublished content' ] || fail 'late repository bytes lost' ;;
  esac
  pass "nested changed $variant refuses after controlled proof/removal interleaving"
}

test_nested_recreated_candidate() {
  local c inner deep rc=0
  c=$(nested_fixture recreated-candidate)
  inner="$c/wt/.claude/worktrees/inner copy"
  deep="$inner/tmp/deeper"
  git -C "$c/project" worktree add -q --detach "$deep" main
  cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
deep="$NESTED_CASE/wt/.claude/worktrees/inner copy/tmp/deeper"
if [ "${3:-} ${4:-}" = 'worktree remove' ] && [ "${6:-}" = "$deep" ]; then
  "$REAL_GIT_FOR_TEST" "$@" || exit $?
  mkdir -p "$deep"
  printf 'new retained data\n' > "$deep/.env"
  exit 0
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$c/fakebin/git"
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'a removed candidate path hid new retained data from final inspection'
  [ ! -e "$deep/.git" ] || fail 'recreated fixture never removed the proven descendant'
  [ -f "$inner/.git" ] && [ "$(cat "$deep/.env")" = 'new retained data' ] || fail 'new data in removed candidate path was lost'
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail 'recreated candidate changed task or returned slot'
  grep -F "$deep/.env" "$c/err" >/dev/null || fail 'final retention refusal did not name new data'
  pass 'final parent inspection retains new data at an already removed candidate path'
}

test_nested_repository_retention() {
  local variant=$1 c inner foreign foreign_head rc=0
  c=$(nested_fixture "repository-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  foreign="$inner/tmp/foreign"
  if [ "$variant" = standalone ]; then
    git init -q "$foreign"
    git -C "$foreign" commit -qm baseline --allow-empty
  else
    git init -q "$c/foreign-primary"
    git -C "$c/foreign-primary" commit -qm baseline --allow-empty
    git -C "$c/foreign-primary" worktree add -q --detach "$foreign"
  fi
  printf 'unique foreign data\n' > "$foreign/unlanded"
  git -C "$foreign" add unlanded
  git -C "$foreign" commit -qm unique
  foreign_head=$(git -C "$foreign" rev-parse HEAD)
  printf 'unique unpublished foreign edits\n' > "$foreign/unlanded"
  "$ROOT/bin/fm-worktree-cleanup.sh" --worktree "$inner" "" > "$c/cleanup-out" 2> "$c/cleanup-err" \
    || fail 'existing cleanup failed on repository fixture'
  [ "$(cat "$foreign/unlanded")" = 'unique unpublished foreign edits' ] || fail 'outer cleanup removed retained repository'
  [ -z "$(git -C "$inner" status --porcelain)" ] || fail 'foreign repository fixture is visibly dirty'
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "nested $variant repository unexpectedly allowed return"
  [ -f "$inner/.git" ] && [ -e "$foreign/.git" ] || fail 'retained repository was discarded'
  [ "$(git -C "$foreign" rev-parse HEAD)" = "$foreign_head" ] || fail 'retained repository HEAD changed'
  [ "$(cat "$foreign/unlanded")" = 'unique unpublished foreign edits' ] || fail 'retained repository dirty bytes changed'
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail 'repository refusal changed task or returned slot'
  grep -F "$inner" "$c/err" >/dev/null || fail 'repository refusal did not name nested copy'
  grep -F "$foreign" "$c/err" >/dev/null || fail 'repository refusal did not name retained item'
  pass "nested $variant repository follows shared cleanup retention and preserves HEAD and dirty bytes"
}

test_nested_hidden_untracked() {
  local c inner rc=0
  c=$(nested_fixture hidden-untracked)
  inner="$c/wt/.claude/worktrees/inner copy"
  git -C "$inner" config status.showUntrackedFiles no
  printf 'unique unpublished untracked work\n' > "$inner/notes.txt"
  [ -z "$(git -C "$inner" status --porcelain)" ] || fail 'hidden untracked fixture is visibly dirty'
  [ "$(git -C "$inner" status --porcelain --untracked-files=all)" = '?? notes.txt' ] || fail 'explicit status did not expose fixture'
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'hidden untracked work unexpectedly allowed return'
  [ -f "$inner/.git" ] && [ "$(cat "$inner/notes.txt")" = 'unique unpublished untracked work' ] || fail 'hidden untracked bytes lost'
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail 'hidden untracked refusal changed task or returned slot'
  grep -F "REFUSED: nested worktree $inner has uncommitted changes." "$c/err" >/dev/null || fail 'hidden untracked work missed early refusal'
  pass 'nested status inspects all untracked files independent of Git configuration'
}

test_nested_plan_retention() {
  local variant=$1 c inner deep safe='' rc=0
  c=$(nested_fixture "plan-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  deep="$inner/tmp/deeper"
  git -C "$c/project" worktree add -q --detach "$deep" main
  case "$variant" in
    unlanded|kept-child)
      safe="$inner/tmp/a-landed-longer"
      git -C "$c/project" worktree add -q --detach "$safe" main
      ;;
  esac
  case "$variant" in
    unlanded)
      printf 'unlanded descendant\n' > "$deep/unique"
      git -C "$deep" add unique
      git -C "$deep" commit -qm 'unlanded descendant'
      ;;
    kept-child) printf 'private descendant\n' > "$deep/.env"; printf '.env\n' >> "$(git -C "$deep" rev-parse --git-path info/exclude)" ;;
    kept-sibling) mkdir -p "$inner/tmp/deeper-other"; printf 'private sibling\n' > "$inner/tmp/deeper-other/.env" ;;
    out-of-plan)
      cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-} ${4:-} ${5:-} ${6:-}" = 'worktree list --porcelain -z' ]; then
  "$REAL_GIT_FOR_TEST" "$@" | python3 -c 'import os, sys
excluded = os.fsencode(os.environ["NESTED_CASE"] + "/wt/.claude/worktrees/inner copy/tmp/deeper")
for record in sys.stdin.buffer.read().split(b"\0\0"):
    if record and record.split(b"\0")[0] != b"worktree " + excluded:
        sys.stdout.buffer.write(record + b"\0\0")'
  exit "${PIPESTATUS[0]}"
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
      chmod +x "$c/fakebin/git"
      ;;
  esac
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "nested plan $variant unexpectedly allowed return"
  [ -z "$safe" ] || [ -f "$safe/.git" ] || fail "nested plan $variant removed a safe peer before all proofs passed"
  [ -f "$inner/.git" ] && [ -f "$deep/.git" ] || fail "nested plan $variant removed a candidate before all proofs passed"
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail "nested plan $variant changed task or returned slot"
  case "$variant" in
    unlanded) [ "$(cat "$deep/unique")" = 'unlanded descendant' ] || fail 'unlanded descendant bytes changed' ;;
    kept-child) [ "$(cat "$deep/.env")" = 'private descendant' ] || fail 'kept descendant bytes changed' ;;
    kept-sibling) [ "$(cat "$inner/tmp/deeper-other/.env")" = 'private sibling' ] || fail 'kept sibling bytes changed' ;;
    out-of-plan) grep -F "$deep" "$c/err" >/dev/null || fail 'out-of-plan repository was not named by retention refusal' ;;
  esac
  pass "nested plan $variant preserves every candidate and retained item before removal"
}

test_nested_history() {
  local variant=$1 c inner unique gitdir head history_root rc=0
  c=$(nested_fixture "history-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  head=$(git -C "$inner" rev-parse HEAD)
  if [ "$variant" = mixed ]; then git -C "$c/project" worktree add -q --detach "$c/wt/.claude/worktrees/a-landed-peer-longer" main; fi
  history_root=$inner
  case "$variant" in
    other-worktree-ref|other-worktree-reflog|other-worktree-old-side)
      history_root="$c/other copy"
      git -C "$c/project" worktree add -q --detach "$history_root" main
      ;;
  esac
  git -C "$history_root" checkout -q --detach
  case "$variant" in
    reflog-squash|ref-squash) printf '%s\n' 'unique static committed work\n' > "$history_root/unique-work" ;;
    *) printf 'unique static committed work\\n' > "$history_root/unique-work" ;;
  esac
  git -C "$history_root" add unique-work
  git -C "$history_root" commit -qm 'static unpublished detached work'
  unique=$(git -C "$history_root" rev-parse HEAD)
  case "$variant" in
    worktree-ref|ref-only|ref-squash|ref-ancestor|private-ref-reflog|other-worktree-ref)
      git -C "$inner" update-ref refs/worktree/a-landed-peer-longer "$head"
      if [ "$variant" = private-ref-reflog ]; then
        git -C "$history_root" update-ref --create-reflog refs/worktree/saved-work "$unique"
      else
        git -C "$history_root" update-ref refs/worktree/saved-work "$unique"
      fi
      ;;
  esac
  if [ "$variant" = ref-ancestor ]; then
    git -C "$inner" update-ref refs/worktree/saved-work "$(printf 'landed tree after private ancestor\n' | git -C "$inner" commit-tree "$head^{tree}" -p "$unique")"
  fi
  case "$variant" in
    head-old-side|other-worktree-old-side) git -C "$history_root" reflog expire --expire=all HEAD ;;
  esac
  git -C "$history_root" checkout -q --detach main
  if [ "$variant" = private-ref-reflog ]; then
    git -C "$inner" update-ref refs/worktree/saved-work "$head"
  fi
  if [ "$variant" = head-new-side ]; then git -C "$inner" reflog delete 'HEAD@{0}'; fi
  case "$variant" in
    ref-only|ref-squash|ref-ancestor|private-ref-reflog|other-worktree-ref) git -C "$history_root" reflog expire --expire=all HEAD ;;
  esac
  case "$variant" in
    reflog-squash|ref-squash) land_on_origin_main "$c" unique-work 'unique static committed work\n' ;;
    history-unreadable|history-silent-error|history-warning)
      git -C "$inner" push -q origin "$unique:main"
      git -C "$inner" fetch -q origin
      cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = "$NESTED_CASE/wt/.claude/worktrees/inner copy" ] && [ "${3:-} ${4:-} ${5:-}" = 'rev-list --stdin --not' ]; then
  if [ "$NESTED_VARIANT" != history-silent-error ]; then echo 'synthetic unreadable retained history' >&2; fi
  if [ "$NESTED_VARIANT" = history-warning ]; then exit 0; fi
  exit 1
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
      chmod +x "$c/fakebin/git"
      ;;
  esac
  [ -z "$(git -C "$inner" status --porcelain --untracked-files=all)" ] || fail 'history fixture is dirty'
  [ "$(git -C "$inner" rev-parse HEAD)" = "$head" ] || fail 'history fixture HEAD is not landed'
  case "$variant" in
    head-old-side)
      grep -F "$unique $head " "$(git -C "$inner" rev-parse --git-path logs/HEAD)" >/dev/null || fail 'old endpoint fixture missing compact raw entry'
      if git -C "$inner" reflog --format=%H HEAD | grep -qxF "$unique"; then fail 'old endpoint also has a new-endpoint witness'; fi
      ;;
    head-new-side)
      grep -F "$head $unique " "$(git -C "$inner" rev-parse --git-path logs/HEAD)" >/dev/null || fail 'new endpoint fixture missing raw entry'
      if grep -E "^$unique " "$(git -C "$inner" rev-parse --git-path logs/HEAD)"; then fail 'new endpoint also has an old-endpoint witness'; fi
      ;;
    private-ref-reflog)
      [ -z "$(git -C "$inner" reflog --format=%H HEAD)" ] || fail 'private reflog fixture still has HEAD history'
      [ "$(git -C "$inner" rev-parse refs/worktree/saved-work)" = "$head" ] || fail 'private reflog fixture tip is not landed'
      ;;
  esac
  gitdir=$(git -C "$inner" rev-parse --absolute-git-dir)
  git -C "$inner" reflog --format=%H HEAD > "$c/reflog-before"
  git -C "$inner" for-each-ref --format='%(refname) %(objectname)' refs/worktree/ > "$c/refs-before"
  git -C "$inner" show "$unique:unique-work" > "$c/content-before"
  git -C "$inner" rev-list --all --reflog --not origin/main -- > "$c/reachable-before"
  case "$variant" in
    history-unreadable|history-silent-error|history-warning) [ ! -s "$c/reachable-before" ] || fail 'unreadable fixture has unlanded history' ;;
    other-worktree-ref)
      git -C "$history_root" rev-list --all --reflog --not origin/main -- > "$c/other-reachable"
      grep -qxF "$unique" "$c/other-reachable" || fail 'other private ref fixture lost its unique commit'
      if git -C "$history_root" reflog exists refs/worktree/saved-work; then fail 'other private ref fixture has a masking reflog'; fi
      ;;
    *) grep -qxF "$unique" "$c/reachable-before" || fail "Git all-history traversal missed $variant fixture" ;;
  esac
  case "$variant" in
    other-worktree-*)
      git -C "$history_root" rev-list --single-worktree --all --reflog --not origin/main -- > "$c/other-owned-before"
      cp "$(git -C "$history_root" rev-parse --git-path logs/HEAD)" "$c/other-log-before"
      ;;
  esac
  printf 'Git all-history fixture verified: %s %s\n' "$variant" "$unique"
  NESTED_CASE="$c" NESTED_VARIANT="$variant" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?

  case "$variant" in
    other-worktree-*)
      [ "$rc" -eq 0 ] && [ ! -e "$inner" ] && [ -s "$c/returns" ] || fail "unrelated $variant blocked landed candidate"
      [ -f "$history_root/.git" ] || fail 'unrelated history copy disappeared'
      git -C "$history_root" rev-list --single-worktree --all --reflog --not origin/main -- > "$c/other-owned-after"
      cmp -s "$c/other-owned-before" "$c/other-owned-after" || fail 'unrelated reachable history changed'
      cmp -s "$c/other-log-before" "$(git -C "$history_root" rev-parse --git-path logs/HEAD)" || fail 'unrelated HEAD log changed'
      pass "nested history excludes unrelated $variant and returns landed slot"
      return
      ;;
  esac
  [ "$rc" -ne 0 ] || fail "nested history $variant unexpectedly allowed return"
  [ -f "$inner/.git" ] && [ -d "$gitdir" ] || fail "nested history $variant lost copy or private Git data"
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail "nested history $variant changed task or returned slot"
  if [ "$variant" = mixed ]; then
    if ! grep -F "REFUSED: nested worktree $inner" "$c/err" >/dev/null \
      && ! grep -F "REFUSED: nested worktree $c/wt/.claude/worktrees/a-landed-peer-longer" "$c/err" >/dev/null; then
      fail 'history refusal did not name an inspected copy'
    fi
  else
    grep -F "REFUSED: nested worktree $inner" "$c/err" >/dev/null || fail 'history refusal did not name copy'
  fi
  git -C "$inner" reflog --format=%H HEAD > "$c/reflog-after"
  git -C "$inner" for-each-ref --format='%(refname) %(objectname)' refs/worktree/ > "$c/refs-after"
  git -C "$inner" show "$unique:unique-work" > "$c/content-after"
  git -C "$inner" rev-list --all --reflog --not origin/main -- > "$c/reachable-after"
  cmp -s "$c/reachable-before" "$c/reachable-after" || fail 'refused reachable history changed'
  if ! cmp -s "$c/reflog-before" "$c/reflog-after" || ! cmp -s "$c/refs-before" "$c/refs-after" \
    || ! cmp -s "$c/content-before" "$c/content-after"; then
    fail 'refused history changed'
  fi
  if [ "$variant" = mixed ]; then [ -f "$c/wt/.claude/worktrees/a-landed-peer-longer/.git" ] || fail 'history refusal removed a safe peer before all proofs passed'; fi
  case "$variant" in
    history-unreadable|history-silent-error|history-warning) grep -F 'history cannot be inspected' "$c/err" >/dev/null || fail 'unreadable history missed explicit refusal' ;;
    *) grep -F "$unique" "$c/err" >/dev/null || fail 'history refusal did not identify unpublished commit' ;;
  esac
  pass "nested history $variant preserves history outside default reachability"
}

test_nested_history_changed() {
  local variant=$1 c inner head gitdir rc=0
  c=$(nested_fixture "history-changed-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  head=$(git -C "$inner" rev-parse HEAD)
  gitdir=$(git -C "$inner" rev-parse --absolute-git-dir)
  cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
inner="$NESTED_CASE/wt/.claude/worktrees/inner copy"
if [ "${2:-}" = "$inner" ] && [ "${3:-} ${4:-}" = 'status --porcelain' ]; then
  if [ -e "$NESTED_CASE/initial-status" ] && [ ! -e "$NESTED_CASE/late-history" ]; then
    head=$("$REAL_GIT_FOR_TEST" -C "$inner" rev-parse HEAD)
    "$REAL_GIT_FOR_TEST" -C "$inner" checkout -q --detach
    printf 'late private history\n' > "$inner/late-work"
    "$REAL_GIT_FOR_TEST" -C "$inner" add late-work
    "$REAL_GIT_FOR_TEST" -C "$inner" commit -qm 'late private history'
    "$REAL_GIT_FOR_TEST" -C "$inner" rev-parse HEAD > "$NESTED_CASE/late-history"
    if [ "$NESTED_VARIANT" = worktree-ref ]; then
      "$REAL_GIT_FOR_TEST" -C "$inner" update-ref refs/worktree/saved-work "$(cat "$NESTED_CASE/late-history")"
    fi
    "$REAL_GIT_FOR_TEST" -C "$inner" checkout -q --detach "$head"
    if [ "$NESTED_VARIANT" = worktree-ref ]; then "$REAL_GIT_FOR_TEST" -C "$inner" reflog expire --expire=all HEAD; fi
  fi
  touch "$NESTED_CASE/initial-status"
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$c/fakebin/git"
  NESTED_CASE="$c" NESTED_VARIANT="$variant" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  [ -s "$c/late-history" ] || fail 'history change did not reach final file read'
  [ "$rc" -ne 0 ] || fail "nested late $variant history unexpectedly allowed return"
  [ -f "$inner/.git" ] && [ -d "$gitdir" ] || fail 'late history lost copy or private Git data'
  [ "$(git -C "$inner" rev-parse HEAD)" = "$head" ] || fail 'late history changed current HEAD'
  [ "$(git -C "$inner" show "$(cat "$c/late-history"):late-work")" = 'late private history' ] || fail 'late history bytes lost'
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail 'late history refusal returned slot or changed task'
  grep -F "REFUSED: nested worktree $inner" "$c/err" >/dev/null || fail 'late history refusal did not name copy'
  grep -F "$(cat "$c/late-history")" "$c/err" >/dev/null || fail 'late history refusal did not name commit'
  pass "nested late $variant history refuses with unchanged landed HEAD"
}

test_nested_history_context() {
  local variant=$1 c inner other gitdir rc=0
  c=$(nested_fixture "context-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  other="$c/project/other copy"
  gitdir=$(git -C "$inner" rev-parse --absolute-git-dir)
  git -C "$c/project" worktree add -q --detach "$other" main
  case "$variant" in
    missing) mv "$other" "$c/moved-context" ;;
    unlinked) mv "$other/.git" "$c/context-gitfile" ;;
    foreign)
      mv "$other/.git" "$c/context-gitfile"
      git clone -q "$c/origin.git" "$c/replacement"
      mv "$c/replacement/.git" "$other/.git"
      [ -z "$(git -C "$other" rev-list --all --reflog --not origin/main --)" ] || fail 'foreign context history is not landed'
      ;;
  esac
  cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
inner="$NESTED_CASE/wt/.claude/worktrees/inner copy"
other="$NESTED_CASE/project/other copy"
if [ "${2:-}" = "$inner" ] && [ "${3:-} ${4:-}" = 'status --porcelain' ]; then
  if [ -e "$NESTED_CASE/initial-status" ] && [ ! -e "$NESTED_CASE/final-status" ]; then
    touch "$NESTED_CASE/final-status"
    case "$NESTED_VARIANT" in
      late-ref)
        "$REAL_GIT_FOR_TEST" -C "$NESTED_CASE/project" worktree add -q --detach "$NESTED_CASE/late copy" main
        late="$NESTED_CASE/late copy"
        printf 'late context work\n' > "$late/unique-work"
        "$REAL_GIT_FOR_TEST" -C "$late" add unique-work
        "$REAL_GIT_FOR_TEST" -C "$late" commit -qm 'late context work'
        "$REAL_GIT_FOR_TEST" -C "$late" rev-parse HEAD > "$NESTED_CASE/late-commit"
        "$REAL_GIT_FOR_TEST" -C "$late" update-ref refs/worktree/saved-work "$(cat "$NESTED_CASE/late-commit")"
        "$REAL_GIT_FOR_TEST" -C "$late" checkout -q --detach main
        "$REAL_GIT_FOR_TEST" -C "$late" reflog expire --expire=all HEAD
        ;;
      late-missing) mv "$other" "$NESTED_CASE/moved-context" ;;
    esac
  fi
  touch "$NESTED_CASE/initial-status"
fi
if [ "${3:-} ${4:-} ${5:-} ${6:-}" = 'worktree list --porcelain -z' ]; then
  if [ "$NESTED_VARIANT" = inventory-empty ]; then exit 0; fi
  case "$NESTED_VARIANT" in
    inventory-error|inventory-silent-error|inventory-warning|final-inventory-error|final-inventory-warning)
      if [[ "$NESTED_VARIANT" != final-* ]] || [ -e "$NESTED_CASE/final-status" ]; then
        "$REAL_GIT_FOR_TEST" "$@" || exit $?
        if [ "$NESTED_VARIANT" != inventory-silent-error ]; then echo 'synthetic uncertain inventory' >&2; fi
        if [[ "$NESTED_VARIANT" = *warning ]]; then exit 0; fi
        exit 1
      fi
      ;;
  esac
fi
if [ "${2:-}" = "$inner" ]; then
  case "$NESTED_VARIANT:${3:-} ${4:-} ${5:-}" in
    top-error:'rev-parse --show-toplevel ') "$REAL_GIT_FOR_TEST" "$@"; exit 1 ;;
    common-error:'rev-parse --path-format=absolute --git-common-dir') "$REAL_GIT_FOR_TEST" "$@"; exit 1 ;;
  esac
fi
if [ "$NESTED_VARIANT" = all-common-error ] \
  && [ "${3:-} ${4:-} ${5:-}" = 'rev-parse --path-format=absolute --git-common-dir' ]; then exit 1; fi
if [ "${2:-}" = "$NESTED_CASE/project" ] && [ "$NESTED_VARIANT" = project-common-error ] \
  && [ "${3:-} ${4:-} ${5:-}" = 'rev-parse --path-format=absolute --git-common-dir' ]; then exit 1; fi
if [ "${2:-}" = "$other" ] && [ "${3:-} ${4:-} ${5:-}" = 'rev-list --all --reflog' ]; then
  case "$NESTED_VARIANT" in
    initial-history-error)
      if [ ! -e "$NESTED_CASE/final-status" ]; then exit 1; fi
      ;;
    history-error|history-silent-error|history-warning)
      if [ "$NESTED_VARIANT" != history-silent-error ]; then echo 'synthetic unreadable context history' >&2; fi
      if [ "$NESTED_VARIANT" = history-warning ]; then exit 0; fi
      exit 1
      ;;
  esac
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$c/fakebin/git"
  NESTED_CASE="$c" NESTED_VARIANT="$variant" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  case "$variant" in
    late-*|final-*) [ -f "$c/final-status" ] || fail 'context fixture missed final inspection' ;;
  esac
  case "$variant" in
    missing|unlinked|foreign|initial-history-error|history-error|history-silent-error|history-warning|final-inventory-error|final-inventory-warning|late-ref|late-missing)
      [ "$rc" -eq 0 ] && [ ! -e "$inner" ] && [ -s "$c/returns" ] || fail "unrelated context $variant blocked landed candidate"
      if [ "$variant" = late-ref ]; then
        [ "$(git -C "$c/late copy" rev-parse refs/worktree/saved-work)" = "$(cat "$c/late-commit")" ] || fail 'late unrelated private ref changed'
        [ "$(git -C "$c/late copy" show "$(cat "$c/late-commit"):unique-work")" = 'late context work' ] || fail 'late unrelated bytes changed'
      fi
      pass "nested context $variant is outside owned history and allows landed return"
      return
      ;;
  esac
  [ "$rc" -ne 0 ] || fail "nested context $variant unexpectedly allowed return"
  [ -f "$inner/.git" ] && [ -d "$gitdir" ] || fail "nested context $variant lost candidate or private Git data"
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail "nested context $variant changed task or returned slot"
  grep -F 'REFUSED:' "$c/err" >/dev/null || fail 'context refusal lacked safety diagnostic'
  case "$variant" in
    project-common-error) grep -F "$c/project" "$c/err" >/dev/null || fail 'identity refusal did not name project' ;;
    *inventory*) grep -F "$c/wt" "$c/err" >/dev/null || fail 'inventory refusal did not name affected copy' ;;
    *) grep -F "$inner" "$c/err" >/dev/null || fail 'context refusal did not name candidate context' ;;
  esac
  pass "nested context $variant refuses incomplete history inspection and preserves candidate"
}

test_nested_history_scope() {
  local variant=$1 c inner other head unique local_oid remote_oid other_oid rc=0
  c=$(nested_fixture "scope-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  other="$c/other copy"
  head=$(git -C "$inner" rev-parse HEAD)
  local_oid=$(printf 'unrelated local\n' | git -C "$inner" commit-tree "$head^{tree}" -p "$head")
  remote_oid=$(printf 'unrelated remote\n' | git -C "$inner" commit-tree "$head^{tree}" -p "$head")
  case "$variant" in
    local|all|unlanded)
      git -C "$c/project" update-ref --create-reflog refs/heads/unrelated "$local_oid"
      ;;
  esac
  case "$variant" in
    remote|all|unlanded)
      git -C "$c/project" update-ref --create-reflog refs/remotes/elsewhere/unrelated "$remote_oid"
      ;;
  esac
  case "$variant" in
    other|all|unlanded)
      git -C "$c/project" worktree add -q --detach "$other" main
      printf 'unrelated private work\n' > "$other/private-work"
      git -C "$other" add private-work
      git -C "$other" commit -qm 'unrelated private work'
      other_oid=$(git -C "$other" rev-parse HEAD)
      git -C "$other" update-ref --create-reflog refs/worktree/private "$other_oid"
      git -C "$other" checkout -q --detach main
      cp "$(git -C "$other" rev-parse --git-path logs/HEAD)" "$c/other-head-before"
      cp "$(git -C "$other" rev-parse --git-path logs/refs/worktree/private)" "$c/other-private-before"
      ;;
  esac
  git -C "$c/project" for-each-ref --format='%(refname) %(objectname)' refs/heads/unrelated refs/remotes/elsewhere/ > "$c/shared-before"
  if [ "$variant" = unlanded ]; then
    printf 'candidate unpublished work\n' > "$inner/candidate-work"
    git -C "$inner" add candidate-work
    git -C "$inner" commit -qm 'candidate unpublished work'
    unique=$(git -C "$inner" rev-parse HEAD)
  fi
  NESTED_CASE="$c" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  if [ "$variant" = unlanded ]; then
    [ "$rc" -ne 0 ] && [ -f "$inner/.git" ] || fail 'unlanded candidate was removed under unrelated history'
    [ "$(git -C "$inner" rev-parse HEAD)" = "$unique" ] || fail 'unlanded candidate HEAD changed'
    [ "$(cat "$inner/candidate-work")" = 'candidate unpublished work' ] || fail 'unlanded candidate bytes lost'
    [ ! -e "$c/returns" ] || fail 'unlanded candidate returned slot'
  else
    [ "$rc" -eq 0 ] || fail "unrelated $variant history blocked landed candidate removal"
    [ ! -e "$inner" ] && [ -s "$c/returns" ] || fail 'landed candidate did not return slot'
  fi
  git -C "$c/project" for-each-ref --format='%(refname) %(objectname)' refs/heads/unrelated refs/remotes/elsewhere/ > "$c/shared-after"
  cmp -s "$c/shared-before" "$c/shared-after" || fail 'unrelated shared refs changed'
  case "$variant" in
    other|all|unlanded)
      [ "$(git -C "$other" rev-parse refs/worktree/private)" = "$other_oid" ] || fail 'other private history changed'
      cmp -s "$c/other-head-before" "$(git -C "$other" rev-parse --git-path logs/HEAD)" || fail 'other HEAD reflog changed'
      cmp -s "$c/other-private-before" "$(git -C "$other" rev-parse --git-path logs/refs/worktree/private)" || fail 'other private reflog changed'
      [ "$(git -C "$other" show "$other_oid:private-work")" = 'unrelated private work' ] || fail 'other private bytes lost'
      ;;
  esac
  pass "nested owned history excludes unrelated $variant work and preserves candidate safety"
}

test_nested_owned_history() {
  local variant=$1 c inner head unique ref log gitdir rc=0
  c=$(nested_fixture "owned-$variant")
  inner="$c/wt/.claude/worktrees/inner copy"
  head=$(git -C "$inner" rev-parse HEAD)
  unique=$(printf 'owned history only\n' | git -C "$inner" commit-tree "$head^{tree}" -p "$head")
  gitdir=$(git -C "$inner" rev-parse --absolute-git-dir)
  ref=refs/heads/nested
  case "$variant" in
    private-log-root-file) ref=HEAD ;;
    private-*) ref=refs/worktree/saved; git -C "$inner" update-ref --create-reflog "$ref" "$head" ;;
    head-*) ref=HEAD ;;
  esac
  if [ "$variant" = private-nested-orphan-old ] || [ "$variant" = private-nested-landed ]; then
    git -C "$inner" update-ref -d "$ref"
    ref=refs/worktree/archive/saved
  fi
  case "$variant" in private-orphan-*) git -C "$inner" update-ref -d "$ref" ;; esac
  log=$(git -C "$inner" rev-parse --git-path "logs/$ref")
  mkdir -p "$(dirname "$log")"
  case "$variant" in
    branch-old|private-old|head-old|branch-missing-object|private-orphan-old|private-nested-orphan-old|backend-echo-unlanded)
      printf '%s %s %s\told endpoint only\n' "$unique" "$head" "$(git -C "$inner" var GIT_COMMITTER_IDENT)" > "$log"
      ;;
    branch-new|private-new|head-new|private-orphan-new)
      printf '%s %s %s\tnew endpoint only\n' "$head" "$unique" "$(git -C "$inner" var GIT_COMMITTER_IDENT)" > "$log"
      ;;
    private-nested-landed) printf '%s %s %s\tlanded nested log\n' "$head" "$head" "$(git -C "$inner" var GIT_COMMITTER_IDENT)" > "$log" ;;
    private-blob) git -C "$inner" update-ref "$ref" "$(printf 'private blob' | git -C "$inner" hash-object -w --stdin)" ;;
    branch-malformed) printf '0 0 invalid reflog endpoints\n' > "$log" ;;
    branch-truncated) printf '%040d' 0 > "$log" ;;
    branch-directory|private-directory|head-directory) mv "$log" "$c/original-log"; mkdir "$log" ;;
    private-log-root-file) mkdir -p "$(dirname "$(git -C "$inner" rev-parse --git-path logs/refs/worktree)")"; printf 'not a log directory\n' > "$(git -C "$inner" rev-parse --git-path logs/refs/worktree)" ;;
  esac
  if [ "$variant" = branch-missing-object ]; then
    sed "s/$unique/1111111111111111111111111111111111111111/" "$log" > "$c/missing-log"
    cp "$c/missing-log" "$log"
  fi
  if [ -f "$log" ]; then cp "$log" "$c/log-before"; fi
  cat > "$c/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = "$NESTED_CASE/wt/.claude/worktrees/inner copy" ]; then
  case "$NESTED_VARIANT:${3:-} ${4:-}" in
    branch-query-error:'symbolic-ref -q') exit 2 ;;
    branch-query-warning:'symbolic-ref -q') "$REAL_GIT_FOR_TEST" "$@"; echo 'uncertain branch' >&2; exit 0 ;;
    private-inventory-error:'for-each-ref --format=%(refname)') exit 1 ;;
    private-inventory-warning:'for-each-ref --format=%(refname)') "$REAL_GIT_FOR_TEST" "$@"; echo 'uncertain refs' >&2; exit 0 ;;
    backend:'rev-parse --show-ref-format') echo reftable; exit 0 ;;
    backend-echo-landed:'rev-parse --show-ref-format'|backend-echo-unlanded:'rev-parse --show-ref-format')
      touch "$NESTED_CASE/format-queried"
      printf '%s\n' --show-ref-format; exit 0 ;;
    backend-empty:'rev-parse --show-ref-format') exit 0 ;;
    backend-other:'rev-parse --show-ref-format') echo unknown; exit 0 ;;
    backend-error:'rev-parse --show-ref-format') printf '%s\n' --show-ref-format; exit 1 ;;
    backend-warning:'rev-parse --show-ref-format') printf '%s\n' --show-ref-format; echo 'uncertain storage' >&2; exit 0 ;;
  esac
  if [ "$NESTED_VARIANT" = branch-path-error ] && [ "${6:-}" = logs/refs/heads/nested ]; then exit 1; fi
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$c/fakebin/git"
  NESTED_CASE="$c" NESTED_VARIANT="$variant" run_teardown "$c" > "$c/out" 2> "$c/err" || rc=$?
  case "$variant" in
    backend-echo-*) [ -f "$c/format-queried" ] || fail 'legacy echo did not reach storage inspection' ;;
  esac
  if [ "$variant" = private-nested-landed ] || [ "$variant" = backend-echo-landed ]; then
    [ "$rc" -eq 0 ] && [ ! -e "$inner" ] && [ -s "$c/returns" ] || fail "landed $variant prevented slot return"
    pass "landed $variant allows slot return"
    return
  fi
  [ "$rc" -ne 0 ] || fail "owned $variant history unexpectedly allowed return"
  [ -f "$inner/.git" ] && [ -d "$gitdir" ] || fail "owned $variant lost copy or private Git data"
  [ -f "$c/state/task-x1.meta" ] && [ ! -e "$c/returns" ] || fail 'owned history refusal changed task or returned slot'
  grep -F "REFUSED: nested worktree $inner retained history cannot be inspected" "$c/err" >/dev/null || fail "owned $variant missed history refusal"
  [ "$(git -C "$inner" rev-parse HEAD)" = "$head" ] || fail 'owned history refusal changed HEAD'
  if [ -f "$c/log-before" ]; then cmp -s "$c/log-before" "$log" || fail 'owned history refusal changed reflog'; fi
  case "$variant" in
    *-old|*-new|backend-echo-unlanded) grep -F "$unique" "$c/err" >/dev/null || fail 'owned endpoint refusal did not identify commit' ;;
  esac
  pass "nested owned $variant history refuses and preserves HEAD, private data and reflog"
}

run_nested_tests() {
  local variant
  for variant in local remote other all unlanded; do test_nested_history_scope "$variant"; done
  for variant in branch-old branch-new private-old private-new head-old head-new private-orphan-old private-orphan-new private-nested-orphan-old private-nested-landed branch-truncated branch-directory private-directory head-directory branch-malformed branch-missing-object private-log-root-file private-blob branch-query-error branch-query-warning private-inventory-error private-inventory-warning branch-path-error backend backend-echo-landed backend-echo-unlanded backend-empty backend-other backend-error backend-warning; do test_nested_owned_history "$variant"; done
  test_nested_landed
  test_nested_squash
  test_nested_disposable
  for variant in missing unlinked foreign top-error common-error all-common-error project-common-error inventory-empty inventory-error inventory-silent-error inventory-warning initial-history-error history-error history-silent-error history-warning final-inventory-error final-inventory-warning late-ref late-missing; do test_nested_history_context "$variant"; done
  for variant in reflog worktree-ref ref-only ref-ancestor mixed head-old-side head-new-side private-ref-reflog other-worktree-ref other-worktree-reflog other-worktree-old-side history-unreadable history-silent-error history-warning reflog-squash ref-squash; do test_nested_history "$variant"; done
  for variant in reflog worktree-ref; do test_nested_history_changed "$variant"; done
  test_nested_repository_retention standalone
  test_nested_repository_retention foreign-worktree
  test_nested_hidden_untracked
  test_nested_recreated_candidate
  for variant in unlanded kept-child kept-sibling out-of-plan; do test_nested_plan_retention "$variant"; done
  for variant in skip-worktree assume-unchanged env notes rails-key dependency empty-dependency status-unreadable flags-unreadable ignored-unreadable head-unreadable; do
    test_nested_private "$variant"
  done
  for variant in head dirty skip-worktree assume-unchanged ignored head-unreadable hidden-untracked repository; do
    test_nested_changed "$variant"
  done
  for variant in unlanded pushed forced dirty agent-dirty unknown locked missing mixed inventory; do
    test_nested_refusal "$variant"
  done
}

if [ "${1:-}" = nested ]; then
  if [ "$#" -gt 1 ]; then
    case "$2" in
      landed|squash|disposable) "test_nested_$2" ;;
      scope) test_nested_history_scope "$3" ;;
      owned) test_nested_owned_history "$3" ;;
      history) test_nested_history "$3" ;;
      history-changed) test_nested_history_changed "$3" ;;
      context) test_nested_history_context "$3" ;;
      repository) test_nested_repository_retention "$3" ;;
      plan) test_nested_plan_retention "$3" ;;
      hidden-untracked) test_nested_hidden_untracked ;;
      recreated) test_nested_recreated_candidate ;;
      private) test_nested_private "$3" ;;
      changed) test_nested_changed "$3" ;;
      *) test_nested_refusal "$2" ;;
    esac
  else
    run_nested_tests
  fi
  exit 0
fi

if [ "${1:-}" = cleanup ]; then
  shift
  if [ "$#" -gt 0 ]; then
    "test_cleanup_$1"
  else
    for cleanup_case in outputs keep unlanded symlinks force free leased protected_targets link_cycle reservations unavailable changed_pool lock free_unlanded nested_repository unattributed_target external_links slot_identity hardlinks gate dangling_build scout writers stubborn_writer caller_in_worktree caller_modules caller_modules_pythonpath caller_dir_deleted scan_denied unkillable_writer grace_wait readonly readonly_modes partial_failure recorded_target record_bounds lock_lifetime rust_deps nested_deps recorded_unlinked recorded_parent recorded_protections record_user_temp recorded_writer recorded_writer_protections ignored_only_directory kept_listed_children rails_keys tracked_agent_config tracked_codex_config tracked_dependency_install tracked_nested_project deps_contexts; do "test_cleanup_$cleanup_case"; done
  fi
  exit 0
fi
run_nested_tests
for cleanup_case in outputs keep unlanded symlinks force free leased protected_targets link_cycle reservations unavailable changed_pool lock free_unlanded nested_repository unattributed_target external_links slot_identity hardlinks gate dangling_build scout writers stubborn_writer caller_in_worktree caller_modules caller_modules_pythonpath caller_dir_deleted scan_denied unkillable_writer grace_wait readonly readonly_modes partial_failure recorded_target record_bounds lock_lifetime rust_deps nested_deps recorded_unlinked recorded_parent recorded_protections record_user_temp recorded_writer recorded_writer_protections ignored_only_directory kept_listed_children rails_keys tracked_agent_config tracked_codex_config tracked_dependency_install tracked_nested_project deps_contexts; do "test_cleanup_$cleanup_case"; done

test_shared_daemon_restored_after_a_successful_return
test_landed_task_clears_only_its_gate_backups
test_missing_gate_store_does_not_block_teardown
test_shared_daemon_left_untouched_when_healthy
test_shared_daemon_absent_is_a_clean_no_op
test_shared_daemon_failure_never_fails_teardown
test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_secondmate_projected_child_retains_records_when_worktree_close_unconfirmed
test_forced_secondmate_projected_child_closes_worktree_pane_before_task_pane
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_herdr_projection_teardown_closes_worktree_pane_before_task_pane
test_herdr_projection_teardown_retains_records_when_worktree_close_unconfirmed
test_herdr_quarantined_journal_teardown_still_closes_worktree_pane
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_supplied_branch_name_merged_pr_is_recognized_as_landed
test_supplied_branch_name_unlanded_work_still_refuses
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_unfetched_pushed_branch_is_landed
test_rebased_branch_republished_under_new_hashes_is_landed
test_open_pr_head_containing_the_work_is_landed
test_one_line_difference_from_landed_content_still_refuses
test_proven_unlanded_refusal_names_force_as_the_captain_s_call
test_undecidable_landing_refuses_without_offering_force
test_every_failed_check_is_reported_on_its_own_line
test_detached_head_refuses_without_offering_force
test_diagnostic_free_return_failure_is_rerun_and_completes
test_diagnosed_return_failure_still_aborts_without_retrying
test_return_failure_diagnosed_on_the_next_line_still_aborts_without_retrying
test_dirty_worktree_refuses
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_captured_recovery_context_survives_teardown
