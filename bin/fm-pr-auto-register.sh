#!/usr/bin/env bash
# Discover a task's GitHub PR in its own status log or exact backlog item and
# register it through fm-pr-check.sh. Latest status URL wins over backlog links.
# A successful automatic registration is remembered across drains and resumes,
# including after the merge poll retires. Failures print one diagnostic per task
# and leave the caller successful; a later invocation retries.
# Usage: fm-pr-auto-register.sh [<task-id> | --all]
# Wake drain calls --all after releasing its queue lock; spawn calls <task-id>
# after writing metadata, on both fresh launches and resumes.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
  --all) set -- ;;
  '') echo 'usage: fm-pr-auto-register.sh [<task-id> | --all]' >&2; exit 2 ;;
  *) fm_pr_task_id_valid "$1" && [ "$#" -eq 1 ] || exit 2 ;;
esac

candidates() {
  perl -MFcntl=:DEFAULT -e '
    my ($status, $backlog, $id) = @ARGV;
    sub open_record {
      my ($path) = @_;
      sysopen(my $f, $path, O_RDONLY | O_NOFOLLOW) or return;
      return unless -f $f;
      return $f;
    }
    if (my $f = open_record($backlog)) {
      my $own = 0;
      while (<$f>) {
        if (/^- \[[ x]\] (\S+)/) { $own = $1 eq $id; next; }
        if (/^\S/) { $own = 0; }
        next unless $own && /^\s+links:\s+(.*)/;
        for (split /\s+/, $1) { print "$1\n" if /^pr:(https:\/\/github\.com\/\S+)$/; }
      }
    }
    if (my $f = open_record($status)) {
      while (<$f>) {
        for (split /\s+/) {
          s/^[([]//; s/[),.;\]]+$//;
          print "$_\n" if m{^https://github\.com/};
        }
      }
    }
  ' "$STATE/$1.status" "$DATA/backlog.md" "$1"
}

register_one() (
  local id=$1 meta="$STATE/$1.meta" receipt="$STATE/$1.pr-auto" url='' candidate tmp=''
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  fm_lock_try_acquire "$STATE/$id.pr-auto.lock" || return 0
  trap 'fm_lock_release "$STATE/$id.pr-auto.lock"; [ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
  while IFS= read -r candidate; do
    fm_pr_url_parse "$candidate" && url=$FM_PR_URL
  done < <(candidates "$id")
  [ -n "$url" ] || return 0
  fm_pr_regular_destination_or_absent "$receipt" || return 1
  if [ "$(cat "$receipt" 2>/dev/null || true)" = "$url" ] \
    && fm_pr_metadata_identity_parse "$meta" && [ "$FM_PR_META_URL" = "$url" ]; then
    return 0
  fi
  if ! fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
    || [ "$FM_PR_META_URL" != "$url" ]; then
    "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$url" > /dev/null 2>&1 || return 1
  fi
  tmp=$(mktemp "$STATE/.pr-auto.XXXXXX") || return 1
  printf '%s\n' "$url" > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$receipt" || return 1
  tmp=''
)

if [ "$#" -eq 0 ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    register_one "$id" 2>/dev/null || printf 'PR_REGISTRATION: %s: automatic PR registration failed; will retry\n' "$id" >&2
  done
else
  register_one "$1" 2>/dev/null || printf 'PR_REGISTRATION: %s: automatic PR registration failed; will retry\n' "$1" >&2
fi
exit 0
