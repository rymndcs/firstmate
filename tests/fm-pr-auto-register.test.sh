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

printf '# Backlog\n## Under way\n- [ ] task-b own item\n  links: pr:https://github.com/owner/repo/pull/43\n- [ ] task-b-extra other item\n  links: pr:https://github.com/wrong/repo/pull/8\n' > "$FM_HOME/data/backlog.md"
"$PR_CODE/bin/fm-pr-auto-register.sh" task-b
assert_grep 'pr=https://github.com/owner/repo/pull/43' "$FM_HOME/state/task-b.meta" 'backlog must match exact task key'
pass 'backlog PR comes only from exact task item'

write_pr_task task-fail
printf 'pushed fix PR %s\n' "$url" > "$FM_HOME/state/task-fail.status"
printf '#!/usr/bin/env bash\nprintf "failure detail\\nsecond detail\\n" >&2\nexit 1\n' > "$PR_CODE/bin/fm-pr-check.sh"
drain_pr > "$PR_TMP/out" 2> "$PR_TMP/err"
[ "$(wc -l < "$PR_TMP/err" | tr -d ' ')" = 1 ] || fail 'registration failure needs one diagnostic'
assert_grep 'task-fail' "$PR_TMP/err" 'diagnostic must name failing task'
pass 'registration failure reports once without failing drain'

cp "$ROOT/bin/fm-pr-check.sh" "$PR_CODE/bin/fm-pr-check.sh"
drain_pr > /dev/null
assert_grep "pr=$url" "$FM_HOME/state/task-fail.meta" 'a later drain must retry failed registration'
fm_git_worktree "$PR_TMP/project" "$PR_TMP/worktree" test-pr-spawn
mkdir -p "$FM_HOME/data/task-spawn"
printf 'Delivery contract: mode=no-mistakes yolo=off\n' > "$FM_HOME/data/task-spawn/brief.md"
printf '\n- [ ] task-spawn launch\n  links: pr:%s\n' "$url" >> "$FM_HOME/data/backlog.md"
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
    "$PR_CODE/bin/fm-spawn.sh" task-spawn "$PR_TMP/project" --mode no-mistakes --yolo off --captain-pick codex --harness codex > "$PR_TMP/spawn.out" 2> "$PR_TMP/spawn.err"
}
spawn_pr || { cat "$PR_TMP/spawn.err"; fail 'spawn failed'; }
assert_grep "pr=$url" "$FM_HOME/state/task-spawn.meta" 'spawn must register backlog PR'
cp "$FM_HOME/state/task-spawn.pr-poll-registration" "$PR_TMP/spawn-before"
spawn_pr || fail 'resume failed'
assert_grep "pr=$url" "$FM_HOME/state/task-spawn.meta" 'resume must preserve PR registration'
cmp -s "$PR_TMP/spawn-before" "$FM_HOME/state/task-spawn.pr-poll-registration" || fail 'resume must not replace existing registration'
pass 'spawn and resume register own backlog PR without replacing an existing watch'

write_pr_task task-link
printf 'done: PR %s\n' "$url" > "$PR_TMP/other.status"
ln -s "$PR_TMP/other.status" "$FM_HOME/state/task-link.status"
"$PR_CODE/bin/fm-pr-auto-register.sh" task-link
assert_absent "$FM_HOME/state/task-link.check.sh" 'symlink status must not bind another task PR'
pass 'status symlinks cannot import another task record'

printf '#!/usr/bin/env bash\nprintf "detail\\n" >&2\nexit 1\n' > "$PR_CODE/bin/fm-pr-check.sh"
printf '\n- [ ] task-spawn-fail launch\n  links: pr:%s\n' "$url" >> "$FM_HOME/data/backlog.md"
mkdir -p "$FM_HOME/data/task-spawn-fail"
cp "$FM_HOME/data/task-spawn/brief.md" "$FM_HOME/data/task-spawn-fail/brief.md"
FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$PR_TMP/worktree" TMUX=fake,1,0 \
  "$PR_CODE/bin/fm-spawn.sh" task-spawn-fail "$PR_TMP/project" --mode no-mistakes --yolo off --captain-pick codex --harness codex > "$PR_TMP/spawn.out" 2> "$PR_TMP/spawn.err" || fail 'registration failure must not fail spawn'
assert_grep 'spawned task-spawn-fail' "$PR_TMP/spawn.out" 'spawn must complete despite registration failure'
[ "$(grep -c '^PR_REGISTRATION:' "$PR_TMP/spawn.err")" = 1 ] || fail 'spawn registration failure must print one diagnostic'
pass 'failed PR registration leaves launch successful with one diagnostic'

fm_write_meta "$FM_HOME/state/task-cleanup.meta" 'window=firstmate:fm-task-cleanup' 'endpoint_task_id=task-cleanup' "worktree=$PR_TMP/missing-worktree" "project=$PR_TMP/project" 'kind=ship' 'mode=local-only'
printf 'registered\n' > "$FM_HOME/state/task-cleanup.pr-auto"
printf 'observed\n' > "$FM_HOME/state/task-cleanup.pr-ci"
"$PR_CODE/bin/fm-teardown.sh" task-cleanup --force > "$PR_TMP/cleanup.out" 2> "$PR_TMP/cleanup.err" || { cat "$PR_TMP/cleanup.err"; fail 'cleanup fixture failed'; }
assert_absent "$FM_HOME/state/task-cleanup.pr-auto" 'teardown must remove automatic registration receipt'
assert_absent "$FM_HOME/state/task-cleanup.pr-ci" 'teardown must remove CI observation receipt'
pass 'teardown removes task-owned registration and CI receipts'

cp "$ROOT/bin/fm-pr-check.sh" "$PR_CODE/bin/fm-pr-check.sh"
rm -f "${FM_HOME:?}/state/task-a.check.sh" "${FM_HOME:?}/state/task-a.pr-poll" "${FM_HOME:?}/state/task-a.pr-poll-registration"
"$PR_CODE/bin/fm-pr-auto-register.sh" task-a
assert_absent "$FM_HOME/state/task-a.check.sh" 'discovery must not rearm a retired merge poll'
pass 'successful discovery remains a no-op after merge-poll retirement'
