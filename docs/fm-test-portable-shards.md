# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-10-25 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 23 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 35373 | `tests/fm-x-mode.test.sh` |
| 33306 | `tests/fm-backend-herdr.test.sh` |
| 26056 | `tests/fm-arm-pretool-check.test.sh` |
| 22207 | `tests/fm-test-run.test.sh` |
| 20417 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 18359 | `tests/fm-cd-pretool-check.test.sh` |
| 14643 | `tests/fm-crew-state.test.sh` |
| 9262 | `tests/fm-pr-merge.test.sh` |
| 8698 | `tests/fm-herdr-lab.test.sh` |
| 5825 | `tests/fm-brief.test.sh` |
| 5257 | `tests/fm-grok-harness.test.sh` |
| 4725 | `tests/fm-review-diff.test.sh` |
| 3531 | `tests/fm-lint.test.sh` |
| 3421 | `tests/fm-composer-ghost.test.sh` |
| 3233 | `tests/fm-send-popup-settle.test.sh` |
| 1970 | `tests/fm-tmux-submit-busy.test.sh` |
| 1833 | `tests/fm-send-strict.test.sh` |
| 1671 | `tests/fm-send-settle.test.sh` |
| 1287 | `tests/fm-spawn-batch.test.sh` |
| 382 | `tests/fm-supervision-instructions.test.sh` |
| 95 | `tests/fm-transition-lib.test.sh` |
| 63 | `tests/fm-composer-lib.test.sh` |
| 21 | `tests/fm-pi-primary-types.test.sh` |

## Parallel lanes

The two parallel lanes retain their established membership after removing the retired project-memory helper test.
The estimates below sum the refreshed concurrent-proof durations for each lane.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 119231 ms |
| `portable-parallel-2` | 12 | 102404 ms |
| imbalance | | 16827 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints came from that run's `fm-test-timing-portable-serial` artifact on 2026-08-02, where the lane ran 69 scripts in 1143762 ms of serial work.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 15 | 285945 ms (~285.9 s) |
| `portable-serial-2of4` | 18 | 285944 ms (~285.9 s) |
| `portable-serial-3of4` | 17 | 285929 ms (~285.9 s) |
| `portable-serial-4of4` | 19 | 285944 ms (~285.9 s) |
| imbalance | | 16 ms |

The single longest script, `tests/fm-pr-check-security.test.sh` at 199573 ms, is the floor for any shard count.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above:

```sh
gh run download <run-id> -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-4 | 15 | Each balanced shard is about five minutes, leaving roughly 3x hang-tripwire margin. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
