#!/usr/bin/env bash
# Discover a ship task's own GitHub PR and register it through fm-pr-check.sh.
# Only kind=ship tasks are eligible. A task's own PR is, in precedence order:
# an explicit fm-pr-check.sh registration, then the first status line of the
# form `done: PR <url> ...` or `pushed ... to PR <url>`. Other status URLs are
# references, never registrations. The backlog is never a source: it stores a
# linked PR and a cited PR as the same bytes.
# A promoted scout's status lines from before promotion never count:
# fm-promote.sh records the status log's byte length as promoted_status_offset=
# in the metadata, and discovery reads only after it. A task spawned as a ship
# has no offset and reads its whole status log.
# On those own-PR lines the URL may be bare, `backticked`, <angled>, a Markdown
# link [text](url), or followed by : or .
# Discovery is GitHub-only; register a GitLab merge request with fm-pr-check.sh.
# It registers through fm-pr-check.sh --if-unregistered, which owns the
# registration lock and skips a task that already has a registration.
# A registration prints fm-pr-check.sh's whole output to stderr, so the
# pr-ready guidance and Linear diagnostics arrive once, at registration, and the
# caller's stdout stays unchanged.
# Failures print one diagnostic per task instead and leave the caller
# successful; a later invocation retries.
# Usage: fm-pr-auto-register.sh [<task-id> | --all]
# Wake drain calls --all after releasing its queue lock; spawn calls <task-id>
# after writing metadata, on both fresh launches and resumes.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
  --all) set -- ;;
  '') echo 'usage: fm-pr-auto-register.sh [<task-id> | --all]' >&2; exit 2 ;;
  *) fm_pr_task_id_valid "$1" && [ "$#" -eq 1 ] || exit 2 ;;
esac

candidates() {
  perl -MFcntl=:DEFAULT -e '
    sysopen(my $f, $ARGV[0], O_RDONLY | O_NOFOLLOW) or exit;
    exit unless -f $f;
    seek($f, $ARGV[1], 0);
    while (<$f>) {
      next unless /^done: PR (.*)/ || /^pushed (?:.* )?to PR (.*)/;
      my $rest = $1;
      my $url = $rest =~ /^\[[^\]]*\]\(([^)\s]+)\)/ ? $1
        : $rest =~ /^`([^`\s]+)`/ ? $1
        : $rest =~ /^<([^>\s]+)>/ ? $1
        : ($rest =~ /^(\S*)/)[0] =~ s/[:.]+$//r;
      print "$url\n" if $url =~ m{^https://github\.com/};
    }
  ' "$STATE/$1.status" "$2"
}

register_one() {
  local id=$1 meta="$STATE/$1.meta" url='' candidate offset out
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ "$(awk '/^kind=/ { kind = substr($0, 6) } END { print kind }' "$meta")" = ship ] || return 0
  offset=$(awk '/^promoted_status_offset=/ { offset = substr($0, 24) } END { print offset + 0 }' "$meta")
  while IFS= read -r candidate; do
    if fm_pr_url_parse "$candidate"; then
      url=$FM_PR_URL
      break
    fi
  done < <(candidates "$id" "$offset")
  [ -n "$url" ] || return 0
  out=$("$SCRIPT_DIR/fm-pr-check.sh" --if-unregistered "$id" "$url" 2>&1) || return 1
  [ -z "$out" ] || printf '%s\n' "$out" >&2
}

if [ "$#" -eq 0 ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    register_one "$id" || printf 'PR_REGISTRATION: %s: automatic PR registration failed; will retry\n' "$id" >&2
  done
else
  register_one "$1" || printf 'PR_REGISTRATION: %s: automatic PR registration failed; will retry\n' "$1" >&2
fi
exit 0
