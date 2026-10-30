#!/usr/bin/env bash
set -eu
# shellcheck source=tests/pr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-helpers.sh"
write_pr_task task-a
printf 'pr=%s\n' "$url" >> "$FM_HOME/state/task-a.meta"
[ -z "$(poll_pr)" ] || fail 'unregistered URL must not publish a CI observation'
register_pr task-a
out=$(poll_pr)
assert_contains "$out" 'ci-pass' 'all required passing checks must wake'
assert_contains "$out" "$FM_TEST_GH_HEAD" 'CI wake must identify head'
[ -z "$(poll_pr)" ] || fail 'same head and outcome must not repeat'
drain_pr > "$PR_TMP/drained"
[ -z "$(poll_pr)" ] || fail 'draining must not forget observed outcome'
pass 'green CI wakes once per head, including after draining'

FM_TEST_GH_BUCKETS=fail FM_TEST_GH_CHECK_RC=1
out=$(poll_pr)
assert_contains "$out" 'ci-fail' 'required failure must wake even with gh exit 1'
[ -z "$(poll_pr)" ] || fail 'failure must not repeat'
FM_TEST_GH_BUCKETS=pending FM_TEST_GH_CHECK_RC=8
[ -z "$(poll_pr)" ] || fail 'pending is not a CI outcome'
FM_TEST_GH_BUCKETS=pass FM_TEST_GH_CHECK_RC=0
[ -z "$(poll_pr)" ] || fail 'same head returning green must not repeat prior green'
FM_TEST_GH_HEAD=2222222222222222222222222222222222222222
assert_contains "$(poll_pr)" ci-pass 'new head needs a fresh outcome'
pass 'failure and new-head outcomes wake while pending and previous outcomes stay silent'

FM_TEST_GH_ALL_BUCKETS=
for buckets in '' garbage; do
  FM_TEST_GH_HEAD=3333333333333333333333333333333333333333
  FM_TEST_GH_BUCKETS=$buckets
  [ -z "$(poll_pr)" ] || fail 'empty or malformed checks must not become green'
done
FM_TEST_GH_ALL_BUCKETS=fail
FM_TEST_GH_BUCKETS=pass FM_TEST_GH_CHECK_RC=4
[ -z "$(poll_pr)" ] || fail 'authentication error must not become green'
FM_TEST_GH_STATE=MERGED
[ "$(poll_pr)" = merged ] || fail 'merge must remain exact for retirement'
pass 'errors stay silent and merge keeps its existing exact result'

FM_TEST_GH_STATE=OPEN FM_TEST_GH_CHECK_RC=8
FM_TEST_GH_HEAD=4444444444444444444444444444444444444444
FM_TEST_GH_BUCKETS=$'pass\npending'
[ -z "$(poll_pr)" ] || fail 'partially complete CI must not be green'
FM_TEST_GH_BUCKETS=$'fail\npending' FM_TEST_GH_CHECK_RC=1
assert_contains "$(poll_pr)" ci-fail 'one failed required check must wake before remaining checks finish'
FM_TEST_GH_HEAD=5555555555555555555555555555555555555555
FM_TEST_GH_BUCKETS=cancel
assert_contains "$(poll_pr)" ci-fail 'canceled required check is a failure'
FM_TEST_GH_HEAD=6666666666666666666666666666666666666666
FM_TEST_GH_BUCKETS=$'pass\nskipping' FM_TEST_GH_CHECK_RC=0
assert_contains "$(poll_pr)" ci-pass 'skipped required checks satisfy GitHub protection'
pass 'required-check aggregation handles mixed, canceled and skipped checks'

FM_TEST_GH_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
FM_TEST_GH_BUCKETS='' FM_TEST_GH_CHECK_RC=1
export FM_TEST_GH_CHECK_ERR="no required checks reported on the 'fix' branch"
FM_TEST_GH_ALL_BUCKETS=$(printf 'pass\n%.0s' $(seq 17); printf 'skipping\n%.0s' $(seq 3)) FM_TEST_GH_ALL_RC=0
assert_contains "$(poll_pr)" ci-pass 'a PR with no required checks must use all reported checks'
FM_TEST_GH_HEAD=cccccccccccccccccccccccccccccccccccccccc
FM_TEST_GH_ALL_RC=4
[ -z "$(poll_pr)" ] || fail 'a failed all-checks lookup must stay silent'
unset FM_TEST_GH_CHECK_ERR
FM_TEST_GH_BUCKETS=pass FM_TEST_GH_CHECK_RC=0 FM_TEST_GH_ALL_BUCKETS=fail FM_TEST_GH_ALL_RC=1
pass 'a PR without required checks reports CI from all of its checks'

FM_TEST_GH_HEAD=7777777777777777777777777777777777777777
export FM_TEST_GH_HEAD_AFTER=8888888888888888888888888888888888888888
[ -z "$(poll_pr)" ] || fail 'concurrent head change must not publish stale checks'
unset FM_TEST_GH_HEAD_AFTER
[ -n "$(poll_pr)" ] || fail 'stable head after race must remain observable'
pass 'a concurrent push is discarded without consuming its outcome'

write_pr_task task-other
register_pr task-other
FM_TEST_GH_HEAD=9999999999999999999999999999999999999999
poll_pr > /dev/null
drain_pr > "$PR_TMP/outcomes"
assert_grep 'task-other.check.sh' "$PR_TMP/outcomes" 'each registered task must receive its own wake'
[ "$(grep -c 'ci-pass head=9999999999999999999999999999999999999999' "$PR_TMP/outcomes")" = 2 ] || fail 'each registration receives exactly one deduped CI notification'
[ -z "$(poll_pr)" ] || fail 'same URL registered twice must still deduplicate'
pass 'matching registrations each receive one durable notification'

write_pr_task task-diff
"$PR_CODE/bin/fm-pr-check.sh" task-diff https://github.com/owner/repo/pull/43 > /dev/null 2>&1 || fail 'registration failed'
FM_TEST_GH_HEAD=dddddddddddddddddddddddddddddddddddddddd
poll_pr > /dev/null
drain_pr > "$PR_TMP/other-url"
assert_grep 'task-a.check.sh' "$PR_TMP/other-url" 'the registered task must still be notified'
assert_no_grep 'task-diff.check.sh' "$PR_TMP/other-url" 'a task registered to another PR must not receive this CI outcome'
pass 'CI outcomes reach only tasks registered to that PR'

write_pr_task task-move
"$PR_CODE/bin/fm-pr-check.sh" task-move https://github.com/owner/repo/pull/51 > /dev/null 2>&1 || fail 'registration failed'
FM_TEST_GH_HEAD=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
FM_PR_CHECK_GH_TIMEOUT=30 FM_TEST_GH_HEAD_WAIT_URL=https://github.com/owner/repo/pull/52 \
  "$PR_CODE/bin/fm-pr-check.sh" task-move https://github.com/owner/repo/pull/52 > /dev/null 2>&1 &
mover=$!
await_file "$FM_HOME/head-wait-started" 'fixture: re-registration did not reach its head lookup'
[ -z "$(poll_pr 51)" ] || fail 'a CI outcome must not publish while its task registration is changing'
: > "$FM_HOME/head-wait-release"
wait "$mover" || fail 're-registration failed'
rm -f "${FM_HOME:?}/head-wait-started" "${FM_HOME:?}/head-wait-finished" "${FM_HOME:?}/head-wait-release"
[ -z "$(poll_pr 51)" ] || fail 'a task moved to another PR must never receive the old PR outcome'
pass 'CI publication never overlaps a change of the task registration'

write_pr_task task-queue
"$PR_CODE/bin/fm-pr-check.sh" task-queue https://github.com/owner/repo/pull/50 > /dev/null 2>&1 || fail 'registration failed'
FM_TEST_GH_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir "$FM_HOME/state/.wake-queue.blocked"
mv "$FM_HOME/state/.wake-queue" "$FM_HOME/state/.wake-queue.blocked/saved"
mkdir "$FM_HOME/state/.wake-queue"
[ -z "$(poll_pr 50)" ] || fail 'failed durable enqueue must not announce or consume observation'
rmdir "$FM_HOME/state/.wake-queue"
mv "$FM_HOME/state/.wake-queue.blocked/saved" "$FM_HOME/state/.wake-queue"
rmdir "$FM_HOME/state/.wake-queue.blocked"
assert_contains "$(poll_pr 50)" ci-pass 'CI observation must retry when enqueue recovers'
pass 'queue failure cannot consume an undelivered CI observation'

write_pr_task task-transient
transient_url=https://github.com/owner/repo/pull/53
"$PR_CODE/bin/fm-pr-check.sh" task-transient "$transient_url" > /dev/null 2>&1 || fail 'registration failed'
drain_pr > /dev/null
FM_TEST_GH_HEAD=ffffffffffffffffffffffffffffffffffffffff
FM_TEST_GH_BUCKETS=$'pass\npass' FM_TEST_GH_CHECK_RC=0
FM_TEST_GH_ALL_BUCKETS=$'pass\npass\nfail' FM_TEST_GH_ALL_RC=0
assert_contains "$(poll_pr 53)" ci-pass 'green required checks must wake'
FM_TEST_GH_BUCKETS='' FM_TEST_GH_CHECK_RC=1
export FM_TEST_GH_CHECK_ERR='Post "https://api.github.com/graphql": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused'
[ -z "$(poll_pr 53)" ] || fail 'a failed required-check lookup must stay silent, never fall back to all checks'
unset FM_TEST_GH_CHECK_ERR
FM_TEST_GH_BUCKETS=$'pass\npass' FM_TEST_GH_CHECK_RC=0
[ -z "$(poll_pr 53)" ] || fail 'a recovered lookup must not repeat the recorded outcome'
[ "$(cat "$FM_HOME/state/task-transient.pr-ci")" = "$transient_url $FM_TEST_GH_HEAD ci-pass" ] \
  || fail 'the receipt must keep only the observed green outcome'
drain_pr > "$PR_TMP/transient"
[ "$(grep -c "task-transient.check.sh: ci-pass head=$FM_TEST_GH_HEAD" "$PR_TMP/transient")" = 1 ] \
  || fail 'the green outcome must be delivered once'
assert_no_grep 'ci-fail' "$PR_TMP/transient" 'a failed lookup must never deliver a CI failure'
pass 'a transient required-check lookup failure never reports CI failure'

write_pr_task task-closed
"$PR_CODE/bin/fm-pr-check.sh" task-closed https://github.com/owner/repo/pull/54 > /dev/null 2>&1 || fail 'registration failed'
drain_pr > /dev/null
FM_TEST_GH_HEAD=1212121212121212121212121212121212121212
FM_TEST_GH_STATE=CLOSED
[ "$(poll_pr 54)" = closed ] || fail 'a closed PR must report closure without a CI outcome'
assert_absent "$FM_HOME/state/task-closed.pr-ci" 'a closed PR must not record a CI outcome'
drain_pr > "$PR_TMP/closed"
assert_no_grep 'task-closed.check.sh' "$PR_TMP/closed" 'a closed PR must not deliver a CI wake'
FM_TEST_GH_STATE=OPEN
assert_contains "$(poll_pr 54)" ci-pass 'the same green checks must wake while the PR is open'
pass 'a closed PR with green checks publishes no CI outcome'
