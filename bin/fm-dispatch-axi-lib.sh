# shellcheck shell=bash
# Shared dispatch-tool floors and the bounded dispatch reading spawns record.
# Usage: . bin/fm-dispatch-axi-lib.sh
#
# `dispatch-axi` is the one tool firstmate reads before choosing which model runs
# a task. `quota-axi` is a data source INSIDE dispatch-axi, not a firstmate
# caller: nothing in this file reads quota-axi for quota.
#
# What stays quota-axi-specific is quota-axi's own installation, for two reasons
# that have nothing to do with firstmate reading it for a quota number:
#   - dispatch-axi subprocesses `quota-axi --json` for every window provider, so
#     an absent or wrong-schema quota-axi silently costs firstmate every window
#     provider while dispatch-axi still reports successfully from its other
#     sources;
#   - `quota-axi auth --json` is firstmate's per-provider credential surface, and
#     dispatch-axi exposes no auth surface at all.
#
# 0.1.16 is the quota-axi floor because it is the first build that reports each
# provider's credential sources independently and exposes Grok `state.authStatus`.
# Without those fields a dispatch candidate cannot be checked against the
# authentication surface it actually uses, which is how one harness's expired CLI
# token used to produce a captain-facing sign-out claim for a candidate that
# never read it.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# dispatch-axi is checked for PRESENCE only, deliberately. It has no `--version`
# and no `--help`: an unrecognized flag is ignored and the report prints anyway,
# so any version probe would read a report as a version string. Its actual
# contract version is `schemaVersion` inside `--json`, and reading that at
# bootstrap would cost a live provider refresh on every session start. So the
# schema is validated at the reading boundary below instead, where the cost is
# already being paid and an unrecognized schema degrades to `unavailable`.
#
# fm_dispatch_reading [timeout-seconds] prints one metadata-safe line
# summarizing dispatch-axi's ranked view as `at=<generated>` followed by one
# `provider=<rank>/<runway>` field per candidate, with `-` for an unranked
# candidate and `unknown` for an unmeasured runway, plus `degraded=<sources>`
# when a source inside dispatch-axi failed. The prefix timestamp is the moment
# dispatch-axi generated the snapshot.
# Any command, timeout, schema, or parse failure prints `unavailable` and returns
# success so dispatch can record the failed observation without being blocked by
# it.
#
# There is no firstmate-side cache. The previous quota reading read quota-axi's
# own cache file to skip a process; dispatch-axi publishes no equivalent
# summary cache, and it already caches its expensive source internally, so one
# bounded invocation per ship/scout spawn is the whole cost.
#
# FM_DISPATCH_AXI_READING_DISABLE=1 short-circuits to that same `unavailable`
# without spawning a process. It exists for firstmate's own test suite
# (tests/lib.sh), where dozens of tests drive the real fm-spawn and would
# otherwise reach the machine's real dispatch-axi, its provider APIs, and the
# operator's real caches. Nothing in the dispatch path sets it, so the reading
# stays unavoidable in production; the test that owns this contract unsets it and
# supplies its own stub.

FM_QUOTA_AXI_MIN=0.1.16

# The dispatch-axi `--json` contract versions this library knows how to read.
# An unlisted version is never summarized, so a changed shape records
# `unavailable` rather than a confident wrong line.
FM_DISPATCH_AXI_SCHEMAS=1

fm_axi_bounded_run() {  # <timeout-seconds-or-empty> <command> [args...]
  local timeout=$1
  shift
  command -v "$1" >/dev/null 2>&1 || return 1
  if [ -z "$timeout" ]; then
    "$@" 2>/dev/null </dev/null
    return
  fi
  case "$timeout" in
    *[!0-9]*|0) return 1 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" "$@" 2>/dev/null </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout" "$@" 2>/dev/null </dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout" "$@" 2>/dev/null </dev/null
  else
    return 1
  fi
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  output=$(fm_axi_bounded_run "$timeout" quota-axi --version) || return 1
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_dispatch_axi_summarize() {
  command -v node >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016  # Node owns every ${...} template expression here.
  FM_DISPATCH_AXI_SCHEMAS="$FM_DISPATCH_AXI_SCHEMAS" node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (!data || typeof data.generatedAt !== "string" || !Array.isArray(data.candidates)) process.exit(1);
// dispatch-axi owns its own contract version. An unrecognized schema is not
// summarized at all, so a reshaped report records `unavailable` instead of a
// line this parser only appears to understand.
const known = String(process.env.FM_DISPATCH_AXI_SCHEMAS || "").split(",").filter(Boolean);
if (!known.includes(String(data.schemaVersion))) process.exit(1);
// Every interpolated string is provider output relayed by dispatch-axi, not
// local-trusted input, and it lands in a line-oriented key=value metadata store
// whose readers take the LAST matching line. Dropping control characters and
// the two field separators here keeps one reading to exactly one line that
// cannot forge a second key.
const safe = (value) => String(value)
  .split("")
  .filter((ch) => {
    const code = ch.charCodeAt(0);
    return code > 31 && code !== 127 && ch !== ";" && ch !== "=";
  })
  .join("");
const ranks = new Map();
if (Array.isArray(data.rankings)) {
  for (const entry of data.rankings) {
    if (entry && typeof entry.provider === "string" && Number.isFinite(entry.rank)) {
      ranks.set(entry.provider, entry.rank);
    }
  }
}
const fields = [`at=${safe(data.generatedAt)}`];
for (const candidate of data.candidates) {
  if (!candidate || typeof candidate.provider !== "string") continue;
  const name = safe(candidate.provider);
  // An unranked candidate is recorded as unranked, never dropped and never
  // scored: dispatch-axi ranks only what it could measure, and the fact that a
  // candidate could not be measured is itself the evidence worth keeping.
  const rank = ranks.has(candidate.provider) ? String(ranks.get(candidate.provider)) : "-";
  const runway = candidate.runway && typeof candidate.runway.runwayHuman === "string"
    ? safe(candidate.runway.runwayHuman)
    : "unknown";
  fields.push(`${name}=${rank}/${runway}`);
}
// Provenance, not prose: a degraded source is recorded by name so a later
// reader can tell a genuinely empty provider from one whose source never ran.
const degraded = Array.isArray(data.degradedSources)
  ? [...new Set(data.degradedSources
      .filter((source) => typeof source === "string")
      .map((source) => safe(source.split(":")[0]).slice(0, 40))
      .filter(Boolean))]
  : [];
// A snapshot carrying no usable candidate is still worth recording when it
// names a failed source, because that is the case the provenance exists for: a
// home of window-shaped providers with a broken quota-axi would otherwise read
// exactly like dispatch-axi never running.
if (fields.length === 1 && !degraded.length) process.exit(1);
if (degraded.length) fields.push(`degraded=${degraded.join(",")}`);
process.stdout.write(fields.join(";"));
' 2>/dev/null
}

fm_dispatch_reading() {
  local timeout=${1:-10} output summary
  if [ "${FM_DISPATCH_AXI_READING_DISABLE:-0}" = 1 ]; then
    printf '%s\n' unavailable
    return 0
  fi
  summary=
  output=$(fm_axi_bounded_run "$timeout" dispatch-axi --json) || output=
  [ -z "$output" ] || summary=$(printf '%s' "$output" | fm_dispatch_axi_summarize) || summary=
  # Last guard at the owning boundary: whatever a summarizer produced, one
  # reading reaches the caller as one line.
  summary=${summary%%$'\n'*}
  printf '%s\n' "${summary:-unavailable}"
}
