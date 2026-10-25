#!/usr/bin/env bash
# Discover a ship task's own GitHub PR and register it through fm-pr-check.sh.
# Only kind=ship tasks are eligible. A task's own PR is, in precedence order:
# an explicit fm-pr-check.sh registration, then the first status line of the
# form `done: PR <url> ...` or `pushed ... to PR <url>`. Other status URLs are
# references, never registrations. The backlog is never a source: it stores a
# linked PR and a cited PR as the same bytes.
# On those own-PR lines the URL may be bare, `backticked`, <angled>, a Markdown
# link [text](url), or followed by : . , or ;.
# Discovery is GitHub-only; register a GitLab merge request with fm-pr-check.sh.
# It registers through fm-pr-check.sh --if-unregistered, which owns the
# registration lock and skips a task that already has a registration.
# Failures print one diagnostic per task and leave the caller successful; a
# later invocation retries.
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
    while (<$f>) {
      next unless /^done: PR (\S+)/ || /^pushed (?:.* )?to PR (\S+)/;
      my $token = $1;
      my $url = $token =~ /^\[[^\]]*\]\(([^)]+)\)/ ? $1
        : $token =~ /^`([^`]+)`/ ? $1
        : $token =~ /^<([^>]+)>/ ? $1
        : $token =~ s/[:.,;]+$//r;
      print "$url\n" if $url =~ m{^https://github\.com/};
    }
  ' "$STATE/$1.status"
}

register_one() {
  local id=$1 meta="$STATE/$1.meta" url='' candidate
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ "$(awk '/^kind=/ { kind = substr($0, 6) } END { print kind }' "$meta")" = ship ] || return 0
  while IFS= read -r candidate; do
    if fm_pr_url_parse "$candidate"; then
      url=$FM_PR_URL
      break
    fi
  done < <(candidates "$id")
  [ -n "$url" ] || return 0
  "$SCRIPT_DIR/fm-pr-check.sh" --if-unregistered "$id" "$url" > /dev/null 2>&1
}

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
