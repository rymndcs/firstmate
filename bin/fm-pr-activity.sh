#!/usr/bin/env bash
# Publish new GitHub review, inline reply and conversation comments plus conflict
# transitions through the existing PR poll, and queue review learning for them.
# Usage: fm-pr-activity.sh <github-pr-url> <mergeable> <owner-login>
#        fm-pr-activity.sh sweep
# fm-pr-poll.sh passes the mergeability and PR author it read with the OPEN
# state, and this script re-reads the state once after its snapshot so a PR
# closed meanwhile publishes and consumes nothing.
# Resolved threads are included by reading all REST review comments; thread= is
# the root REST comment ID. Only canonical registrations publish. All three
# comment streams are paginated; a failed stream or an unknown owner leaves the
# durable last-seen IDs untouched for retry, while conflicts still publish.
# The first successful snapshot of a URL records every current item as seen and
# reports none of it; only later activity wakes.
# The PR author's own comments, pending reviews and empty review bodies are
# ignored, and an item without a numeric ID is skipped without failing the rest.
# A returned link must start with the registered URL and "#", compared without
# case, and is published in the registration's casing; any other link is
# withheld, the item alerts as [link unverified] and is never learned.
# A URL-scoped state/.pr-activity-<sha256> receipt and lock deduplicate across
# registrations and restarts. UNKNOWN never resets a CONFLICTING episode; only
# MERGEABLE does. Queue before receipt, matching at-least-once wake delivery.
# Each batch has its own queue key so later polls cannot erase undrained comments.
# Learning: a comment from a login trusted by config/pr-learning-trust (format in
# docs/configuration.md) queues learning when the executable
# ~/.claude/skills/adv-review/bin/learn-from-review exists; other comments note
# "untrusted author" or "not installed" and never learn. Each batch
# registers one learn-<key>-<batch> process-to-event source before its wake is
# queued, retired again if queueing fails, so the poll never runs the hook.
# bin/fm-procevent-learn.sh owns the run, its bound and its invocation receipts;
# FM_PR_LEARN_TIMEOUT (default 10 seconds) is recorded as that bound.
# sweep removes a URL's receipt, lock and learning logs once no armed poll
# sidecar names the URL, no learning source for it is registered and every
# learning result for it is handled; the watcher runs it after each check sweep
# and teardown after removing a task's poll. No GitHub writes.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi

activity_key() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

sweep() {
  local data url armed=' ' path key short keep f
  for data in "$STATE"/*.pr-poll; do
    [ -f "$data" ] && [ ! -L "$data" ] || continue
    url=$(sed -n 2p "$data") || continue
    armed="$armed$(activity_key "$url") "
  done
  for path in "$STATE"/.pr-activity-*; do
    key=${path##*/.pr-activity-}
    key=${key%%.*}
    case "$key" in *[!0-9a-f]*) continue ;; esac
    [ "${#key}" -eq 64 ] || continue
    case "$armed" in *" $key "*) continue ;; esac
    short=${key:0:16}
    keep=0
    for f in "$STATE/procevent/learn-$short-"*.source "$STATE/procevent-inbox/learn-$short-"*.result; do
      [ -e "$f" ] || continue
      case "$f" in *.result) [ ! -e "${f%.result}.handled" ] || continue ;; esac
      keep=1
    done
    [ "$keep" -eq 0 ] || continue
    fm_lock_try_acquire "$STATE/.pr-activity-$key.lock" || continue
    for f in "$STATE/.pr-activity-$key" "$STATE/.pr-activity-$key".learn-*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      rm -f -- "$f"
    done
    fm_lock_release "$STATE/.pr-activity-$key.lock"
  done
}

if [ "${1:-}" = sweep ] && [ "$#" -eq 1 ]; then
  sweep
  exit 0
fi
[ "$#" -eq 3 ] && fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || exit 2
URL=$FM_PR_URL
PROJECT=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
OBSERVED_MERGEABLE=$2
OWNER=$3
KEY=$(activity_key "$URL") || exit 1
RECEIPT="$STATE/.pr-activity-$KEY"
LOCK="$RECEIPT.lock"
fm_lock_try_acquire "$LOCK" || exit 0
WORK=
trap '[ -z "$WORK" ] || rm -rf -- "${WORK:?}"; fm_lock_release "$LOCK"' EXIT
fm_pr_regular_destination_or_absent "$RECEIPT" || exit 1
WORK=$(mktemp -d "$STATE/.pr-activity.XXXXXX") || exit 1
chmod 0700 "$WORK" || exit 1

publish_one() (
  local id=$1 batch mergeable=$OBSERVED_MERGEABLE message='' snapshot='' key mode link text note
  local hook source='' learn=()
  fm_lock_try_acquire "$STATE/$id.pr-registration.lock" || return 1
  trap 'fm_lock_release "$STATE/$id.pr-registration.lock"' EXIT
  fm_pr_metadata_identity_parse "$STATE/$id.meta" && [ "$FM_PR_META_URL" = "$URL" ] || return 1
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  : > "$WORK/new"
  if [ -n "$OWNER" ] \
    && gh api "repos/$PROJECT/pulls/$NUMBER/comments?per_page=100" --paginate --slurp > "$WORK/comments" 2>/dev/null \
    && gh api "repos/$PROJECT/pulls/$NUMBER/reviews?per_page=100" --paginate --slurp > "$WORK/reviews" 2>/dev/null \
    && gh api "repos/$PROJECT/issues/$NUMBER/comments?per_page=100" --paginate --slurp > "$WORK/issues" 2>/dev/null \
    && perl -MJSON::PP -e '
    use strict; use warnings;
    my ($dir, $receipt, $url, $owner, $trust) = @ARGV;
    my (%seen, %trusted);
    if (-e $receipt) {
      open my $f, "<", $receipt or die $!;
      while (<$f>) { chomp; $seen{$_} = 1 }
    }
    if (open my $f, "<", $trust) {
      while (<$f>) { s/#.*//; s/^\s+|\s+$//g; $trusted{lc $_} = 1 if length }
    }
    my $prefix = lc "$url#";
    my @out;
    for my $type (qw(comments reviews issues)) {
      open my $f, "<", "$dir/$type" or die $!;
      my $pages = decode_json(do { local $/; <$f> });
      die "invalid pages" unless ref($pages) eq "ARRAY";
      for my $page (@$pages) {
        die "invalid page" unless ref($page) eq "ARRAY";
        for my $c (@$page) {
          next unless ref($c) eq "HASH" && ($c->{id} // "") =~ /^\d+$/;
          my $author = (ref($c->{user}) eq "HASH" ? $c->{user}{login} : undef) // "ghost";
          next if lc($author) eq lc($owner);
          next if $type eq "reviews" && ($c->{state} // "") eq "PENDING";
          my $body = $c->{body} // "";
          next if $type eq "reviews" && $body !~ /\S/;
          my $key = "$type:$c->{id}";
          next if $seen{$key};
          my $link = $c->{html_url} // "";
          my $anchor = lc(substr($link, 0, length $prefix)) eq $prefix ? substr($link, length $prefix) : "";
          my $mode = $trusted{lc $author} ? "learn" : "alert";
          if ($anchor =~ /^[A-Za-z0-9_-]+$/) { $link = "$url#$anchor" } else { $link = ""; $mode = "unverified" }
          $author =~ s/[^a-zA-Z0-9_\[\]-]/?/g;
          $body =~ s/[\x00-\x20\x7f]+/ /g;
          $body = substr($body, 0, 160);
          my $detail = $type eq "reviews" ? "review=$c->{id}"
            : $type eq "comments" ? "thread=" . ($c->{in_reply_to_id} // $c->{id}) . " comment=$c->{id} review=" . ($c->{pull_request_review_id} // "unknown")
            : "comment=$c->{id}";
          my $text = "$detail author=$author $body " . ($link eq "" ? "[link unverified]" : $link);
          push @out, join("\x1f", $key, $mode, $link, $text);
        }
      }
    }
    print "$_\n" for @out;
  ' "$WORK" "$RECEIPT" "$URL" "$OWNER" "$CONFIG/pr-learning-trust" > "$WORK/new"; then
    snapshot=ok
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
  if [ "$snapshot" = ok ] && ! grep -qxF 'baseline:1' "$WORK/receipt"; then
    cut -d $'\037' -f1 "$WORK/new" >> "$WORK/receipt" || return 0
    printf 'baseline:1\n' >> "$WORK/receipt"
    : > "$WORK/new"
  fi
  hook="$HOME/.claude/skills/adv-review/bin/learn-from-review"
  batch=$(awk -F: '$1 == "batch" { n = $2 } END { print n + 1 }' "$WORK/receipt")
  if [ -x "$hook" ]; then
    while IFS=$'\037' read -r key mode link text; do
      [ "$mode" != learn ] || learn+=("$key" "$link")
    done < "$WORK/new"
  fi
  if [ "${#learn[@]}" -gt 0 ]; then
    source="learn-${KEY:0:16}-$batch"
    FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" register learn "$source" -- \
      "$SCRIPT_DIR/fm-procevent-learn.sh" run "${FM_PR_LEARN_TIMEOUT:-10}" "$URL" "$RECEIPT" "${learn[@]}" \
      > /dev/null 2>&1 || source=
  fi
  while IFS=$'\037' read -r key mode link text; do
    [ -n "$key" ] || continue
    case "$mode" in
      unverified) note= ;;
      *) if [ ! -x "$hook" ]; then note=' [learn-from-review: not installed]'
        elif [ "$mode" = alert ]; then note=' [learn-from-review: untrusted author]'
        elif [ -n "$source" ]; then note=" [learn-from-review: queued $source]"
        else note=' [learn-from-review: not queued]'
        fi ;;
    esac
    message="${message:+$message; }$text$note"
    printf '%s\n' "$key" >> "$WORK/receipt"
  done < "$WORK/new"
  if [ -n "$message" ]; then
    message="activity PR $URL: $message"
    sed '/^batch:/d' "$WORK/receipt" > "$WORK/next" || return 0
    printf 'batch:%s\n' "$batch" >> "$WORK/next"
    mv "$WORK/next" "$WORK/receipt" || return 0
    if ! fm_wake_append check "$RECEIPT:$batch" "check: $STATE/$id.check.sh: $message"; then
      [ -z "$source" ] || FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" retire "$source" > /dev/null 2>&1
      return 0
    fi
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
