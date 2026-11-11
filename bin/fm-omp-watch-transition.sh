#!/usr/bin/env bash
# One transactional omp watcher transition; fm-watch-arm.sh owns launching.
# Public arm: [--transition <reason> --reason '<concrete description>'].
# Reasons: work-pending, unanswered-input, chat-question, stow-incomplete,
# decision, idle-recheck, unknown, watching-only. Semantic work/input reasons
# remain claims. A verified clean bare/watching-only arm exits 2 naming
# firstmate_watch_reset; unavailable evidence warns and allows, never resets.
#
# Sole authority: state/.omp-watch-transition, private atomic regular JSON v1.
# Special-file/symlink obstructions are unknown and are never read or replaced.
# session/arm/generation identify the current transition; phase/pid describe its
# cycle; startup is pre-arm admission with no decision or recovery. classes fold
# typed producer provenance monotonically. watermark is the
# highest admitted transport sequence, retained across successors. batch is the
# SHA-256 identity of the latest admitted raw batch; only matching replay at or
# below the watermark is ignored, while changed replay identity is unknown.
# uncertain poisons incomplete or unknown admission.
# recovery contains the exact session/arm/generation/watermark/batch token it exempts.
# decision records the command/declaration/verdict consumed to create this arm;
# attempt is the latest refused command and grants no permission.
# Diagnostic .omp-watch-transitions.log and native .omp-watch-arm-result are
# observations, never permission stores. A current-session arm observation rules
# out startup when the canonical record is lost. Legacy split fragments grant nothing.
#
# Internal commands (OMPCODE=1):
#   arm <claim> <detail> - atomically consume and reserve successor before launch
#     exit 3 means this native command already reserved its arm; do not relaunch
#   cycle <starting|running|wake|failed> <pid> <cause> - current arm callbacks only
#   drain [--queue-lock-held] - admit canonical raw TSV before queue consumption
#   identity <session> - capture the current token for the reset adapter
#   recovery <session> <captured-token> - one-use, exact-transition recovery
# The sole implementation writer is this script. All record operations share
# .wake-queue.lock; parent-owned drain calls verify its PID and symlink owner.
# Queue acquisition mechanics: fm-wake-lib.sh header; verified dead owners
# reuse bounded stale-lock recovery.
# Unknown obstructions are never stolen. Public startup drains initialize this
# same record before the first arm, retaining replay identity across sessions.
# Slow evidence is gathered outside the lock and its local input fingerprint
# revalidated inside. Changed evidence is unknown. Both drain publication stages
# update this same record; either failure retains raw wakes. Publication precedes
# clearing the queue, so a crash in between replays admitted sequences safely.
# Allowed arms always clear recovery, including away/hold/declaration precedence,
# before best-effort logging. Persistence failure cannot claim consumption.
# Existing native arm correlation and producer sequence must match before old
# evidence can be trusted after an unavailable operation. Other harnesses are inert.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
RECORD="$STATE/.omp-watch-transition"
LOG="$STATE/.omp-watch-transitions.log"
SESSION=${PI_SESSION_ID:-}
CALL=${PI_TOOL_CALL_ID:-}
record=''
warn() { printf 'watcher: WARNING - %s; arming without reset.\n' "$*" >&2; }
publish() { fm_state_path replace "$RECORD"; }
load_record() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  record=$(fm_state_path read "$RECORD") || return 1
  printf '%s' "$record" | jq -e '
    .version == 1 and (.session | type == "string" and length > 0)
    and (.arm | type == "string" and length > 0)
    and (.generation | type == "number" and . >= 1 and floor == .)
    and (.watermark | type == "number" and . >= 0 and floor == .)
    and ((.batch == "" and .watermark == 0) or (.batch | type == "string" and test("^[a-f0-9]{64}$")))
    and (.uncertain | type == "boolean") and (.classes | type == "array" and all(.[]; IN("check","heartbeat","signal","stale","idle-recheck","unknown")))
    and (.phase | IN("startup","starting","running","wake","failed"))
    and (.pid | type == "string" and test("^[0-9]+$"))
    and (if .phase == "startup" then .decision == null and .recovery == null and .pid == "0"
      else (.decision | type == "object" and .verdict == "allow"
        and (.claim | type == "string") and (.detail | type == "string")
        and (.observed | type == "string")) and (.decision.call == .arm) end)
    and (.recovery == null or .recovery == {session,arm,generation,watermark,batch})' >/dev/null 2>&1
}
new_record() {
  jq -cn --arg session "$SESSION" --arg arm "$CALL" \
    --argjson generation "${1:-1}" --argjson watermark "${2:-0}" --arg batch "${3:-}" \
    '{version:1,session:$session,arm:$arm,generation:$generation,watermark:$watermark,batch:$batch,
      phase:"starting",pid:"0",classes:[],uncertain:false,recovery:null,decision:null}'
}
token() { printf '%s' "$record" | jq -c '{session,arm,generation,watermark,batch}'; }
queue_sequence() {
  local seq
  if [ -e "$STATE/.wake-queue.seq" ] || [ -L "$STATE/.wake-queue.seq" ]; then
    seq=$(fm_state_path read "$STATE/.wake-queue.seq") || return 1
  else seq=0; fi
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$seq"
}
invalidate() {
  load_record || return 1
  printf '%s' "$record" | jq '.uncertain=true | .recovery=null' | publish
}
acquire_queue_lock() {
  fm_omp_queue_lock || { warn 'transition lock is unavailable'; return 1; }
  trap 'fm_lock_release "$FM_WAKE_QUEUE_LOCK"' EXIT
}
fingerprint() {
  perl -MTime::HiRes=stat -e '
    my ($state, $data, $config, $inbox) = @ARGV;
    my @paths = ((glob "$state/*.status"), (glob "$state/*.meta"), (glob "$state/*.turn-ended"),
      "$state/.afk", "$state/.afk-daemon-terminal", "$state/.captain-hold",
      "$state/.last-watcher-beat", "$state/.watch.lock/pid", "$state/.watch.lock/pid-identity",
      "$state/.watch.lock/fm-home", "$state/.watch.lock/watcher-path",
      "$data/backlog.md", "$data/projects.md", "$data/secondmates.md",
      "$config/decision-inbox", "$config/decision-inbox-query.jq", $inbox);
    for my $p (sort @paths) {
      my @s = stat $p;
      print "$p:", (@s ? join(":", @s[0,1,2,7,9,10]) : "missing"), "\n";
    }
  ' "$STATE" "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$CONFIG" "${inbox_path:-$CONFIG/decision-inbox}" | cksum
}
observe_external() {
  local f open snapshot inbox_rows
  EXTERNAL=unknown
  for f in "$STATE/"*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || return
    open=$(status_open_decisions "$f") || return
    if [ -n "$open" ]; then EXTERNAL=decision; return; fi
  done
  command -v jq >/dev/null 2>&1 || return
  if [ -e "$CONFIG/decision-inbox" ] || [ -L "$CONFIG/decision-inbox" ]; then
    inbox_path=$(cat "$CONFIG/decision-inbox") || return
    case "$inbox_path" in ''|*$'\n'*) return ;; /*) ;; *) inbox_path="$FM_HOME/$inbox_path" ;; esac
    inbox_rows=$(set -o pipefail; jq -c -f "$CONFIG/decision-inbox-query.jq" "$inbox_path" 2>/dev/null | jq -cs '.') || return
    printf '%s' "$inbox_rows" | jq -e 'length == 1 and (.[0] | type == "array" and all(.[]; type == "array" and length == 4 and all(.[]; type == "string")))' >/dev/null 2>&1 || return
    if [ "$(printf '%s' "$inbox_rows" | jq '.[0] | length')" -gt 0 ]; then EXTERNAL=decision; return; fi
  fi
  snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null) || return
  printf '%s' "$snapshot" | jq -e '.schema == "fm-secondmate-home-summary.v1" and .valid == true' >/dev/null 2>&1 || return
  if printf '%s' "$snapshot" | jq -e '.counts.decisions_open > 0 or .counts.holds > 0 or any(.queued[]; .hold_kind != null)' >/dev/null 2>&1; then
    EXTERNAL=decision; return
  fi
  if printf '%s' "$snapshot" | jq -e 'any(.active_children[]; .source != "pane" and .source != "run-step") or any(.omitted[]; .surface != "landed")' >/dev/null 2>&1; then return; fi
  EXTERNAL=clean
}
record_verdict() {
  local claim=$1 detail=$2 verdict=$3 observed=$4 previous
  previous=$(fm_state_path read "$LOG" | tail -n 255) || return 1
  {
    if [ -n "$previous" ]; then printf '%s\n' "$previous"; fi
    jq -cn --arg session "$SESSION" --arg call "$CALL" --arg claim "$claim" \
      --arg detail "$detail" --arg verdict "$verdict" --arg observed "$observed" \
      '{session:$session,call:$call,claim:$claim,detail:$detail,verdict:$verdict,observed:$observed}'
  } | fm_state_path replace "$LOG"
}

session_unarmed() {
  local result_session result_call result="$STATE/.omp-watch-arm-result"
  if [ -e "$result" ] || [ -L "$result" ]; then
    [ -f "$result" ] && [ ! -L "$result" ] || return 1
    { IFS= read -r result_session; IFS= read -r result_call; } < "$result" || return 1
    [ -n "$result_session" ] && [ -n "$result_call" ] && [ "$result_session" != "$SESSION" ]
  fi
}
startup_evidence() {
  session_unarmed || return 1
  [ ! -e "$STATE/.omp-watch-cycle" ] && [ ! -e "$STATE/.omp-watch-drain" ] && [ ! -e "$STATE/.omp-watch-recovery" ]
}
initialize_drain() {
  local generation=1 watermark=0 batch='' uncertain=false
  if load_record; then
    [ "$(printf '%s' "$record" | jq -r .session)" != "$SESSION" ] || return 0
    generation=$(printf '%s' "$record" | jq '.generation + 1')
    watermark=$(printf '%s' "$record" | jq .watermark)
    batch=$(printf '%s' "$record" | jq -r .batch)
    session_unarmed || uncertain=true
  elif [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    uncertain=true
  else
    startup_evidence || uncertain=true
  fi
  new_record "$generation" "$watermark" "$batch" | jq --argjson uncertain "$uncertain" \
    '.phase="startup" | .uncertain=$uncertain' | publish
}
observe() {
  local result_session result_call sequence
  OBSERVED=unknown
  fm_state_path check "$FM_WAKE_QUEUE" || return
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ]; then OBSERVED=away; return; fi
  if [ -e "$STATE/.captain-hold" ]; then OBSERVED=hold; return; fi
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]; then
    startup_evidence || return
    OBSERVED=startup; return
  fi
  load_record || return
  if [ "$(printf '%s' "$record" | jq -r .session)" != "$SESSION" ]; then
    session_unarmed && OBSERVED=startup
    return
  fi
  if [ "$(printf '%s' "$record" | jq -r .phase)" = startup ]; then
    [ "$(printf '%s' "$record" | jq -r .uncertain)" = false ] && session_unarmed && OBSERVED=startup
    return
  fi
  if [ -f "$STATE/.omp-watch-arm-result" ]; then
    { IFS= read -r result_session; IFS= read -r result_call; } < "$STATE/.omp-watch-arm-result" || return
    [ "$result_session" != "$SESSION" ] || [ "$result_call" = "$(printf '%s' "$record" | jq -r .arm)" ] || return
  fi
  [ "$(printf '%s' "$record" | jq -r .uncertain)" = false ] || return
  sequence=$(queue_sequence) || return
  if [ -s "$FM_WAKE_QUEUE" ]; then OBSERVED=queued-wakes; return; fi
  [ "$sequence" = "$(printf '%s' "$record" | jq -r .watermark)" ] || return
  if printf '%s' "$record" | jq -e '.recovery == {session,arm,generation,watermark,batch}' >/dev/null; then OBSERVED=recovery; return; fi
  case "$(printf '%s' "$record" | jq -r .phase)" in
    failed|starting) OBSERVED=repair; return ;;
    running)
      if [ "$HEALTHY" != true ]; then OBSERVED=repair; return; fi ;;
  esac
  [ "$EXTERNAL" = clean ] || { OBSERVED=$EXTERNAL; return; }
  case "$(printf '%s' "$record" | jq -r '.classes | sort | join(" ")')" in
    idle-recheck) OBSERVED=idle-recheck ;;
    '') ;;
    *unknown*) ;;
    *) OBSERVED=clean ;;
  esac
}
record_cycle() {
  local phase=$1 pid=$2
  load_record || return 1
  [ "$(printf '%s' "$record" | jq -r .phase)" != startup ] || return 0
  printf '%s' "$record" | jq -e --arg session "$SESSION" --arg arm "$CALL" \
    '.session == $session and .arm == $arm' >/dev/null || return 0
  case "$phase" in starting|running|wake|failed) ;; *) return 1 ;; esac
  printf '%s' "$record" | jq --arg phase "$phase" --arg pid "$pid" '.phase=$phase | .pid=$pid' | publish
}
record_drain() {
  local rows=$1 watermark classes next replay previous_batch batch replay_changed=false
  load_record || return 1
  [ "$(printf '%s' "$record" | jq -r .session)" = "$SESSION" ] || return 1
  watermark=$(printf '%s' "$record" | jq -r .watermark)
  next=$(printf '%s\n' "$rows" | awk -F '\t' -v mark="$watermark" '$2 ~ /^[0-9]+$/ && $2 > mark {mark=$2} END {print mark}')
  replay=$(printf '%s\n' "$rows" | awk -F '\t' -v mark="$watermark" 'NF >= 5 && $2 ~ /^[0-9]+$/ && $2 <= mark')
  if [ -n "$replay" ]; then
    previous_batch=$(printf '%s\n' "$replay" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
    if [ "$previous_batch" != "$(printf '%s' "$record" | jq -r .batch)" ]; then replay_changed=true; fi
  fi
  classes=$(printf '%s\n' "$rows" | awk -F '\t' -v mark="$watermark" '
    NF >= 5 && $2 > mark {
      if ($3 == "stale" && NF == 6 && $6 == "idle-recheck") print "idle-recheck"
      else if ($3 ~ /^(check|heartbeat|signal|stale)$/) print $3
      else print "unknown"
    }
    NF && (NF < 5 || $2 !~ /^[0-9]+$/) {print "unknown"}
  ' | jq -Rsc 'split("\n") | map(select(length > 0)) | unique') || return 1
  if [ "$replay_changed" = true ]; then
    classes=$(printf '%s' "$classes" | jq '. + ["unknown"] | unique') || return 1
    warn 'transport sequence replay identity changed; transition remains unknown'
  fi
  [ "$classes" != '[]' ] || return 0
  batch=$(printf '%s\n' "$rows" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
  printf '%s' "$record" | jq '.uncertain=true | .recovery=null' | publish || return 1
  printf '%s' "$record" | jq --argjson classes "$classes" --argjson watermark "$next" --arg batch "$batch" \
    '.classes=(.classes + $classes | unique) | .watermark=$watermark | .batch=$batch | .uncertain=(.uncertain or ($classes | index("unknown") != null)) | .recovery=null' | publish || return 1
}
arm_transition() {
  local claim=$1 detail=$2 verdict=allow observed generation=1 watermark=0 batch='' successor current
  case "$claim" in
    ''|watching-only|unknown|work-pending|unanswered-input|chat-question|stow-incomplete|decision|idle-recheck) ;;
    *) echo 'watcher: invalid --transition; see fm-watch-arm.sh --help' >&2; return 2 ;;
  esac
  if [ -n "$claim" ] && [ -z "$detail" ]; then
    echo 'watcher: --transition requires a nonempty --reason' >&2; return 2
  fi
  observe
  current=$(fingerprint) || current=unavailable
  [ "$before" != unavailable ] && [ "$before" = "$after" ] && [ "$after" = "$current" ] || OBSERVED=unknown
  observed=$OBSERVED
  case "$claim" in
    ''|watching-only) [ "$observed" != clean ] || verdict=refuse ;;
    decision|idle-recheck) [ "$observed" = "$claim" ] || observed=unknown ;;
    unknown) warn "declared unknown transition: $detail" ;;
  esac
  [ "$observed" != unknown ] || warn 'transition evidence is unknown'
  if load_record; then
    if printf '%s' "$record" | jq -e --arg session "$SESSION" --arg call "$CALL" '.session == $session and .arm == $call and .decision.verdict == "allow"' >/dev/null; then return 3; fi
    generation=$(printf '%s' "$record" | jq '.generation + 1')
    watermark=$(printf '%s' "$record" | jq .watermark)
    batch=$(printf '%s' "$record" | jq -r .batch)
  fi
  if [ "$verdict" = refuse ]; then
    if ! printf '%s' "$record" | jq --arg call "$CALL" --arg claim "$claim" --arg detail "$detail" --arg observed "$observed" \
      '.attempt={call:$call,claim:$claim,detail:$detail,observed:$observed,verdict:"refuse"}' | publish; then
      warn 'canonical transition could not be saved'; return 0
    fi
  else
    successor=$(new_record "$generation" "$watermark" "$batch" | jq --arg call "$CALL" --arg claim "$claim" --arg detail "$detail" --arg observed "$observed" \
      '.decision={call:$call,claim:$claim,detail:$detail,observed:$observed,verdict:"allow"}') || return 1
    if ! printf '%s' "$successor" | publish; then warn 'canonical successor could not be saved; consumption is unconfirmed'; return 0; fi
  fi
  record_verdict "$claim" "$detail" "$verdict" "$observed" || warn 'could not persist the diagnostic transition verdict'
  if [ "$verdict" = refuse ]; then
    echo 'watcher: reset required - use firstmate_watch_reset for this clean watching-only transition; otherwise declare the work or unanswered input that prevents reset with --transition and --reason.' >&2
    return 2
  fi
}

if [ "${1:-}" = --help ]; then
  sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi
[ "${OMPCODE:-}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || { warn 'jq is unavailable'; [ "${1:-}" != drain ]; exit $?; }
case "${1:-}" in
  arm)
    inbox_path=''
    [ ! -f "$CONFIG/decision-inbox" ] || inbox_path=$(cat "$CONFIG/decision-inbox")
    case "$inbox_path" in /*|'') ;; *) inbox_path="$FM_HOME/$inbox_path" ;; esac
    before=$(fingerprint) || before=unavailable
    observe_external
    HEALTHY=false
    fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" && HEALTHY=true
    after=$(fingerprint) || after=unavailable
    acquire_queue_lock || exit 0
    if [ -z "$SESSION" ] || [ -z "$CALL" ]; then
      invalidate || true
      warn 'native omp session or tool identity is unavailable'; exit 0
    fi
    arm_transition "${2:-}" "${3:-}"
    ;;
  drain)
    rows=$(cat)
    if [ "${2:-}" = --queue-lock-held ]; then
      fm_state_path lock-check "$FM_WAKE_QUEUE_LOCK" '' "$PPID" || exit 1
    else acquire_queue_lock || exit 1; fi
    if [ -z "$SESSION" ] || [ -z "$CALL" ]; then
      invalidate || true
      warn 'native omp drain identity is unavailable; wakes retained'; exit 1
    fi
    if [ "${2:-}" = --queue-lock-held ]; then
      initialize_drain || { warn 'startup drain admission failed; wakes retained'; exit 1; }
    fi
    record_drain "$rows" || { warn 'canonical drain admission failed; wakes retained'; exit 1; }
    ;;
  identity)
    acquire_queue_lock || exit 1
    load_record && [ "$(printf '%s' "$record" | jq -r .session)" = "${2:-}" ] || exit 1
    [ "$(printf '%s' "$record" | jq -r .phase)" != startup ] || exit 1
    token
    ;;
  recovery)
    acquire_queue_lock || exit 1
    load_record || { warn 'recovery has no canonical transition'; exit 1; }
    [ "$(printf '%s' "$record" | jq -r .session)" = "${2:-}" ] || exit 1
    [ "$(printf '%s' "$record" | jq -r .phase)" != startup ] || { warn 'recovery has no admitted arm'; exit 1; }
    [ "$(token)" = "${3:-}" ] || { warn 'retired recovery callback ignored'; exit 0; }
    [ "$(queue_sequence)" = "$(printf '%s' "$record" | jq -r .watermark)" ] || { warn 'recovery evidence has changed'; exit 0; }
    printf '%s' "$record" | jq '.recovery={session,arm,generation,watermark,batch}' | publish
    ;;
  cycle)
    acquire_queue_lock || exit 1
    [ -n "$SESSION" ] && [ -n "$CALL" ] || { invalidate || true; warn 'native cycle identity unavailable'; exit 1; }
    record_cycle "$2" "$3"
    ;;
  *) exit 2 ;;
esac
