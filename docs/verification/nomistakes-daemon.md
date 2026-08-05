# Shared no-mistakes daemon verification

Audience: maintainer verification.

This record holds the version-scoped evidence behind `bin/fm-nomistakes-daemon.sh`.
That script's own header owns the contract and the safety direction, `bin/fm-bootstrap.sh` and `bin/fm-teardown.sh` own their call sites, and `tests/fm-nomistakes-daemon.test.sh` plus `tests/fm-teardown.test.sh` own the regressions.

Verified on 2026-08-05 on Linux (WSL2, kernel 6.18.33.2) against the installed build.

## Why a verdict is needed at all

`no-mistakes` runs ONE shared daemon for every lane and home, and starts it lazily.
`treehouse return --help` describes itself as "Terminate lingering processes and return a worktree", and firstmate cannot exclude anything from that sweep.
So a daemon first started by a crewmate lives in that crewmate's worktree process tree and dies when the worktree is returned.
The replacement daemon started from the firstmate home was observed with `/proc/<pid>/cwd -> /home/rymndcs/ai-workspace`, outside every worktree, and is not reachable by the same sweep.

## The installed daemon surface

```sh
$ no-mistakes --version
no-mistakes version v1.41.2 (867d64d) 2026-07-24T06:16:03Z
$ no-mistakes daemon --help
Manage the no-mistakes daemon
...
Available Commands:
  restart     Restart the daemon (stop if running, then start)
  start       Install or refresh the managed daemon service and start it
  status      Check if the daemon is running
  stop        Stop the running daemon
```

`start` is documented as install-or-**refresh**-and-start, which is precisely why the verdict must never guess.
Calling it against a live daemon risks the same outage it exists to prevent, so anything short of proof that the daemon is down resolves to `unknown` and starts nothing.

The daemon is global rather than per-repository: `status` answers identically from inside the repo and from `/`, so a home where no-mistakes was never initialized needs no special case.

```sh
$ no-mistakes daemon status
  ● daemon running (pid 173320)          # exit 0
$ cd / && no-mistakes daemon status
  ● daemon running (pid 173320)          # exit 0
```

That rendered line is the only affirmative text this build emits, and it carries a pid.
The pid is what makes the primary signal a kernel fact rather than a vendor string: the verdict accepts `running` on `kill -0 <pid>` alone, independent of wording.

## The verdict against the real build

```sh
$ bin/fm-nomistakes-daemon.sh status
running
$ bin/fm-nomistakes-daemon.sh ensure
                                        # no output, exit 0
```

`ensure` against a healthy daemon is silent and touches nothing, which is the idempotence guarantee both call sites depend on.

## What is deliberately NOT verified live

The down path was never exercised against the real binary.
Doing so would require stopping the one shared daemon, which kills every concurrently validating lane - the exact incident this work fixes.
That path is covered by `tests/fm-nomistakes-daemon.test.sh` and `tests/fm-teardown.test.sh` against a `no-mistakes` stub, with real processes supplying the live and reaped pids.

This is an acceptable gap because the failure direction is safe by construction.
If a future build rewords its status output, the verdict falls to `unknown`, `ensure` starts nothing and says so, and behavior degrades to the pre-existing lazy start - never to an unwanted restart.
Refresh this record after a no-mistakes upgrade by re-running the two commands under "The verdict against the real build"; a `running` verdict against a live daemon proves both signals still parse.
