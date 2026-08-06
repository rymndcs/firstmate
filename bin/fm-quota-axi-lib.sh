# shellcheck shell=bash
# Shared quota-axi compatibility floor and bounded quota reading for dispatch.
# Usage: . bin/fm-quota-axi-lib.sh
#
# 0.1.16 is the floor because it is the first build that reports each provider's
# credential sources independently and exposes Grok `state.authStatus`. Without
# those fields a dispatch candidate cannot be checked against the authentication
# surface it actually uses, which is how one harness's expired CLI token used to
# produce a captain-facing sign-out claim for a candidate that never read it.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# fm_quota_axi_reading [timeout-seconds] [cache-freshness-seconds] prints one
# metadata-safe line summarizing every reported quota window as
# provider/window=percentRemaining%@reset, prefixed by the reading timestamp.
# A cache younger than the freshness bound is used directly because quota-axi
# refreshes providers even when its cache is current; otherwise this library's
# single bounded invocation path runs quota-axi --json. Any command, timeout,
# cache, or parse failure prints `unavailable` and returns success so dispatch
# can record the failed observation without being blocked by it.

FM_QUOTA_AXI_MIN=0.1.16

fm_quota_axi_run() {  # <timeout-seconds-or-empty> <quota-axi-args...>
  local timeout=$1
  shift
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -z "$timeout" ]; then
    quota-axi "$@" 2>/dev/null </dev/null
    return
  fi
  case "$timeout" in
    *[!0-9]*|0) return 1 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  else
    return 1
  fi
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  output=$(fm_quota_axi_run "$timeout" --version) || return 1
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

fm_quota_axi_cache_fresh() {  # <cache-path> <freshness-seconds>
  local cache=$1 freshness=$2 modified now age
  [ -f "$cache" ] && [ ! -L "$cache" ] || return 1
  case "$freshness" in
    ''|*[!0-9]*) return 1 ;;
  esac
  modified=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null) || return 1
  now=$(date +%s) || return 1
  age=$((now - modified))
  [ "$age" -ge 0 ] && [ "$age" -le "$freshness" ]
}

fm_quota_axi_summarize() {
  command -v node >/dev/null 2>&1 || return 1
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (!data || !Array.isArray(data.providers) || typeof data.generatedAt !== "string") process.exit(1);
const fields = [`at=${data.generatedAt}`];
for (const provider of data.providers) {
  if (!provider || typeof provider.provider !== "string" || !Array.isArray(provider.windows)) continue;
  if (provider.windows.length === 0) {
    fields.push(`${provider.provider}=unavailable`);
    continue;
  }
  for (const window of provider.windows) {
    if (!window || typeof window.id !== "string" || typeof window.percentRemaining !== "number") continue;
    const reset = typeof window.resetsAt === "string" ? `@${window.resetsAt}` : "";
    fields.push(`${provider.provider}/${window.id}=${window.percentRemaining}%${reset}`);
  }
}
if (fields.length === 1) process.exit(1);
process.stdout.write(fields.join(";"));
' 2>/dev/null
}

fm_quota_axi_reading() {
  local timeout=${1:-3} freshness=${2:-300} cache output summary
  cache=${FM_QUOTA_AXI_CACHE:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/quota-axi/quotas.json}
  output=
  if fm_quota_axi_cache_fresh "$cache" "$freshness"; then
    output=$(cat -- "$cache" 2>/dev/null) || output=
  fi
  if [ -z "$output" ]; then
    output=$(fm_quota_axi_run "$timeout" --json) || output=
  fi
  if [ -n "$output" ]; then
    summary=$(printf '%s' "$output" | fm_quota_axi_summarize) || summary=
  else
    summary=
  fi
  printf '%s\n' "${summary:-unavailable}"
}
