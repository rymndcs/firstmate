#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-array-dispatch skill.
#
# This drives the public Pi skill-loading interface against a fake dispatch-axi
# executable rather than parsing instruction source bytes or recreating the
# selector in test code.
#
# A fake quota-axi sits beside it and records every invocation. These cases all
# state that authentication is usable, so the skill has no reason to reach the
# credential surface: any quota-axi call here means the skill went back to
# reading capacity directly instead of through dispatch-axi.
set -u

if [ "${FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E=1 to run the credentialed Pi dispatch-selection regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
[ -f "$OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/dispatch.json"
CALLS="$LAB/dispatch-axi.calls"
QUOTA_CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"

cat > "$FAKEBIN/dispatch-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != --json ] || [ "$#" -ne 1 ]; then
  printf 'unexpected dispatch-axi invocation: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "$*" >> "${DISPATCH_AXI_CALLS:?}"
cat "${DISPATCH_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/dispatch-axi"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
printf 'quota-axi is a source inside dispatch-axi; firstmate does not read it for capacity\n' >&2
exit 64
SH
chmod +x "$FAKEBIN/quota-axi"

write_fixture() {
  cat > "$FIXTURE"
}

run_case() {
  local label=$1 expected=$2 prompt=$3 out calls required
  shift 3
  : > "$CALLS"
  : > "$QUOTA_CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" DISPATCH_AXI_CALLS="$CALLS" DISPATCH_AXI_FIXTURE="$FIXTURE" \
        QUOTA_AXI_CALLS="$QUOTA_CALLS" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "$calls" = "--json" ] || fail "$label: skill did not use one dispatch-axi --json snapshot: $calls"
  [ ! -s "$QUOTA_CALLS" ] \
    || fail "$label: skill read quota-axi directly instead of through dispatch-axi: $(tr '\n' '|' < "$QUOTA_CALLS")"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || fail "$label: expected accounting line $required, got: $out"
  done
  printf '%s\n' "$out"
  printf 'ok - %s\n' "$label"
}

write_fixture <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":1,"candidates":[{"provider":"claude","label":"Claude","source":"window","runway":{"status":"projected_exhaustion","runwaySeconds":600,"runwayHuman":"10m","projectionConfidence":"established","projectionBasis":"cycle_average","limitingWindow":"weekly","resetsAt":null,"projectedExhaustedAt":"2030-01-01T00:10:00Z"},"evidence":{"effectivePercentRemaining":1,"worstReservePercentPoints":-1,"liveWindows":["weekly"]},"warnings":[],"errors":[]},{"provider":"codex","label":"Codex","source":"window","runway":{"status":"projected_exhaustion","runwaySeconds":14400,"runwayHuman":"4h","projectionConfidence":"established","projectionBasis":"cycle_average","limitingWindow":"weekly","resetsAt":null,"projectedExhaustedAt":"2030-01-01T04:00:00Z"},"evidence":{"effectivePercentRemaining":55,"worstReservePercentPoints":-40,"liveWindows":["weekly"]},"warnings":[],"errors":[]}],"rankings":[{"provider":"codex","rank":1,"runway_human":"4h"},{"provider":"claude","rank":2,"runway_human":"10m"}],"warnings":[],"degradedSources":[]}
JSON
run_case \
  "the rank is taken with its evidence, and a less-negative reserve does not rescue" \
  "SELECTED=codex" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run dispatch-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable, so do not run any other vendor command. The likely task-completion horizon is two hours with established confidence. Return exact lines FACT=claude|rank=2|headroom=1|runway_seconds=600|reserve=-1 and FACT=codex|rank=1|headroom=55|runway_seconds=14400|reserve=-40 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not modify files." \
  "FACT=claude|rank=2|headroom=1|runway_seconds=600|reserve=-1" \
  "FACT=codex|rank=1|headroom=55|runway_seconds=14400|reserve=-40"

write_fixture <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":1,"candidates":[{"provider":"claude","label":"Claude","source":"unknown","runway":{"status":"unknown","runwaySeconds":null,"runwayHuman":null,"projectionConfidence":null,"projectionBasis":null,"limitingWindow":null,"resetsAt":null,"projectedExhaustedAt":null},"evidence":{"effectivePercentRemaining":55,"liveWindows":["weekly"]},"warnings":[],"errors":["No runway could be measured for the weekly window"]},{"provider":"codex","label":"Codex","source":"window","runway":{"status":"projected_exhaustion","runwaySeconds":14400,"runwayHuman":"4h","projectionConfidence":"established","projectionBasis":"cycle_average","limitingWindow":"weekly","resetsAt":null,"projectedExhaustedAt":"2030-01-01T04:00:00Z"},"evidence":{"effectivePercentRemaining":45,"worstReservePercentPoints":-5,"liveWindows":["weekly"]},"warnings":[],"errors":[]}],"rankings":[{"provider":"codex","rank":1,"runway_human":"4h"},{"provider":"claude","rank":null,"runway_human":"unknown"}],"warnings":[],"degradedSources":[]}
JSON
run_case \
  "an unranked candidate stays eligible and is accounted for explicitly" \
  "DECISION=CODEX" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run dispatch-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable, so do not run any other vendor command. The likely task-completion horizon is two hours with established confidence. Claude has higher known headroom but is unranked with no measurable runway, while Codex is ranked with lower known headroom and established runway that supports completion. Claude's unranked state is uncertainty and must not exclude it, and the known completion-supporting runway justifies Codex. Return exact lines FACT=claude|eligible=yes|rank=unranked|headroom=55|runway=unknown and FACT=codex|eligible=yes|rank=1|headroom=45|runway_seconds=14400|supports_horizon=yes, then an exact final line DECISION=CODEX. Do not modify files." \
  "FACT=claude|eligible=yes|rank=unranked|headroom=55|runway=unknown" \
  "FACT=codex|eligible=yes|rank=1|headroom=45|runway_seconds=14400|supports_horizon=yes"

write_fixture <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":1,"candidates":[{"provider":"claude","label":"Claude","source":"window","runway":{"status":"projected_exhaustion","runwaySeconds":10800,"runwayHuman":"3h","projectionConfidence":"established","projectionBasis":"cycle_average","limitingWindow":"weekly","resetsAt":null,"projectedExhaustedAt":"2030-01-01T03:00:00Z"},"evidence":{"effectivePercentRemaining":1,"worstReservePercentPoints":-1,"liveWindows":["weekly"]},"warnings":[],"errors":[]},{"provider":"codex","label":"Codex","source":"window","runway":{"status":"projected_exhaustion","runwaySeconds":28800,"runwayHuman":"8h","projectionConfidence":"established","projectionBasis":"cycle_average","limitingWindow":"weekly","resetsAt":null,"projectedExhaustedAt":"2030-01-01T08:00:00Z"},"evidence":{"effectivePercentRemaining":80,"worstReservePercentPoints":-2,"liveWindows":["weekly"]},"warnings":[],"errors":[]}],"rankings":[{"provider":"codex","rank":1,"runway_human":"8h"},{"provider":"claude","rank":2,"runway_human":"3h"}],"warnings":[],"degradedSources":[]}
JSON
run_case \
  "the required strongest reasoning class overrides the top rank" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run dispatch-axi --json exactly once. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile that meets the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class and cannot meet the requirement, so do not run any other vendor command. Return exact lines FACT=claude|reasoning=required|rank=2|headroom=1|runway_seconds=10800 and FACT=codex|reasoning=weaker|rank=1|headroom=80|runway_seconds=28800, then an exact final line SELECTED=<claude|codex>. Do not modify files." \
  "FACT=claude|reasoning=required|rank=2|headroom=1|runway_seconds=10800" \
  "FACT=codex|reasoning=weaker|rank=1|headroom=80|runway_seconds=28800"

write_fixture <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":1,"candidates":[{"provider":"deepseek","label":"DeepSeek","source":"balance","runway":{"status":"low_confidence_balance","runwaySeconds":23565600,"runwayHuman":">272d 18h","projectionConfidence":"low","projectionBasis":"daily_burn_average_1d","limitingWindow":null,"resetsAt":null,"projectedExhaustedAt":null},"evidence":{"balance_usd":"21.82","daily_burn_usd":"0.08","history_days":1},"warnings":["Burn rate from 1 day of history - runway is a floor, not a precise estimate"],"errors":[]},{"provider":"claude","label":"Claude","source":"window","runway":{"status":"through_reset","runwaySeconds":64666,"runwayHuman":"17h 57m","projectionConfidence":"established","projectionBasis":"cycle_average","limitingWindow":"seven_day","resetsAt":"2030-01-01T18:00:00Z","projectedExhaustedAt":null},"evidence":{"effectivePercentRemaining":25,"worstReservePercentPoints":14,"liveWindows":["five_hour","seven_day"]},"warnings":[],"errors":[]}],"rankings":[{"provider":"deepseek","rank":1,"runway_human":">272d 18h"},{"provider":"claude","rank":2,"runway_human":"17h 57m"}],"warnings":["Balance-based and window-based runways use different measurement shapes; ranking is approximate."],"degradedSources":[]}
JSON
run_case \
  "a low-confidence cross-shape rank is overridden and the override is stated" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run dispatch-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable, so do not run any other vendor command. The likely task-completion horizon is twelve hours with established confidence. DeepSeek holds the top rank on a balance-shaped runway whose projection confidence is low and whose basis is one day of burn history, while Claude's window-shaped runway is established and reaches through the horizon, and the snapshot itself warns that the cross-shape ranking is approximate. Return exact lines FACT=deepseek|rank=1|shape=balance|confidence=low|basis=daily_burn_average_1d and FACT=claude|rank=2|shape=window|confidence=established|basis=cycle_average|supports_horizon=yes and OVERRIDE=rank1-deepseek-low-confidence, then an exact final line SELECTED=<deepseek|claude>. Do not modify files." \
  "FACT=deepseek|rank=1|shape=balance|confidence=low|basis=daily_burn_average_1d" \
  "FACT=claude|rank=2|shape=window|confidence=established|basis=cycle_average|supports_horizon=yes" \
  "OVERRIDE=rank1-deepseek-low-confidence"

echo "# all quota-array-dispatch live behavior tests passed"
