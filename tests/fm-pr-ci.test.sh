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

for buckets in '' garbage; do
  FM_TEST_GH_HEAD=3333333333333333333333333333333333333333
  FM_TEST_GH_BUCKETS=$buckets
  [ -z "$(poll_pr)" ] || fail 'empty or malformed checks must not become green'
done
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

FM_TEST_GH_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir "$FM_HOME/state/.wake-queue.blocked"
mv "$FM_HOME/state/.wake-queue" "$FM_HOME/state/.wake-queue.blocked/saved"
mkdir "$FM_HOME/state/.wake-queue"
[ -z "$(poll_pr)" ] || fail 'failed durable enqueue must not announce or consume observation'
rmdir "$FM_HOME/state/.wake-queue"
mv "$FM_HOME/state/.wake-queue.blocked/saved" "$FM_HOME/state/.wake-queue"
rmdir "$FM_HOME/state/.wake-queue.blocked"
assert_contains "$(poll_pr)" ci-pass 'CI observation must retry when enqueue recovers'
pass 'queue failure cannot consume an undelivered CI observation'
