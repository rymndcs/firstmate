#!/usr/bin/env bash
set -eu
# shellcheck source=tests/pr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-helpers.sh"
write_pr_task task-a
write_pr_task task-b
printf 'done: PR %s checks green\nworking: later note without URL\n' "$url" > "$FM_HOME/state/task-a.status"
printf '1\t1\tsignal\ttask-a.status\tPR https://github.com/wrong/repo/pull/9\n' > "$FM_HOME/state/.wake-queue"
drain_pr > "$PR_TMP/drain"
assert_grep "pr=$url" "$FM_HOME/state/task-a.meta" 'drain must register URL from own complete status log'
assert_absent "$FM_HOME/state/task-b.check.sh" 'unrelated task must not inherit PR'
assert_grep 'wrong/repo' "$PR_TMP/drain" 'raw wake must survive registration'
cp "$FM_HOME/state/task-a.pr-poll-registration" "$PR_TMP/before"
drain_pr > /dev/null
cmp -s "$PR_TMP/before" "$FM_HOME/state/task-a.pr-poll-registration" || fail 'repeated registration must preserve identity'
pass 'drain discovers own status URL and repeated empty drains are no-ops'

write_pr_task task-ref
printf 'done: PR %s checks green\n' "$url" > "$FM_HOME/state/task-ref.status"
drain_pr > /dev/null
printf 'blocked: needs rebase after https://github.com/owner/repo/pull/20 merged\n' >> "$FM_HOME/state/task-ref.status"
drain_pr > /dev/null
assert_grep "pr=$url" "$FM_HOME/state/task-ref.meta" 'a referenced PR must not replace the registered PR'
assert_no_grep 'pull/20' "$FM_HOME/state/task-ref.pr-poll" 'the merge poll must keep following the task PR'
pass 'a later status reference to another PR never replaces the task PR'

write_pr_task task-exp
printf 'done: PR %s\n' "$url" > "$FM_HOME/state/task-exp.status"
drain_pr > /dev/null
"$PR_CODE/bin/fm-pr-check.sh" task-exp https://github.com/owner/repo/pull/99 > /dev/null 2>&1 || fail 'explicit registration failed'
drain_pr > /dev/null
assert_grep 'pr=https://github.com/owner/repo/pull/99' "$FM_HOME/state/task-exp.meta" 'explicit registration must survive an empty drain'
pass 'discovery never replaces an explicit registration'

write_pr_task task-two
printf 'done: PR %s\ndone: PR https://github.com/owner/repo/pull/45\n' "$url" > "$FM_HOME/state/task-two.status"
drain_pr > /dev/null
assert_grep "pr=$url" "$FM_HOME/state/task-two.meta" 'one drain must register the PR that drains in between would have kept'
pass 'the first qualifying status line names the task PR'

write_pr_task task-cite
printf 'working: porting approach from https://github.com/cli/cli/pull/9000\nblocked: waiting on https://github.com/owner/repo/pull/20\npushed fix PR %s\n' "$url" > "$FM_HOME/state/task-cite.status"
drain_pr > /dev/null
assert_absent "$FM_HOME/state/task-cite.check.sh" 'a cited PR is a reference, never a registration'
pass 'status URLs outside done and pushed-to-PR lines are references'

write_pr_task task-legacy
printf 'pr=https://github.com/owner/repo/pull/77\n' >> "$FM_HOME/state/task-legacy.meta"
printf 'done: PR %s\n' "$url" > "$FM_HOME/state/task-legacy.status"
drain_pr > /dev/null
assert_grep 'pr=https://github.com/owner/repo/pull/77' "$FM_HOME/state/task-legacy.meta" 'a recorded pr= line is an existing registration'
assert_absent "$FM_HOME/state/task-legacy.check.sh" 'discovery must not arm a poll over an existing registration'
pass 'metadata registered before the registration record is never replaced'

cat > "$FM_HOME/data/backlog.md" <<'BACKLOG'
# Backlog
## In flight
- [ ] task-b - resume fix https://github.com/owner/repo/pull/43 (kind: ship) (since 2026-10-26)
  links: pr:https://github.com/owner/repo/pull/43
- [ ] task-cited - port approach from https://github.com/cli/cli/pull/9000 (kind: ship) (since 2026-10-26)
  links: pr:https://github.com/cli/cli/pull/9000
- [ ] task-both - port approach from https://github.com/cli/cli/pull/9000 https://github.com/owner/repo/pull/43 (kind: ship) (since 2026-10-26)
  links: pr:https://github.com/cli/cli/pull/9000 pr:https://github.com/owner/repo/pull/43
- [ ] task-spawn - launch https://github.com/owner/repo/pull/43 (kind: ship) (since 2026-10-26)
  links: pr:https://github.com/owner/repo/pull/43
BACKLOG
for id in task-b task-cited; do
  write_pr_task "$id"
  "$PR_CODE/bin/fm-pr-auto-register.sh" "$id"
  assert_absent "$FM_HOME/state/$id.check.sh" "$id: a PR URL on the task's own backlog item must not arm a poll"
  assert_absent "$FM_HOME/state/$id.pr-registered" "$id: a PR URL on the task's own backlog item must not register"
  assert_no_grep 'github.com' "$FM_HOME/state/$id.meta" "$id: a PR URL on the task's own backlog item must not be recorded"
done
pass 'same-repo and foreign-repo PR URLs on a backlog item never register'

write_pr_task task-both
printf 'done: PR https://github.com/owner/repo/pull/44\n' > "$FM_HOME/state/task-both.status"
drain_pr > /dev/null
[ "$(grep '^pr=' "$FM_HOME/state/task-both.meta")" = 'pr=https://github.com/owner/repo/pull/44' ] \
  || fail 'the own status PR must be the only PR recorded despite backlog citations'
[ "$(cat "$FM_HOME/state/task-both.pr-registered")" = 'https://github.com/owner/repo/pull/44' ] \
  || fail 'the registration record must name the own status PR'
assert_no_grep 'pull/43' "$FM_HOME/state/task-both.pr-poll" 'the merge poll must not follow a backlog citation'
assert_no_grep 'pull/9000' "$FM_HOME/state/task-both.pr-poll" 'the merge poll must not follow a foreign backlog citation'
pass 'the own status PR registers and backlog citations are ignored'

for kind in scout secondmate; do
  fm_write_meta "$FM_HOME/state/task-$kind.meta" "worktree=$PR_TMP" "kind=$kind"
  printf 'done: PR %s\n' "$url" > "$FM_HOME/state/task-$kind.status"
done
drain_pr > /dev/null
for kind in scout secondmate; do
  assert_absent "$FM_HOME/state/task-$kind.check.sh" "a $kind task must not be registered"
  assert_no_grep "pr=$url" "$FM_HOME/state/task-$kind.meta" "a $kind task must not record a PR"
done
pass 'only ship tasks are eligible for discovery'

write_pr_task task-fail
printf 'pushed fix to PR %s\n' "$url" > "$FM_HOME/state/task-fail.status"
printf '#!/usr/bin/env bash\ncase "$*" in *task-fail*) printf "failure detail\\nsecond detail\\n" >&2; exit 1 ;; esac\n' > "$PR_CODE/bin/fm-pr-check.sh"
drain_pr > "$PR_TMP/out" 2> "$PR_TMP/err"
[ "$(wc -l < "$PR_TMP/err" | tr -d ' ')" = 1 ] || fail 'registration failure needs one diagnostic'
assert_grep 'task-fail' "$PR_TMP/err" 'diagnostic must name failing task'
pass 'registration failure reports once without failing drain'

cp "$ROOT/bin/fm-pr-check.sh" "$PR_CODE/bin/fm-pr-check.sh"
drain_pr > /dev/null
assert_grep "pr=$url" "$FM_HOME/state/task-fail.meta" 'a later drain must retry failed registration'
pass 'a pushed-to-PR status line registers on retry'

n=60
# shellcheck disable=SC2016 # The backticks are a literal status-line form.
for form in '`URL` checks green' '<URL>' 'URL: checks green' '[#N](URL) checks green' 'URL.'; do
  write_pr_task "task-form-$n"
  pr="https://github.com/owner/repo/pull/$n"
  line=${form//URL/$pr}
  printf 'done: PR %s\n' "${line//N/$n}" > "$FM_HOME/state/task-form-$n.status"
  n=$((n + 1))
done
write_pr_task task-form-pushed
printf 'pushed fix to PR [#65](https://github.com/owner/repo/pull/65)\n' > "$FM_HOME/state/task-form-pushed.status"
drain_pr > /dev/null
for n in 60 61 62 63 64; do
  assert_grep "pr=https://github.com/owner/repo/pull/$n" "$FM_HOME/state/task-form-$n.meta" "own-PR line form $n must register"
done
assert_grep 'pr=https://github.com/owner/repo/pull/65' "$FM_HOME/state/task-form-pushed.meta" 'a Markdown link on a pushed-to-PR line must register'
pass 'own-PR lines accept backticked, angle, colon, period and Markdown-link URLs'

write_pr_task task-slow
printf 'done: PR https://github.com/owner/repo/pull/66\n' > "$FM_HOME/state/task-slow.status"
FM_PR_CHECK_GH_TIMEOUT=1 FM_TEST_GH_HEAD_WAIT_URL=https://github.com/owner/repo/pull/66 drain_pr > /dev/null
assert_grep 'pr=https://github.com/owner/repo/pull/66' "$FM_HOME/state/task-slow.meta" 'a slow GitHub head lookup must not stop registration'
assert_absent "$FM_HOME/head-wait-finished" 'drain must abandon a hung GitHub head lookup instead of waiting for it'
rm -f "${FM_HOME:?}/head-wait-started" "${FM_HOME:?}/head-wait-finished"
pass 'a hung GitHub head lookup is bounded during discovery'

write_pr_task task-partial
printf 'kept=line\n' >> "$FM_HOME/state/task-partial.meta"
printf 'done: PR https://github.com/owner/repo/pull/67\n' > "$FM_HOME/state/task-partial.status"
mkdir "$FM_HOME/state/task-partial.pr-poll-registration"
drain_pr > /dev/null 2>&1
assert_absent "$FM_HOME/state/task-partial.check.sh" 'fixture: an obstructed poll must fail to publish'
assert_no_grep 'pr=https://github.com/owner/repo/pull/67' "$FM_HOME/state/task-partial.meta" 'a registration that failed to publish must not leave its PR recorded'
rmdir "$FM_HOME/state/task-partial.pr-poll-registration"
drain_pr > /dev/null
assert_grep 'pr=https://github.com/owner/repo/pull/67' "$FM_HOME/state/task-partial.meta" 'a later drain must retry a registration that failed after recording metadata'
assert_grep 'kept=line' "$FM_HOME/state/task-partial.meta" 'a failed registration must keep the other metadata lines'
assert_present "$FM_HOME/state/task-partial.check.sh" 'the retried registration must arm its poll'
pass 'a registration that fails after recording metadata is retried'

write_pr_task task-rereg
"$PR_CODE/bin/fm-pr-check.sh" task-rereg https://github.com/owner/repo/pull/70 > /dev/null 2>&1 || fail 'registration failed'
mv "$FM_HOME/state/task-rereg.pr-poll-registration" "$PR_TMP/rereg-registration"
mkdir "$FM_HOME/state/task-rereg.pr-poll-registration"
! "$PR_CODE/bin/fm-pr-check.sh" task-rereg https://github.com/owner/repo/pull/71 > /dev/null 2>&1 || fail 'fixture: an obstructed re-registration must fail'
assert_grep 'pr=https://github.com/owner/repo/pull/70' "$FM_HOME/state/task-rereg.meta" 'a failed re-registration must keep the previous PR recorded'
rmdir "$FM_HOME/state/task-rereg.pr-poll-registration"
pass 'a failed re-registration restores the previous PR metadata'

race_state="$FM_HOME/race-state"
mkdir "$race_state"
fm_write_meta "$race_state/task-race.meta" "worktree=$PR_TMP" 'kind=ship'
printf 'done: PR https://github.com/owner/repo/pull/68\n' > "$race_state/task-race.status"
# shellcheck disable=SC2016 # The stub expands FM_HOME when explicit registration reaches Linear.
printf '#!/usr/bin/env bash\n: > "$FM_HOME/head-wait-release"\n' > "$PR_CODE/bin/fm-linear.sh"
# A private state keeps the explicit run near 1 s, so without the shared lock it finishes inside this 3 s head lookup.
FM_STATE_OVERRIDE=$race_state FM_PR_CHECK_GH_TIMEOUT=3 FM_TEST_GH_HEAD_WAIT_URL=https://github.com/owner/repo/pull/68 \
  "$PR_CODE/bin/fm-pr-auto-register.sh" task-race &
discovery=$!
await_file "$FM_HOME/head-wait-started" 'fixture: discovery did not reach its head lookup'
FM_STATE_OVERRIDE=$race_state "$PR_CODE/bin/fm-pr-check.sh" task-race https://github.com/owner/repo/pull/69 > /dev/null 2>&1 &
explicit=$!
wait "$discovery"
wait "$explicit" || fail 'explicit registration failed'
printf '#!/usr/bin/env bash\nexit 0\n' > "$PR_CODE/bin/fm-linear.sh"
rm -f "${FM_HOME:?}/head-wait-started" "${FM_HOME:?}/head-wait-finished" "${FM_HOME:?}/head-wait-release"
assert_grep 'pr=https://github.com/owner/repo/pull/69' "$race_state/task-race.meta" 'discovery in flight must not overwrite an explicit registration'
pass 'an explicit registration during discovery is never overwritten'

fm_git_worktree "$PR_TMP/project" "$PR_TMP/worktree" test-pr-spawn
mkdir -p "$FM_HOME/data/task-spawn"
printf 'Delivery contract: mode=no-mistakes yolo=off\n' > "$FM_HOME/data/task-spawn/brief.md"
printf 'done: PR %s\n' "$url" > "$FM_HOME/state/task-spawn.status"
cat > "$PR_TMP/fakebin/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH" ;;
  display-message*) printf 'firstmate\n' ;;
esac
exit 0
FAKE
chmod +x "$PR_TMP/fakebin/tmux"
fm_fake_exit0 "$PR_TMP/fakebin" treehouse
spawn_pr() {
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$PR_TMP/worktree" TMUX=fake,1,0 \
    "$PR_CODE/bin/fm-spawn.sh" "$1" "$PR_TMP/project" --mode no-mistakes --yolo off --captain-pick codex --harness codex > "$PR_TMP/spawn.out" 2> "$PR_TMP/spawn.err"
}
spawn_pr task-spawn || { cat "$PR_TMP/spawn.err"; fail 'spawn failed'; }
[ "$(grep '^pr=' "$FM_HOME/state/task-spawn.meta")" = "pr=$url" ] || fail 'spawn must register the own status PR, not the backlog citation'
cp "$FM_HOME/state/task-spawn.pr-poll-registration" "$PR_TMP/spawn-before"
spawn_pr task-spawn || fail 'resume failed'
assert_grep "pr=$url" "$FM_HOME/state/task-spawn.meta" 'resume must preserve PR registration'
cmp -s "$PR_TMP/spawn-before" "$FM_HOME/state/task-spawn.pr-poll-registration" || fail 'resume must not replace existing registration'
pass 'spawn and resume register own status PR without replacing an existing watch'

retire_merged() {
  # shellcheck disable=SC2016 # The child shell expands this retirement script.
  FM_TEST_GH_STATE=MERGED bash -c '
    . "$1/fm-pr-lib.sh"
    fm_pr_poll_snapshot_capture "$2" "$3" "$1/fm-pr-poll.sh" || exit 1
    out=$("$1/fm-pr-poll.sh" --validated "$FM_PR_POLL_SNAPSHOT_PROVIDER" "$FM_PR_POLL_SNAPSHOT_URL" \
      "$FM_PR_POLL_SNAPSHOT_HOST" "$FM_PR_POLL_SNAPSHOT_PATH" "$FM_PR_POLL_SNAPSHOT_NUMBER")
    [ "$out" = merged ] || exit 1
    fm_pr_poll_retirement_publish "$2" "$3" "$1/fm-pr-poll.sh" "$out" || exit 1
    fm_pr_poll_retirement_recover_one "$2" "$3" "$1/fm-pr-poll.sh"
  ' _ "$PR_CODE/bin" "$FM_HOME/state" "$1" || fail "$1 merge poll did not retire through the watcher retirement path"
}
mkdir -p "$FM_HOME/data/task-resume"
cp "$FM_HOME/data/task-spawn/brief.md" "$FM_HOME/data/task-resume/brief.md"
spawn_pr task-resume || { cat "$PR_TMP/spawn.err"; fail 'spawn failed'; }
"$PR_CODE/bin/fm-pr-check.sh" task-resume "$url" > /dev/null 2>&1 || fail 'explicit registration failed'
printf 'done: PR %s checks green\n' "$url" > "$FM_HOME/state/task-resume.status"
retire_merged task-resume
assert_absent "$FM_HOME/state/task-resume.check.sh" 'the merged poll must retire'
drain_pr > /dev/null
assert_absent "$FM_HOME/state/task-resume.check.sh" 'discovery must not rearm an explicitly registered PR after its merge retired'
printf 'decisions_reviewed=1\n' >> "$FM_HOME/state/task-resume.meta"
spawn_pr task-resume || fail 'resume failed'
drain_pr > /dev/null
assert_absent "$FM_HOME/state/task-resume.check.sh" 'the registration record must keep a retired PR retired after resume dropped its metadata'
! grep -q '^pr=' "$FM_HOME/state/task-resume.meta" || fail 'fixture: resume must drop the unparseable PR metadata'
pass 'a merged and retired PR is never polled again after explicit registration'

promoted="$FM_HOME/state/task-promoted"
fm_write_meta "$promoted.meta" "worktree=$PR_TMP" 'kind=scout'
printf 'working: reproducing\ndone: PR https://github.com/owner/repo/pull/20 introduced the regression; report at data/task-promoted/report.md\n' > "$promoted.status"
drain_pr > /dev/null
"$PR_CODE/bin/fm-promote.sh" task-promoted --mode no-mistakes --yolo off > /dev/null || fail 'promotion failed'
drain_pr > /dev/null
! grep -q '^pr=' "$promoted.meta" || fail 'a PR cited while the task was a scout must not register after promotion'
cp "$FM_HOME/data/task-spawn/brief.md" "$FM_HOME/data/task-promoted/brief.md"
spawn_pr task-promoted || { cat "$PR_TMP/spawn.err"; fail 'resume failed'; }
drain_pr > /dev/null
! grep -q '^pr=' "$promoted.meta" || fail 'a PR cited while the task was a scout must not register after resume'
printf 'working: implementing fix\ndone: PR https://github.com/owner/repo/pull/77\n' >> "$promoted.status"
drain_pr > /dev/null
[ "$(grep '^pr=' "$promoted.meta")" = 'pr=https://github.com/owner/repo/pull/77' ] \
  || fail 'the PR reported after promotion must be the only PR recorded'
[ "$(cat "$promoted.pr-registered" 2>/dev/null)" = 'https://github.com/owner/repo/pull/77' ] \
  || fail 'the registration record must name the PR reported after promotion'
[ "$(FM_TEST_GH_MERGED_URL=https://github.com/owner/repo/pull/20 bash "$promoted.check.sh" 2>/dev/null)" != merged ] \
  || fail 'the merge poll must not report the scout-cited PR as this task merging'
spawn_pr task-promoted || fail 'resume after registration failed'
assert_grep 'pr=https://github.com/owner/repo/pull/77' "$promoted.meta" 'resume must keep the PR registered after promotion'
retire_merged task-promoted
assert_absent "$promoted.check.sh" 'the registered PR must retire through the watcher after resume'
pass 'a promoted task registers only PRs reported after promotion, across resume'

ready_home="$PR_TMP/pr-ready-home"
mkdir -p "$ready_home/state" "$ready_home/data/task-ready-spawn" "$ready_home/config" "$PR_TMP/linear-bin"
cp "$ROOT/bin/fm-standing-knowledge.sh" "$ROOT/bin/fm-linear.sh" "$PR_CODE/bin/"
printf '# Projects\n\n- project [no-mistakes] - CAPTAIN MERGE RULE: hold every PR for my word\n' > "$ready_home/data/projects.md"
printf '# Learnings\n\n## PR ready rule\n<!-- fm-moment: pr-ready -->\nHOLD-OR-LAND RULE TEXT\n' > "$ready_home/data/learnings.md"
printf 'lin_test_key\n' > "$ready_home/config/linear-api-key"
printf '#!/usr/bin/env bash\nexit 7\n' > "$PR_TMP/linear-bin/curl"
chmod +x "$PR_TMP/linear-bin/curl"
fm_write_meta "$ready_home/state/task-ready.meta" "worktree=$PR_TMP" "project=$PR_TMP/project" 'kind=ship' 'branch=rac-125-pr-ready'
printf 'done: PR https://github.com/owner/repo/pull/80\n' > "$ready_home/state/task-ready.status"
ready() {
  FM_HOME=$ready_home FM_STATE_OVERRIDE=$ready_home/state FM_DATA_OVERRIDE=$ready_home/data PATH="$PR_TMP/linear-bin:$PATH" "$@"
}
ready drain_pr > "$PR_TMP/ready.out" 2> "$PR_TMP/ready.err"
assert_grep 'pr=https://github.com/owner/repo/pull/80' "$ready_home/state/task-ready.meta" 'fixture: drain must register the PR'
assert_grep 'HOLD-OR-LAND RULE TEXT' "$PR_TMP/ready.err" 'automatic registration must print the pr-ready standing knowledge'
assert_grep 'CAPTAIN MERGE RULE' "$PR_TMP/ready.err" 'automatic registration must print the project merge-authority entry'
assert_grep 'LINEAR: RAC-125' "$PR_TMP/ready.err" 'automatic registration must surface the Linear diagnostic'
assert_no_grep 'PR_REGISTRATION' "$PR_TMP/ready.err" 'a successful registration is not a registration failure'
[ ! -s "$PR_TMP/ready.out" ] || fail 'registration output must not enter the drained wake rows'
ready drain_pr > /dev/null 2> "$PR_TMP/ready-again.err"
assert_no_grep 'HOLD-OR-LAND' "$PR_TMP/ready-again.err" 'an already registered PR must not repeat its pr-ready guidance'
printf 'done: PR https://github.com/owner/repo/pull/81\n' > "$ready_home/state/task-ready-spawn.status"
cp "$FM_HOME/data/task-spawn/brief.md" "$ready_home/data/task-ready-spawn/brief.md"
ready spawn_pr task-ready-spawn || { cat "$PR_TMP/spawn.err"; fail 'spawn failed'; }
assert_grep 'pr=https://github.com/owner/repo/pull/81' "$ready_home/state/task-ready-spawn.meta" 'fixture: spawn must register the PR'
assert_grep 'HOLD-OR-LAND RULE TEXT' "$PR_TMP/spawn.err" 'spawn registration must print the pr-ready standing knowledge'
assert_grep 'CAPTAIN MERGE RULE' "$PR_TMP/spawn.err" 'spawn registration must print the project merge-authority entry'
[ "$(cat "$PR_TMP/spawn.out")" = "$(grep '^spawned task-ready-spawn ' "$PR_TMP/spawn.out")" ] \
  || fail 'spawn stdout must stay its one spawned line'
for tool in fm-standing-knowledge fm-linear; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PR_CODE/bin/$tool.sh"
done
pass 'automatic registration delivers the pr-ready guidance once, like explicit registration'

write_pr_task task-link
printf 'done: PR %s\n' "$url" > "$PR_TMP/other.status"
ln -s "$PR_TMP/other.status" "$FM_HOME/state/task-link.status"
"$PR_CODE/bin/fm-pr-auto-register.sh" task-link
assert_absent "$FM_HOME/state/task-link.check.sh" 'symlink status must not bind another task PR'
pass 'status symlinks cannot import another task record'

printf '#!/usr/bin/env bash\nprintf "detail\\n" >&2\nexit 1\n' > "$PR_CODE/bin/fm-pr-check.sh"
printf 'done: PR %s\n' "$url" > "$FM_HOME/state/task-spawn-fail.status"
mkdir -p "$FM_HOME/data/task-spawn-fail"
cp "$FM_HOME/data/task-spawn/brief.md" "$FM_HOME/data/task-spawn-fail/brief.md"
spawn_pr task-spawn-fail || fail 'registration failure must not fail spawn'
assert_grep 'spawned task-spawn-fail' "$PR_TMP/spawn.out" 'spawn must complete despite registration failure'
[ "$(grep -c '^PR_REGISTRATION:' "$PR_TMP/spawn.err")" = 1 ] || fail 'spawn registration failure must print one diagnostic'
pass 'failed PR registration leaves launch successful with one diagnostic'

fm_write_meta "$FM_HOME/state/task-cleanup.meta" 'window=firstmate:fm-task-cleanup' 'endpoint_task_id=task-cleanup' "worktree=$PR_TMP/missing-worktree" "project=$PR_TMP/project" 'kind=ship' 'mode=local-only'
printf 'registered\n' > "$FM_HOME/state/task-cleanup.pr-registered"
printf 'observed\n' > "$FM_HOME/state/task-cleanup.pr-ci"
"$PR_CODE/bin/fm-teardown.sh" task-cleanup --force > "$PR_TMP/cleanup.out" 2> "$PR_TMP/cleanup.err" || { cat "$PR_TMP/cleanup.err"; fail 'cleanup fixture failed'; }
assert_absent "$FM_HOME/state/task-cleanup.pr-registered" 'teardown must remove the registration record'
assert_absent "$FM_HOME/state/task-cleanup.pr-ci" 'teardown must remove CI observation receipt'
pass 'teardown removes task-owned registration and CI receipts'
