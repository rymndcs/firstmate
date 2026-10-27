#!/usr/bin/env bash
# Behavior tests for PR review activity, conflict wakes and review learning.
# Learning runs through the process-to-event runner, so these tests start its
# sources directly or through reconcile and never wait for a production bound.
set -eu
# shellcheck source=tests/pr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-helpers.sh"

export HOME="$PR_TMP/private-home" FM_PROCEVENT_CLAIM_ROOT="$PR_TMP/claims"
export FM_TEST_ACTIVITY="$PR_TMP/activity" FM_TEST_MERGEABLE=MERGEABLE FM_TEST_GH_AUTHOR=alice
export FM_TEST_GH_BUCKETS=pending FM_TEST_GH_CHECK_RC=8
mkdir -p "$HOME" "$FM_TEST_ACTIVITY"
mv "$PR_TMP/fakebin/gh" "$PR_TMP/fakebin/gh-original"
cat > "$PR_TMP/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *'--json state,mergeable,author'*)
    state=$FM_TEST_GH_STATE
    case " $* " in *" ${FM_TEST_GH_MERGED_URL:-none} "*) state=MERGED ;; esac
    printf '%s|%s|%s\n' "$state" "$FM_TEST_MERGEABLE" "$FM_TEST_GH_AUTHOR" ;;
  *'--json state '*) printf '%s\n' "${FM_TEST_GH_RECHECK_STATE:-$FM_TEST_GH_STATE}" ;;
  *'api '*)
    spec=$(printf '%s\n' "$*" | sed -nE 's#.*/(pulls|issues)/([0-9]+)/(comments|reviews)\?.*#\2.\1-\3#p')
    case "$spec" in
      *.issues-comments) file="$FM_TEST_ACTIVITY/${spec%%.*}.issues" ;;
      *.pulls-comments) file="$FM_TEST_ACTIVITY/${spec%%.*}.comments" ;;
      *.pulls-reviews) file="$FM_TEST_ACTIVITY/${spec%%.*}.reviews" ;;
      *) exit 1 ;;
    esac
    if [ -x "$file.sh" ]; then exec "$file.sh"; fi
    if [ -f "$file" ]; then cat "$file"; else printf '[[]]\n'; fi ;;
  *) exec "$(dirname "$0")/gh-original" "$@" ;;
esac
FAKE
chmod +x "$PR_TMP/fakebin/gh"

set_items() {  # <pr-number> <comments|reviews|issues> <json-items>
  printf '[[%s]]\n' "$3" > "$FM_TEST_ACTIVITY/$1.$2"
}
item() {  # <id> <login> <body> <link> [extra-json-fields]
  printf '{"id":%s,"user":{"login":"%s"},"body":"%s","html_url":"%s"%s}' "$1" "$2" "$3" "$4" "${5:+,$5}"
}
learn_sources() {
  local f
  for f in "$FM_HOME/state/procevent/"learn-*.source; do
    [ -e "$f" ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.source}"
  done
}
start_learning() {
  local id
  for id in $(learn_sources); do
    "$PR_CODE/bin/fm-procevent.sh" start "$id" > /dev/null 2>&1 || fail "learning source $id did not complete"
  done
}
handle_learning() {
  local result r
  for result in "$FM_HOME/state/procevent-inbox/"learn-*.result; do
    [ -e "$result" ] || continue
    r=${result##*/}
    r=${r%.result}
    "$PR_CODE/bin/fm-procevent.sh" handled "${r%.*}" "${r##*.}" > /dev/null
  done
}
learned_count() {
  if [ -f "$FM_TEST_ACTIVITY/learned" ]; then wc -l < "$FM_TEST_ACTIVITY/learned" | tr -d ' '; else echo 0; fi
}
await_dead() {  # <pid> <message>
  for _ in $(seq 200); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.05
  done
  fail "$2"
}
hook="$HOME/.claude/skills/adv-review/bin/learn-from-review"
install_hook() {
  mkdir -p "${hook%/*}"
  cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_ACTIVITY/learned"
case "$(cat "$FM_TEST_ACTIVITY/hook-mode" 2>/dev/null)" in
  slow)
    sleep 300 &
    printf '%s\n' "$!" > "$FM_TEST_ACTIVITY/hook-child.pid"
    printf '%s\n' "$$" > "$FM_TEST_ACTIVITY/hook.pid"
    wait ;;
  straggler)
    sleep 300 &
    printf '%s\n' "$!" > "$FM_TEST_ACTIVITY/straggler.pid" ;;
  *) printf 'learned successfully\n'; exit 7 ;;
esac
HOOK
  chmod +x "$hook"
}

write_pr_task task-a
register_pr task-a
printf 'not json\n' > "$FM_TEST_ACTIVITY/42.comments"
set_items 42 issues "$(item 1 josh 'Historical finding' "$url#issuecomment-1")"
[ -z "$(poll_pr)" ] || fail 'a failed first snapshot must stay silent'
printf '[[]]\n' > "$FM_TEST_ACTIVITY/42.comments"
out=$(poll_pr)
assert_not_contains "$out" 'comment=1 ' 'the first successful snapshot must report no historical activity'
set_items 42 issues "$(item 1 josh 'Historical finding' "$url#issuecomment-1"),$(item 2 josh 'Fresh finding' "$url#issuecomment-2")"
out=$(poll_pr)
assert_contains "$out" 'comment=2 author=josh Fresh finding' 'activity after the baseline must wake'
assert_not_contains "$out" 'comment=1 ' 'baseline activity must never be reported later'
drain_pr > "$PR_TMP/baseline"
assert_no_grep 'comment=1 ' "$PR_TMP/baseline" 'baseline activity must not be queued'
pass 'the first successful snapshot is a silent baseline and a failed snapshot does not consume it'

set_items 42 issues "$(item 3 alice 'Owner note' "$url#issuecomment-3"),$(item 4 rymndcs 'Captain on a teammate PR' "$url#issuecomment-4")"
FM_TEST_GH_AUTHOR=''
[ -z "$(poll_pr)" ] || fail 'an unknown PR owner must not publish comments'
FM_TEST_GH_AUTHOR=alice
set_items 42 comments "$(item 201 'pr-review-watch[bot]' 'Reply after resolution\n<!-- pr-review-watch -->' "$url#discussion_r201" '"in_reply_to_id":100,"pull_request_review_id":80')"
out=$(poll_pr)
assert_contains "$out" 'thread=100 comment=201' 'a reply on a resolved thread must wake'
assert_contains "$out" 'author=pr-review-watch[bot]' 'bot reviewers count'
assert_contains "$out" 'Reply after resolution' 'wake must include excerpt'
assert_contains "$out" 'comment=4 author=rymndcs' 'a non-owner captain comment must wake'
assert_not_contains "$out" 'comment=3 ' 'the actual PR owner comments must stay silent'
assert_contains "$out" 'learn-from-review: not installed' 'absent learning command must not prevent wake'
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail 'one batch must produce one wake'
[ -z "$(poll_pr)" ] || fail 'same resolved reply must never repeat'
drain_pr > "$PR_TMP/activity-wakes"
[ "$(grep -c 'comment=201' "$PR_TMP/activity-wakes")" = 1 ] || fail 'one reply must enqueue exactly once'
pass 'resolved-thread replies and non-owner comments wake once while the actual owner stays silent'

set_items 42 reviews "$(item 81 josh 'Review without a thread' "$url#pullrequestreview-81" '"state":"COMMENTED"'),$(item 82 josh '' "$url#pullrequestreview-82" '"state":"COMMENTED"'),$(item 83 josh 'Draft review' "$url#pullrequestreview-83" '"state":"PENDING"')"
out=$(poll_pr)
assert_contains "$out" 'review=81 author=josh' 'standalone review body must wake'
assert_not_contains "$out" 'review=82' 'an empty review body must stay silent'
assert_not_contains "$out" 'review=83' 'a pending review must stay silent'
[ -z "$(poll_pr)" ] || fail 'same standalone review must not repeat'
pass 'review bodies wake exactly once while empty and pending reviews stay silent'

FM_TEST_MERGEABLE=CONFLICTING
assert_contains "$(poll_pr)" 'CONFLICTING' 'conflicts must wake on transition'
[ -z "$(poll_pr)" ] || fail 'remaining conflicting must not wake again'
FM_TEST_MERGEABLE=UNKNOWN
[ -z "$(poll_pr)" ] || fail 'unknown mergeability must not wake'
FM_TEST_MERGEABLE=CONFLICTING
[ -z "$(poll_pr)" ] || fail 'unknown must not reset conflict episode'
FM_TEST_MERGEABLE=MERGEABLE
[ -z "$(poll_pr)" ] || fail 'becoming mergeable must remain silent'
FM_TEST_MERGEABLE=CONFLICTING
assert_contains "$(poll_pr)" 'CONFLICTING' 'a new conflict after mergeability must wake'
FM_TEST_MERGEABLE=MERGEABLE
poll_pr > /dev/null
pass 'conflicts wake only once per episode'

set_items 42 issues "$(item 5 josh 'Closed while reading' "$url#issuecomment-5")"
FM_TEST_GH_RECHECK_STATE=CLOSED
export FM_TEST_GH_RECHECK_STATE
[ -z "$(poll_pr)" ] || fail 'a PR closed during the snapshot must not publish'
unset FM_TEST_GH_RECHECK_STATE
assert_contains "$(poll_pr)" 'comment=5' 'activity unpublished because of a concurrent close must retry while open'
pass 'a PR closing during the snapshot publishes nothing and consumes nothing'

install_hook
mkdir -p "$FM_HOME/config"
printf '# trusted reviewers\nrymndcs\nJosh\n' > "$FM_HOME/config/pr-learning-trust"
set_items 42 issues "$(item 6 josh 'Trusted finding' "$url#issuecomment-6"),$(item 7 stranger 'Outside suggestion' "$url#issuecomment-7"),$(item 8 alice 'Owner reply' "$url#issuecomment-8")"
out=$(poll_pr)
assert_contains "$out" 'comment=6 author=josh' 'trusted comments must wake'
assert_contains "$out" 'comment=7 author=stranger' 'untrusted comments must still wake'
assert_not_contains "$out" 'comment=8 ' 'owner comments must stay silent with learning installed'
assert_contains "$out" 'learn-from-review: queued learn-' 'trusted comments must queue learning'
assert_contains "$out" 'learn-from-review: untrusted author' 'untrusted comments must alert without learning'
assert_absent "$FM_TEST_ACTIVITY/learned" 'the poll must not run learning before the wake'
[ "$(learn_sources | wc -l | tr -d ' ')" = 1 ] || fail 'one batch must register one learning source'
source_id=$(learn_sources)
start_learning
[ "$(learned_count)" = 1 ] || fail 'learning must run once for the one trusted comment'
assert_grep "$url $url#issuecomment-6" "$FM_TEST_ACTIVITY/learned" 'learning receives PR and comment URLs'
[ -z "$(learn_sources)" ] || fail 'a completed learning source must retire itself'
result=$(cat "$FM_HOME/state/procevent-inbox/$source_id".*.result)
assert_contains "$result" "$url#issuecomment-6 exit=7 output=" 'the learning result records the hook exit and output path'
log=$(printf '%s\n' "$result" | sed -n 's/.* output=//p')
assert_grep 'learned successfully' "$log" 'the output path holds the hook output'
drain_pr > "$PR_TMP/learn-wakes"
assert_grep "procevent learn $source_id 1" "$PR_TMP/learn-wakes" 'learning completion must reach firstmate'
[ -z "$(poll_pr)" ] && [ -z "$(learn_sources)" ] || fail 'learning must not repeat with no new activity'
pass 'trusted comments learn asynchronously after the wake while others only alert'

printf 'slow\n' > "$FM_TEST_ACTIVITY/hook-mode"
set_items 42 issues "$(item 9 Rymndcs 'Bounded finding' "$url#issuecomment-9")"
FM_PR_LEARN_TIMEOUT=1 poll_pr > /dev/null
source_id=$(learn_sources)
start_learning
result=$(cat "$FM_HOME/state/procevent-inbox/$source_id".*.result)
assert_contains "$result" "$url#issuecomment-9 exit=124 output=" 'a hook past its bound must be stopped and reported'
await_dead "$(cat "$FM_TEST_ACTIVITY/hook.pid")" 'a timed-out hook must not survive'
await_dead "$(cat "$FM_TEST_ACTIVITY/hook-child.pid")" 'a timed-out hook process group must not survive'
rm -f "$FM_TEST_ACTIVITY/hook.pid" "$FM_TEST_ACTIVITY/hook-child.pid"
pass 'a slow hook is stopped at its bound together with its process group'

set_items 42 issues "$(item 10 josh 'Retired while learning' "$url#issuecomment-10")"
FM_PR_LEARN_TIMEOUT=300 poll_pr > /dev/null
source_id=$(learn_sources)
"$PR_CODE/bin/fm-procevent.sh" start "$source_id" > /dev/null 2>&1 &
await_file "$FM_TEST_ACTIVITY/hook-child.pid" 'fixture: the learning hook did not start'
"$PR_CODE/bin/fm-procevent.sh" retire "$source_id" > /dev/null || fail 'retiring a running learning source failed'
await_dead "$(cat "$FM_TEST_ACTIVITY/hook.pid")" 'retiring learning must stop the hook'
await_dead "$(cat "$FM_TEST_ACTIVITY/hook-child.pid")" 'retiring learning must stop the hook process group'
wait || true
rm -f "$FM_TEST_ACTIVITY/hook.pid" "$FM_TEST_ACTIVITY/hook-child.pid"
pass 'retiring a running learning source stops the hook and its children'

set_items 42 issues "$(item 11 josh 'Runner crash' "$url#issuecomment-11")"
FM_PR_LEARN_TIMEOUT=2 poll_pr > /dev/null
source_id=$(learn_sources)
"$PR_CODE/bin/fm-procevent.sh" start "$source_id" > /dev/null 2>&1 &
await_file "$FM_TEST_ACTIVITY/hook-child.pid" 'fixture: the learning hook did not start'
runner=$(cat "$FM_HOME/state/procevent/$source_id.runner")
kill -KILL -- "-$runner"
wait || true
await_dead "$(cat "$FM_TEST_ACTIVITY/hook.pid")" 'a killed runner must not leave its hook unbounded'
await_dead "$(cat "$FM_TEST_ACTIVITY/hook-child.pid")" 'a killed runner must not leave hook children unbounded'
before=$(learned_count)
start_learning
[ "$(learned_count)" = "$before" ] || fail 'an interrupted invocation must not run again'
result=$(cat "$FM_HOME/state/procevent-inbox/$source_id".*.result)
assert_contains "$result" "$url#issuecomment-11 exit=interrupted output=" 'a restarted source reports the interrupted invocation'
rm -f "$FM_TEST_ACTIVITY/hook.pid" "$FM_TEST_ACTIVITY/hook-child.pid"
pass 'a crashed learning runner keeps the bound and never repeats the invocation'

printf 'straggler\n' > "$FM_TEST_ACTIVITY/hook-mode"
set_items 42 issues "$(item 13 josh 'Leaves a process behind' "$url#issuecomment-13")"
FM_PR_LEARN_TIMEOUT=300 poll_pr > /dev/null
source_id=$(learn_sources)
"$PR_CODE/bin/fm-procevent.sh" start "$source_id" > /dev/null 2>&1 &
learner=$!
await_file "$FM_HOME/state/procevent-inbox/$source_id.1.result" 'a finished hook must end its learning run without waiting for the bound'
wait "$learner" || true
await_dead "$(cat "$FM_TEST_ACTIVITY/straggler.pid")" 'a finished hook must not leave processes behind'
rm -f "$FM_TEST_ACTIVITY/straggler.pid" "$FM_TEST_ACTIVITY/hook-mode"
pass 'a finished hook ends its learning run and leaves no process behind'

set_items 42 issues "$(item 12 josh 'Retry after enqueue failure' "$url#issuecomment-12")"
mv "$FM_HOME/state/.wake-queue" "$FM_HOME/state/.wake-queue.saved"
mkdir "$FM_HOME/state/.wake-queue"
[ -z "$(poll_pr)" ] || fail 'enqueue failure must not claim delivery'
[ -z "$(learn_sources)" ] || fail 'enqueue failure must not leave learning queued'
rmdir "$FM_HOME/state/.wake-queue"
mv "$FM_HOME/state/.wake-queue.saved" "$FM_HOME/state/.wake-queue"
assert_contains "$(poll_pr)" 'comment=12' 'unpublished batch must retry'
before=$(learned_count)
source_id=$(learn_sources)
argv_file="$FM_HOME/state/procevent/$source_id.source"
learn_argv=()
while IFS= read -r arg; do learn_argv+=("$arg"); done < <(sed -n '/^argv:$/,$p' "$argv_file" | tail -n +2)
start_learning
[ "$(learned_count)" = $((before + 1)) ] || fail 'a delivery retry must learn exactly once'
again=$("${learn_argv[@]}")
[ "$(learned_count)" = $((before + 1)) ] || fail 'a repeated learning run must reuse the recorded invocation'
assert_contains "$again" "$url#issuecomment-12 exit=7 output=" 'a repeated learning run reports the recorded exit'
pass 'enqueue retries and repeated learning runs never repeat an invocation'

for bound in bogus 0; do
  bogus=$("$PR_CODE/bin/fm-procevent-learn.sh" run "$bound" "$url" "$FM_HOME/state/.bogus-learning" issues:99 "$url#issuecomment-99")
  assert_contains "$bogus" 'exit=invalid-timeout' "bound $bound must refuse to run the hook"
  [ "$(learned_count)" = $((before + 1)) ] || fail "bound $bound must not invoke the hook"
done
pass 'learning refuses to run without a valid bound'

write_pr_task task-mixed
mixed=https://github.com/Owner/repo/pull/44
"$PR_CODE/bin/fm-pr-check.sh" task-mixed "$mixed" > /dev/null 2>&1 || fail 'mixed-case registration failed'
poll_mixed() { "$PR_CODE/bin/fm-pr-poll.sh" --validated github "$mixed" github.com Owner/repo 44; }
poll_mixed > /dev/null
set_items 44 issues "$(item 21 josh 'Real finding' 'https://github.com/owner/repo/pull/44#issuecomment-21'),$(item 22 josh 'Unexpected link' 'https://github.com/owner/repo/pull/44/files#r22'),{\"id\":\"bad\",\"user\":{\"login\":\"josh\"}},$(item 23 josh 'Other repository' 'https://github.com/elsewhere/repo/pull/44#issuecomment-23'),$(item 24 josh 'Bad anchor' 'https://github.com/owner/repo/pull/44#bad anchor')"
out=$(poll_mixed)
assert_contains "$out" "comment=21 author=josh Real finding $mixed#issuecomment-21" 'a case-different link must be canonicalized to the registration'
assert_contains "$out" 'comment=22 author=josh Unexpected link [link unverified]' 'an unexpected link must still alert'
assert_contains "$out" 'comment=23 author=josh Other repository [link unverified]' 'a foreign link must still alert'
assert_contains "$out" 'comment=24 author=josh Bad anchor [link unverified]' 'a malformed anchor must still alert'
assert_not_contains "$out" 'elsewhere' 'an unverified link must never be published'
[ "$(learn_sources | wc -l | tr -d ' ')" = 1 ] || fail 'the mixed batch must register one learning source'
before=$(learned_count)
start_learning
[ "$(learned_count)" = $((before + 1)) ] || fail 'only verified links may be learned'
assert_grep "$mixed $mixed#issuecomment-21" "$FM_TEST_ACTIVITY/learned" 'learning receives canonical URLs'
pass 'returned links are canonicalized case-insensitively and malformed items never discard a batch'

write_pr_task task-b
"$PR_CODE/bin/fm-pr-check.sh" task-b https://github.com/owner/repo/pull/43 > /dev/null 2>&1 || fail 'registration failed'
handle_learning
drain_pr > /dev/null
cat > "$FM_TEST_ACTIVITY/42.issues.sh" <<'CHATTY'
#!/usr/bin/env bash
n=$(( $(cat "$FM_TEST_ACTIVITY/chatty" 2>/dev/null || echo 500) + 1 ))
printf '%s\n' "$n" > "$FM_TEST_ACTIVITY/chatty"
printf '[[{"id":%s,"user":{"login":"chatty"},"body":"msg %s","html_url":"https://github.com/owner/repo/pull/42#issuecomment-%s"}]]\n' "$n" "$n" "$n"
CHATTY
chmod +x "$FM_TEST_ACTIVITY/42.issues.sh"
FM_TEST_GH_BUCKETS=pass FM_TEST_GH_CHECK_RC=0
FM_TEST_GH_HEAD=abababababababababababababababababababab
out=$(FM_CHECK_INTERVAL=0 FM_POLL=1 "$PR_CODE/bin/fm-watch-checkpoint.sh" --seconds 15)
assert_contains "$out" 'check:' 'the real watcher must wake for the sweep'
drain_pr > "$PR_TMP/fair-sweep"
grep -Eq 'comment=50[0-9] ' "$PR_TMP/fair-sweep" || fail 'the busy PR must still publish its activity'
assert_grep 'task-b.check.sh: ci-pass' "$PR_TMP/fair-sweep" 'a later PR must be polled in the same sweep as a busy earlier PR'
[ "$(grep -Ec 'comment=50[0-9] ' "$PR_TMP/fair-sweep")" = 1 ] || fail 'watcher must not enqueue the activity batch twice'
rm -f "$FM_TEST_ACTIVITY/42.issues.sh"
pass 'every sweep polls every registered PR even when an earlier PR is busy'

key=$(printf '%s' "$url" | shasum -a 256 | awk '{print $1}')
receipt="$FM_HOME/state/.pr-activity-$key"
write_pr_task task-share
register_pr task-share
set_items 42 issues "$(item 600 josh 'Pending learning' "$url#issuecomment-600")"
poll_pr > /dev/null
pending_source=$(learn_sources)
[ -n "$pending_source" ] || fail 'fixture: no pending learning source'
rm -f "$FM_HOME/state/task-share.pr-poll"
"$PR_CODE/bin/fm-pr-activity.sh" sweep
assert_present "$receipt" 'a shared registration must keep the activity receipt'
rm -f "$FM_HOME/state/task-a.pr-poll"
"$PR_CODE/bin/fm-pr-activity.sh" sweep
assert_present "$receipt" 'queued learning work must keep its activity state'
start_learning
"$PR_CODE/bin/fm-pr-activity.sh" sweep
assert_present "$receipt" 'an unhandled learning result must keep its evidence'
handle_learning
mkdir "$receipt.lock"
printf '%s\n' "$$" > "$receipt.lock/pid"
"$PR_CODE/bin/fm-pr-activity.sh" sweep
assert_present "$receipt" 'a sweep must leave state that a running poll holds'
sh -c 'exit 0' &
dead=$!
wait "$dead"
printf '%s\n' "$dead" > "$receipt.lock/pid"
"$PR_CODE/bin/fm-pr-activity.sh" sweep
assert_absent "$receipt" 'a retired PR must drop its activity receipt'
leftover=$(find "$FM_HOME/state" -name ".pr-activity-$key*" | head -1)
[ -z "$leftover" ] || fail "a retired PR must drop its learning logs and lock: $leftover"
pass 'retirement removes activity state only after every registration, learning run and result is done'

write_pr_task task-merge
"$PR_CODE/bin/fm-pr-check.sh" task-merge https://github.com/owner/repo/pull/45 > /dev/null 2>&1 || fail 'registration failed'
poll_pr 45 > /dev/null
merge_receipt="$FM_HOME/state/.pr-activity-$(printf '%s' https://github.com/owner/repo/pull/45 | shasum -a 256 | awk '{print $1}')"
assert_present "$merge_receipt" 'fixture: the open PR has no activity receipt'
drain_pr > /dev/null
export FM_TEST_GH_MERGED_URL=https://github.com/owner/repo/pull/45
out=$(FM_CHECK_INTERVAL=0 FM_POLL=1 "$PR_CODE/bin/fm-watch-checkpoint.sh" --seconds 15)
assert_contains "$out" 'task-merge.check.sh: merged' 'the merged PR must still wake with its exact result'
assert_absent "$merge_receipt" 'the sweep after a merged retirement must drop its activity receipt'
pass 'a merged retirement drops the activity receipt in the same watcher sweep'
