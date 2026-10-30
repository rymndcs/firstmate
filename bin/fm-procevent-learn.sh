#!/usr/bin/env bash
# Review-learning adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-learn.sh run <timeout-seconds> <pr-url> <repo> <log-prefix> <kind> <link> [<kind> <link>...]
#   fm-procevent-learn.sh terminal <result-file>
#
# bin/fm-pr-activity.sh registers one source per review-activity batch, so the
# watcher's reconcile runs learning outside the PR poll and its wake.
# run       Invoke ~/.claude/skills/adv-review/bin/learn-from-review <pr-url>
#           <link> --repo <repo> at most once per comment, where <repo> is the
#           PR's project clone and <link> is GitHub's exact comment html_url.
#           <log-prefix>.learn-<type>-<id> is created
#           exclusively before the invocation, receives its stdout and stderr,
#           then a final learn-from-review-exit=<status> line; a log without
#           that line belongs to an interrupted invocation and is reported as
#           exit=interrupted, never rerun. Prints one
#           `learn-from-review PR <pr-url> <link> exit=<status> output=<log>`
#           line per comment and exits 0. A bound that is not a positive whole
#           number refuses with exit=invalid-timeout.
# terminal  Exit 0 for every result: a learning source runs once.
#
# The hook runs in its own process group with stdin from /dev/null, and the
# whole group ends when the hook does. Exceeding the bound stops the group with
# status 124; a catchable signal to the runner stops it at once; and a watchdog
# inside the group stops it one second after the bound even when the runner and
# its bound wrapper are killed outright.
set -u

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

bounded() {  # <seconds> <argv>...
  # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
  perl -e '
    use POSIX ();
    my $t = shift;
    my $pid = fork;
    exit 125 unless defined $pid;
    if (!$pid) { setpgrp(0, 0); open STDIN, "<", "/dev/null"; exec @ARGV; POSIX::_exit(127) }
    setpgrp($pid, $pid);
    my $dog = fork;
    if (defined $dog && !$dog) {
      setpgrp(0, $pid) or POSIX::_exit(0);
      sleep($t + 1);
      kill "KILL", -$pid;
      POSIX::_exit(0);
    }
    my $stop = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      waitpid $pid, 0;
      waitpid $dog, 0 if $dog;
      exit shift;
    };
    $SIG{ALRM} = sub { $stop->(124) };
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { $stop->(143) };
    alarm $t;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    kill "KILL", -$pid;
    waitpid $dog, 0 if $dog;
    exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
  ' "$@"
}

cmd_run() {
  local timeout=${1-} url=${2-} repo=${3-} prefix=${4-} hook kind link log rc
  shift 4
  hook="$HOME/.claude/skills/adv-review/bin/learn-from-review"
  while [ "$#" -ge 2 ]; do
    kind=$1
    link=$2
    shift 2
    case "$timeout" in
      ''|*[!0-9]*|0*)
        printf 'learn-from-review PR %s %s exit=invalid-timeout\n' "$url" "$link"
        continue ;;
    esac
    log="$prefix.learn-${kind//:/-}"
    if (umask 077; set -o noclobber; : > "$log") 2>/dev/null; then
      rc=0
      bounded "$timeout" "$hook" "$url" "$link" --repo "$repo" >> "$log" 2>&1 || rc=$?
      printf '\nlearn-from-review-exit=%s\n' "$rc" >> "$log"
    fi
    rc=$(sed -n 's/^learn-from-review-exit=//p' "$log" 2>/dev/null | tail -1)
    printf 'learn-from-review PR %s %s exit=%s output=%s\n' "$url" "$link" "${rc:-interrupted}" "$log"
  done
}

case "${1-}" in
  run) shift; cmd_run "$@" ;;
  terminal) exit 0 ;;
  ''|-h|--help|help) usage ;;
  *) printf 'error: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
