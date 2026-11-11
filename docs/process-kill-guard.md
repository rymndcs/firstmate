# Scoped process-kill guard

The process-kill guard prevents an agent from accidentally selecting other agents for termination.
`bin/fm-process-command-policy.mjs` owns the decision and imports shell classification from `bin/fm-arm-command-policy.mjs`.
`bin/fm-process-pretool-check.sh` owns scope discovery, transport, exact invocation syntax, and failure rendering; its header and `--help` describe those mechanics.

## Scope

The user-level hook is silent outside a recorded task worktree or the no-mistakes directory.
Scope uses the hook process's physical working directory, with path-component boundaries and symlink resolution.
Task directories come from `worktree=` in the selected home's `state/*.meta`; secondmate records discover child homes, whose task records are also inspected.
A secondmate home itself is not a task directory merely because its own record contains `worktree=`.
The user hook's default home is the installed code root; generated worker hooks pin their originating home explicitly.
Scope does not depend on a model-supplied environment marker identifying a validation agent.

Within confirmed scope, malformed input, unavailable runtime or policy, and classifier failure refuse execution.
Outside scope, no input parsing or Node invocation occurs.
Existing primary watcher policy and its transport remain independent and retain their current behavior.

## Decisions and limits

I use explicit positive PID arguments as the permitted termination form.
For example, `kill -TERM 12345` passes, while `kill "$(pgrep -f agent)"`, `pkill -f agent -n -P 12345`, and `pgrep agent | xargs kill` are refused.
Read-only `pgrep`, quoted documentation text, searches such as `find . -name '*pkill*'` or `rg -l killall | xargs wc -l`, and lookups such as `command -v pkill` pass.
Signal selection and multiple explicit PIDs are supported; dynamic PID expansions, zero, negative groups, and implicit targets are refused.
Pattern-based `pkill` and `killall` are refused even with parent or process-group selectors: the hook cannot establish that a shared group belongs exclusively to the caller, and options after a pattern do not provide portable containment.
Inspect first in a separate read-only call, then terminate the specific observed PID.

The shared lexer distinguishes executed commands from data and recursively exposes literal shell payloads, groups, substitutions, here-strings, heredocs fed to a shell, and substitutions inside unquoted-delimiter heredoc bodies.
A termination command reaching an execution sink is refused: `xargs`, `parallel`, `find -exec`/`-execdir`/`-ok`/`-okdir`, and wrappers that run their arguments such as `nice`, `setsid`, `stdbuf`, `time`, `doas` and `watch`.
Unsupported compound grammar that mentions a termination command is refused.
Opaque dynamic shell payloads and malformed syntax are refused rather than guessed safe.
This is a guard against visible shell-command mistakes, not a sandbox against deliberately hiding a kill inside an arbitrary executable, script file, interpreter program, alias, or prior-session variable.
It does not inspect the body of every executable a worker launches, intercept operating-system signals, or retroactively install hooks into already-running workers.

## Coverage and installation

| Harness | Coverage |
| --- | --- |
| Claude workers | New launches receive a Bash PreToolUse hook in their generated local settings. |
| Claude validation | Requires the additive user-level registration below after the executable is installed; project settings alone are excluded by no-mistakes' project-instruction isolation. |
| Codex workers | Requires the additive user-level registration below and approval of that hook’s current definition in Codex; generated project hooks alone did not enforce in the live check. |
| Codex validation | The same scoped Codex user hook covers no-mistakes working directories once registered and trusted. |
| OpenCode | No worker process-kill hook is installed. |
| Pi / pi-signed | No worker process-kill hook is installed. |
| Grok | No worker process-kill hook is installed; global registration and trust remain separate integration work. |
| Kimi | No blocking process-kill integration is established. |
| omp | Primary-only, outside this worker/validation change. |

The hook registration must be merged into each harness’s existing user-level Bash PreToolUse hook array, preserving its other entries, after the guard is installed at a stable path.
The worker launcher does not edit user-level settings.
For Claude and Codex, the additive hook object at an installation in `/path/to/firstmate` is:

```json
{
  "type": "command",
  "command": "bash '/path/to/firstmate/bin/fm-process-pretool-check.sh'"
}
```

For Claude, add it inside a `PreToolUse` entry with matcher `Bash` in the user’s `settings.json`; for Codex, add the same object to such an entry in the user’s `hooks.json`.
Approve only this hook’s current definition through Codex’s normal hook trust flow; merely writing the JSON does not enable an untrusted hook.
No hook-trust bypass flag is used.

Both the transport and its Node policy dependencies must remain available at that path.
Do not point a persistent user hook at a disposable task directory.

## Verification

`tests/fm-process-pretool-check.test.sh` drives the public entry point with fake command text and verifies the scope boundary, command decisions and runtime failures without executing a pattern kill.
`tests/fm-spawn-dispatch-profile.test.sh` executes the generated Claude hook against the public guard.
`tests/fm-process-guard-live-e2e.test.sh` is the opt-in real Claude/Codex enforcement proof; it maps a harmless marker-write attempt to fake kill text at the hook, so no real pattern kill can run even if enforcement breaks.
The dated harness results belong in [runtime backend verification](verification/runtime-backends.md).
