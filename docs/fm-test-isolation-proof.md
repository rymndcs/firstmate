# Firstmate test isolation proof

This record is the concurrent isolation proof for the portable parallel candidate set.
`bin/fm-test-isolation-proof.sh` is the authoritative harness and `docs/fm-test-isolation-proof.json` is the machine-readable result.
`bin/fm-test-run.sh` owns the production lane partition.

## Verification

- Date: 2026-10-25
- Command: `bin/fm-test-isolation-proof.sh --jobs 4 --json "$PWD/data/fm-load-claude-local-md/evidence/isolation-final.json"`
- The resulting JSON is archived at `docs/fm-test-isolation-proof.json`.
- Result: `FM_ISOLATION_SUMMARY total=23 failed=0 concurrency=4 duration_ms=100691`

| Field | Value |
|---|---|
| run_id | fm-isolation-1792923413092-47388 |
| started_at | 2026-10-25T10:16:53Z |
| finished_at | 2026-10-25T10:18:33Z |
| concurrency | 4 |
| candidates | 23 |
| failed | 0 |
| wall duration | 100691 ms |

## Candidate set

- `tests/fm-arm-pretool-check.test.sh`
- `tests/fm-backend-herdr.test.sh`
- `tests/fm-brief.test.sh`
- `tests/fm-cd-pretool-check.test.sh`
- `tests/fm-composer-ghost.test.sh`
- `tests/fm-composer-lib.test.sh`
- `tests/fm-crew-state.test.sh`
- `tests/fm-decision-hold-lifecycle.test.sh`
- `tests/fm-grok-harness.test.sh`
- `tests/fm-herdr-lab.test.sh`
- `tests/fm-lint.test.sh`
- `tests/fm-pi-primary-types.test.sh`
- `tests/fm-pr-merge.test.sh`
- `tests/fm-review-diff.test.sh`
- `tests/fm-send-popup-settle.test.sh`
- `tests/fm-send-settle.test.sh`
- `tests/fm-send-strict.test.sh`
- `tests/fm-spawn-batch.test.sh`
- `tests/fm-supervision-instructions.test.sh`
- `tests/fm-test-run.test.sh`
- `tests/fm-tmux-submit-busy.test.sh`
- `tests/fm-transition-lib.test.sh`
- `tests/fm-x-mode.test.sh`

## Durations

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 35373 | 0 | 23 | `tests/fm-x-mode.test.sh` |
| 33306 | 0 | 2 | `tests/fm-backend-herdr.test.sh` |
| 26056 | 0 | 1 | `tests/fm-arm-pretool-check.test.sh` |
| 22207 | 0 | 20 | `tests/fm-test-run.test.sh` |
| 20417 | 0 | 8 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 18359 | 0 | 4 | `tests/fm-cd-pretool-check.test.sh` |
| 14643 | 0 | 7 | `tests/fm-crew-state.test.sh` |
| 9262 | 0 | 13 | `tests/fm-pr-merge.test.sh` |
| 8698 | 0 | 10 | `tests/fm-herdr-lab.test.sh` |
| 5825 | 0 | 3 | `tests/fm-brief.test.sh` |
| 5257 | 0 | 9 | `tests/fm-grok-harness.test.sh` |
| 4725 | 0 | 14 | `tests/fm-review-diff.test.sh` |
| 3531 | 0 | 11 | `tests/fm-lint.test.sh` |
| 3421 | 0 | 5 | `tests/fm-composer-ghost.test.sh` |
| 3233 | 0 | 15 | `tests/fm-send-popup-settle.test.sh` |
| 1970 | 0 | 21 | `tests/fm-tmux-submit-busy.test.sh` |
| 1833 | 0 | 17 | `tests/fm-send-strict.test.sh` |
| 1671 | 0 | 16 | `tests/fm-send-settle.test.sh` |
| 1287 | 0 | 18 | `tests/fm-spawn-batch.test.sh` |
| 382 | 0 | 19 | `tests/fm-supervision-instructions.test.sh` |
| 95 | 0 | 22 | `tests/fm-transition-lib.test.sh` |
| 63 | 0 | 6 | `tests/fm-composer-lib.test.sh` |
| 21 | 0 | 12 | `tests/fm-pi-primary-types.test.sh` |

## Scope

Each worker used a separate mode-`0700` temporary root and private `TMPDIR` and `TMP` outside the repository, because secondmate fixtures must satisfy the seeded-home boundary.
The harness cleared ambient `FM_HOME` and `FM_*_OVERRIDE` values for every worker and verified that global Git configuration was unchanged.
A candidate failure fails the aggregate run and requires investigation rather than a retry.

## Re-run

```sh
bin/fm-test-isolation-proof.sh --list
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json
bin/fm-test-run.sh --check-coverage
```
