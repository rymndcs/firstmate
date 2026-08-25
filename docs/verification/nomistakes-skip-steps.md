# no-mistakes pipeline step-skip verification

Audience: maintainer verification.

This record holds the version-scoped evidence behind one claim in the check contract that `bin/fm-brief.sh --checks targeted` generates: that `no-mistakes axi run --skip` is the pipeline `test` step's only scoping control, and that it accepts `test`.
`bin/fm-brief.sh`'s header owns the contract, and `tests/fm-brief.test.sh` owns the regression that the generated contract names that step at all.

Verified on 2026-08-25 on Linux (WSL2, kernel 6.18.33.2) against the installed build.

## Why a verdict is needed at all

A ship task runs tests in two places: the project's own local CI runner, and the pipeline's own `test` step.
The pipeline step runs the whole suite regardless of what the worker ran locally, so a check instruction that scopes only the local runner leaves it unscoped.
Keeping it proportionate therefore needs a supported control, not an approach the worker invents; the generated contract names one, so that name has to be true.

## The installed run surface

```sh
$ no-mistakes --version
no-mistakes version v1.46.0 (20892e6) 2026-08-06T06:41:38Z
$ no-mistakes axi run --help
Flags:
  -h, --help            help for run
      --intent string   what the user set out to accomplish (not a description of the diff); used instead of inferring from transcripts (required to start a run)
      --skip string     comma-separated pipeline steps to skip
  -y, --yes             auto-resolve every gate (fix findings, then accept) until a decision point or outcome
```

`--skip` is the only flag on the subcommand that scopes what runs.

## The verdict against the real build

Help text names no valid step values, so the accepted set was established from the binary's own refusal rather than assumed.
Run in a throwaway git repo with no no-mistakes gate installed, so no pipeline could start:

```sh
$ no-mistakes axi run --skip bogus
error: "unknown step \"bogus\""
help[1]: "Valid steps: intent, rebase, review, test, document, lint, push, pr, ci"

$ no-mistakes axi run --skip test
error: repo not initialized (run 'no-mistakes init' first)
help[1]: Run `no-mistakes init` to set up the gate in this repository
```

`--skip` is validated before the repository is inspected, so the second run proves `test` passed that validation: an unaccepted value would have been refused first, exactly as `bogus` was.
`test` is therefore an accepted step name, and skipping it is the supported way to keep that step proportionate.

## What is deliberately NOT verified live

No pipeline run was started, so this record does not claim what a run does after `--skip test` is accepted.
The refusal path above is the whole guarantee the generated contract depends on: that the flag exists, scopes the pipeline, and takes `test`.
