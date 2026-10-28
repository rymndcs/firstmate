#!/usr/bin/env bash
# Opt-in credentialed smoke for the launcher's supported review harnesses.
# Run after CLI upgrades: FM_REVIEW_ROUND_LIVE=1 bin/fm-test-run.sh tests/fm-review-round-live-e2e.test.sh
# Fake task records and review evidence stay in an automatically removed fixture.
set -eu

if [ "${FM_REVIEW_ROUND_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_REVIEW_ROUND_LIVE=1 to run credentialed review-launcher smokes'
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-review-round-live)
mkdir -p "$LAB/home/state" "$LAB/repo"
git -C "$LAB/repo" init -q
printf 'Tiny launcher smoke fixture.\n' > "$LAB/repo/README.md"
LAUNCHER="$ROOT/bin/fm-review-round.sh"
export FM_HOME="$LAB/home"
checked=0
for harness in codex claude; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf '# review launcher: %s absent\n' "$harness"
    continue
  fi
  version=$("$harness" --version)
  case "$harness" in
    codex) model=gpt-6.1-sol ;;
    claude) model=opus ;;
  esac
  printf 'harness=%s\nmodel=%s\neffort=high\n' "$harness" "$model" > "$FM_HOME/state/smoke-$harness.meta"
  cd "$LAB/repo"
  token=$("$LAUNCHER" --init "smoke-$harness")
  input=$("$LAUNCHER" reviewer --task "$token" --round 1 --path input)
  printf 'Tiny launcher smoke, not a code audit. Read only README.md; run no commands, load no skills, delegate nothing, and write no files. Reply exactly: SMOKE_OK %s\n' "$harness" > "$input"
  output=$("$LAUNCHER" reviewer --task "$token" --round 1) || fail "$harness $version review launch failed"
  assert_grep "SMOKE_OK $harness" "$output" "$harness $version omitted smoke reply"
  if [ "$harness" = codex ]; then
    grep -Fx "model: $model" "$output.diagnostics" >/dev/null || fail "$harness $version used another model"
    grep -Fx 'reasoning effort: high' "$output.diagnostics" >/dev/null || fail "$harness $version lost effort"
    actual=$model
  else
    actual=$(jq -er '.modelUsage | keys[] | select(contains("opus"))' "$output.runtime.json") \
      || fail "$harness $version did not report the requested Opus model"
  fi
  pass "review launcher: $version model=$actual reply=SMOKE_OK $harness"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail 'review launcher checked no installed supported harness'
printf '# checked %s installed supported harness(es)\n' "$checked"
