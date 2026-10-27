#!/usr/bin/env bash
# Publish new GitHub review, inline reply and conversation comments plus conflict
# transitions through the existing PR poll. Resolved threads are included by
# reading all REST review comments; thread= is the root REST comment ID.
# Usage: fm-pr-activity.sh <github-pr-url>
# Only canonical registrations and OPEN PRs publish. All three comment streams
# are paginated; errors leave their durable last-seen IDs untouched for retry,
# while conflict observations still publish independently.
# The first successful poll reports existing non-owner comments as unseen.
# A URL-scoped state/.pr-activity-<sha256> receipt and lock deduplicate across
# registrations and restarts. UNKNOWN never resets a CONFLICTING episode; only
# MERGEABLE does. Queue before receipt, matching at-least-once wake delivery.
# Each batch has its own queue key so later polls cannot erase undrained comments.
# Each non-owner comment invokes ~/.claude/skills/adv-review/bin/learn-from-review
# with PR and comment URLs when executable. Its exit and private output path are
# included in the batch; absence, failure or timeout cannot suppress the wake.
# Hook output is also its durable invocation receipt, so enqueue retries reuse
# the result; an interrupted invocation is reported rather than run twice.
# FM_PR_LEARN_TIMEOUT bounds each hook (default 10 seconds). No GitHub writes.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-dispatch-axi-lib.sh
. "$SCRIPT_DIR/fm-dispatch-axi-lib.sh"
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi
[ "$#" -eq 1 ] && fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 2
URL=$FM_PR_URL
PROJECT=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
KEY=$(printf '%s' "$URL" | shasum -a 256 | awk '{print $1}') || exit 1
RECEIPT="$STATE/.pr-activity-$KEY"
LOCK="$RECEIPT.lock"
fm_lock_try_acquire "$LOCK" || exit 0
WORK=
trap '[ -z "$WORK" ] || rm -rf -- "${WORK:?}"; fm_lock_release "$LOCK"' EXIT
fm_pr_regular_destination_or_absent "$RECEIPT" || exit 1
WORK=$(mktemp -d "$STATE/.pr-activity.XXXXXX") || exit 1
chmod 0700 "$WORK" || exit 1

publish_one() (
  local id=$1 batch mergeable message='' kind link excerpt note log rc hook
  fm_lock_try_acquire "$STATE/$id.pr-registration.lock" || return 1
  trap 'fm_lock_release "$STATE/$id.pr-registration.lock"' EXIT
  fm_pr_metadata_identity_parse "$STATE/$id.meta" && [ "$FM_PR_META_URL" = "$URL" ] || return 1
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  [ "$(gh pr view "$URL" --json state -q .state 2>/dev/null)" = OPEN ] || return 0
  mergeable=$(gh pr view "$URL" --json mergeable -q .mergeable 2>/dev/null) || mergeable=UNKNOWN
  if gh api "repos/$PROJECT/pulls/$NUMBER/comments?per_page=100" --paginate --slurp > "$WORK/comments" 2>/dev/null \
    && gh api "repos/$PROJECT/pulls/$NUMBER/reviews?per_page=100" --paginate --slurp > "$WORK/reviews" 2>/dev/null \
    && gh api "repos/$PROJECT/issues/$NUMBER/comments?per_page=100" --paginate --slurp > "$WORK/issues" 2>/dev/null; then
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($dir, $receipt, $url) = @ARGV;
    my %seen;
    if (-e $receipt) {
      open my $f, "<", $receipt or die $!;
      while (<$f>) { chomp; $seen{$_} = 1 }
    }
    my @out;
    for my $type (qw(comments reviews issues)) {
      open my $f, "<", "$dir/$type" or die $!;
      my $pages = decode_json(do { local $/; <$f> });
      die "invalid pages" unless ref($pages) eq "ARRAY";
      for my $page (@$pages) {
        die "invalid page" unless ref($page) eq "ARRAY";
        for my $c (@$page) {
          die "invalid comment" unless ref($c) eq "HASH" && ($c->{id} // "") =~ /^\d+$/;
          my $author = $c->{user}{login} // "ghost";
          next if lc($author) eq "rymndcs";
          next if $type eq "reviews" && ($c->{state} // "") eq "PENDING";
          my $body = $c->{body} // "";
          next if $type eq "reviews" && $body !~ /\S/;
          my $key = "$type:$c->{id}";
          next if $seen{$key};
          my $link = $c->{html_url} // "";
          die "invalid link" unless index($link, "$url#") == 0 && $link !~ /[\s\x00-\x1f\x7f]/;
          $author =~ s/[^a-zA-Z0-9_\[\]-]/?/g;
          $body =~ s/[\x00-\x20\x7f]+/ /g;
          $body = substr($body, 0, 160);
          my $detail = $type eq "reviews" ? "review=$c->{id}"
            : $type eq "comments" ? "thread=" . ($c->{in_reply_to_id} // $c->{id}) . " comment=$c->{id} review=" . ($c->{pull_request_review_id} // "unknown")
            : "comment=$c->{id}";
          push @out, join("\t", $key, $link, "$detail author=$author $body");
        }
      }
    }
    print "$_\n" for @out;
  ' "$WORK" "$RECEIPT" "$URL" > "$WORK/new" || : > "$WORK/new"
  else
    : > "$WORK/new"
  fi
  [ "$(gh pr view "$URL" --json state -q .state 2>/dev/null)" = OPEN ] || return 0
  if [ -f "$RECEIPT" ]; then cat "$RECEIPT" > "$WORK/receipt" || return 0; else : > "$WORK/receipt"; fi
  case "$mergeable" in
    CONFLICTING)
      if ! grep -qxF 'mergeable:CONFLICTING' "$WORK/receipt"; then message='CONFLICTING'; fi ;;
    MERGEABLE) ;;
    *) mergeable= ;;
  esac
  if [ -n "$mergeable" ]; then
    sed '/^mergeable:/d' "$WORK/receipt" > "$WORK/next" || return 0
    printf 'mergeable:%s\n' "$mergeable" >> "$WORK/next"
    mv "$WORK/next" "$WORK/receipt" || return 0
  fi
  hook="$HOME/.claude/skills/adv-review/bin/learn-from-review"
  while IFS=$'\t' read -r kind link excerpt; do
    [ -n "$kind" ] || continue
    note='learn-from-review: not installed'
    if [ -x "$hook" ]; then
      log="$RECEIPT.learn-${kind//:/-}"
      if fm_pr_regular_destination_or_absent "$log"; then
        if [ ! -e "$log" ]; then
          (umask 077; set -o noclobber; : > "$log") || return 0
          rc=0
          fm_axi_bounded_run "${FM_PR_LEARN_TIMEOUT:-10}" bash -c 'exec "$@" 2>&1' bash "$hook" "$URL" "$link" > "$log" || rc=$?
          printf '\nlearn-from-review-exit=%s\n' "$rc" >> "$log"
        fi
        rc=$(sed -n 's/^learn-from-review-exit=//p' "$log" | tail -1)
        note="learn-from-review: exit=${rc:-interrupted} output=$log"
      else
        note='learn-from-review: output unavailable'
      fi
    fi
    message="${message:+$message; }$excerpt $link [$note]"
    printf '%s\n' "$kind" >> "$WORK/receipt"
  done < "$WORK/new"
  if [ -n "$message" ]; then
    message="activity PR $URL: $message"
    batch=$(awk -F: '$1 == "batch" { n = $2 } END { print n + 1 }' "$WORK/receipt")
    sed '/^batch:/d' "$WORK/receipt" > "$WORK/next" || return 0
    printf 'batch:%s\n' "$batch" >> "$WORK/next"
    mv "$WORK/next" "$WORK/receipt" || return 0
    fm_wake_append check "$RECEIPT:$batch" "check: $STATE/$id.check.sh: $message" || return 0
  fi
  chmod 0600 "$WORK/receipt" && fm_pr_regular_destination_or_absent "$RECEIPT" \
    && mv -f "$WORK/receipt" "$RECEIPT" || return 0
  [ -z "$message" ] || printf '%s\n' "$message"
)
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  fm_pr_task_id_valid "$id" || continue
  if publish_one "$id"; then exit 0; fi
done
exit 0
