#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# and fm-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those three scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING (the printed order; the wake drain is printed third but runs after
# every step that can hang, see WAKE DRAIN TIMING below), and why LOCK now runs
# before BOOTSTRAP (the old AGENTS.md order was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run: tool/version problems, GitHub
#                       auth, the worktree-tangle check, the harness override,
#                       crew-dispatch profile validation, and backlog-backend
#                       status. Routine confirmations stay silent by default.
#                       When the lock was refused, the worktree-tangle check
#                       uses read-only advisory wording and prints no checkout
#                       repair command. Bootstrap's MUTATING sweeps also run
#                       only when locked; bin/fm-bootstrap.sh's own header owns
#                       their current list. Among them the secondmate liveness
#                       sweep deterministically accounts for EVERY registered
#                       secondmate: it relaunches only from the recovery-grade
#                       'dead' or 'missing' states, preserves ambiguous,
#                       unreadable, or unreachable remote targets rather than
#                       respawning against them, and reports every skipped or
#                       failed guarantee as a SECONDMATE_LIVENESS: line
#                       (bin/fm-backend.sh's fm_backend_agent_state;
#                       docs/remote-secondmates.md).
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked, and it runs after every step that can
#                       hang, just before the local fleet reads and the one
#                       print. When locked, the raw drained records print
#                       prominently as this turn's FIRST work queue; a bounded,
#                       clearly labeled historical status-event annotation may
#                       follow a valid 'signal' record but never replaces that
#                       record or current-state reconciliation. A lapsed watcher
#                       chain surfaces here through the same guard alarm.
#                       When the lock was refused the queue is left UNTOUCHED,
#                       because a read-only session has no mutation authority
#                       and another session may be draining it; the guard's
#                       tangle and watcher-liveness alarms still print, in
#                       advisory mode, with no drain, supervision repair, or
#                       checkout repair command.
#   4. context digest - the rule files data/projects.md, data/secondmates.md,
#                       data/captain.md, data/captain-shared.md,
#                       data/learnings.md: read-only, always safe, always runs.
#                       Each prints in full, as an explicit ABSENT marker that
#                       is never confused with an empty-but-present file, or -
#                       under OUTPUT BUDGET below - not at all; the section
#                       preamble prints what each file's absence means, because
#                       absence is meaningful for every one of them.
#                       The home's optional CLAUDE.local.md is a rule file too,
#                       printed for every primary except Claude, which loads it
#                       natively.
#                       Missing local rules are silent; an unreadable or
#                       non-regular path prints one CLAUDE_LOCAL diagnostic
#                       without aborting the digest.
#                       harness-adapters records the per-harness evidence.
#   5. fleet digest   - the in-flight and captain-held data/backlog.md items,
#                       every state/*.meta, a bounded state/*.status tail
#                       (FM_SESSION_START_STATUS_TAIL, default 3 lines) labeled
#                       as wake-EVENT history rather than current state and
#                       printed with the full log path for a deeper read,
#                       state/.afk, and a cheap per-task endpoint-liveness read:
#                       read-only, always runs. That liveness line is a fast
#                       presence check only. A crew's actual current state - a
#                       run-step, not just "is the pane there" - still needs
#                       bin/fm-crew-state.sh <id>; this digest deliberately
#                       skips that deeper, slower read for every task so it
#                       stays fast and bounded.
#   6. closing reminder - prints the context-specific watcher next step, then
#                       names every rule file printed in full and sends the
#                       reader to every one that was not; this script points
#                       back to the emitted harness supervision block and
#                       deliberately never arms the watcher itself.
#
# OUTPUT BUDGET: primaries show only part of a long command output (omp keeps
# the first and last ~20 KB of anything over 50 KiB; others persist or
# truncate), and a hidden middle once held the captain's rule files. So the
# digest is built in memory and printed once, at most
# FM_SESSION_START_BUDGET_BYTES bytes (default 46080, 45 KiB), filled in this
# order:
#   - never cut: everything LOCK, BOOTSTRAP and WAKE QUEUE print (drained wake
#     records are gone once read), extension diagnostics, the supervision block,
#     and public commitments awaiting delivery;
#   - reserved: fleet state at its most shortened, so a printed rule file can
#     never push the digest past the budget;
#   - rule files, in the order data/captain.md, CLAUDE.local.md,
#     data/captain-shared.md, data/learnings.md, data/projects.md,
#     data/secondmates.md: each printed whole if it fits what remains, never in
#     part; a file that does not fit is skipped and later files are still tried;
#   - fleet state, shortened only as far as needed, in this order: (a) orphan
#     status tails dropped, (b) per-task status tails cut to 1 line, (c) each
#     .meta reduced to its window, kind, harness, model, mode and pr lines,
#     (d) the backlog reduced to in-flight ids plus a captain-held count. Each
#     step taken prints one FLEET_TRUNCATED line naming where the rest lives.
# Every rule file not printed puts one line at the very top of stdout:
#   STOP: rule file not printed - read <absolute path> in full with your
#   file-read tool before any other action (<bytes> bytes)
# The reader must read every file named on a STOP line first.
# Nothing is copied to state/; the digest stays read-only.
#
# WAKE DRAIN TIMING: the drain removes records from the queue as it reads them,
# and this script holds them only in memory until its one print, so every step
# that runs a command that can hang - bootstrap, the supervision block, the
# backlog listing and the endpoint-liveness reads - runs before the drain,
# still under the session lock. After it come only local reads and the print:
# the state/*.meta bodies and status tails, read then so they include a PR the
# drain registers, and the in-memory budget assembly; the drain output is
# measured before any budget decision. A run stopped by any signal, KILL
# included, before the drain leaves every record queued for the next run. A run
# stopped by TERM, HUP or INT before the final print prints, once its running
# step ends, an INTERRUPTED line and the LOCK, BOOTSTRAP and WAKE QUEUE output
# of the steps that finished, so a run stopped during or after the drain prints
# the drained records. TERM, HUP and INT are ignored during the final print, so
# they cannot cut it. Two gaps remain, and each loses the records that run
# drained: a hard kill (KILL, or the machine stopping) between the drain and
# the end of the print, and a second TERM, HUP or INT that lands while the
# INTERRUPTED output is still printing.
#
# The supervision operating instructions are emitted after the wake queue and
# before context: exactly ONE operating block for the detected primary harness,
# rendered by bin/fm-supervision-instructions.sh from docs/supervision-protocols/.
# The closing reminder points back at that block and otherwise preserves only
# the lock, afk, X-mode, and read-once reminders. This script never starts
# supervision; the emitted harness protocol owns the exact wait or wake
# mechanism.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes, writing X-mode artifacts,
# and fetching or fast-forwarding every project clone - before ever discovering
# another session already holds the lock. Two sessions racing those sweeps is
# exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its read-only detect lines - missing tools, gh auth, the
# worktree-tangle check, the harness override, crew-dispatch validation,
# tasks-axi, dispatch-axi, and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute without
# verified lock ownership.
# Only projection cleanup, bootstrap's mutating sweeps, and the
# wake-queue drain are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: FM_SESSION_START_BACKLOG_LIMIT bounds how many backlog items
# are scanned, default 80; a scan that stops short says so.
# Only in-flight items and captain-held items (queued with hold_kind captain)
# print, each as `<id> - <title>`, followed by one line pointing at the rest;
# hold reasons and bodies stay out of the startup digest.
# The captain-held count covers the whole backlog, not only the scanned items:
# one more `tasks-axi list --state held` call, or the whole data/backlog.md in
# manual mode; when the scan stopped short the listing says how many it shows.
# The command it prints for listing them prints exactly the counted rows.
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script filters
# `tasks-axi list` output carrying the compact identity fields plus hold_kind,
# never body; a title tasks-axi truncated ends in "..." instead of its
# "(truncated, ...)" note.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# the same filter applies to data/backlog.md's section headings and item title
# lines.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# Usage: fm-session-start.sh
#   Prints the ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-3}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=3 ;; esac
BACKLOG_LIMIT=${FM_SESSION_START_BACKLOG_LIMIT:-80}
case "$BACKLOG_LIMIT" in ''|*[!0-9]*|0) BACKLOG_LIMIT=80 ;; esac
# The captain-held count must cover every held item, not only the scanned ones,
# so its listing limit sits far above any real backlog.
BACKLOG_HELD_COUNT_LIMIT=1000000
SESSION_BUDGET_BYTES=${FM_SESSION_START_BUDGET_BYTES:-46080}
case "$SESSION_BUDGET_BYTES" in ''|*[!0-9]*|0) SESSION_BUDGET_BYTES=46080 ;; esac

RULE='================================================================================'
SUBRULE='----------------------------------------'

# shellcheck disable=SC2329 # Invoked through capture.
section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
# shellcheck disable=SC2329 # Invoked through capture.
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# capture <command> [args...]: CAPTURED holds the command's exact stdout,
# trailing newlines included, so every assembled piece measures what it prints.
capture() {
  CAPTURED=$("$@"; printf x)
  CAPTURED=${CAPTURED%x}
}

byte_len() { local LC_ALL=C; REPLY=${#1}; }

abs_path() {
  case "$1" in
    /*) REPLY=$1 ;;
    *) REPLY="$PWD/$1" ;;
  esac
}

file_bytes() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

# render_head: everything LOCK, BOOTSTRAP and WAKE QUEUE print, then the
# extension diagnostic and supervision block. A signal waits for the running
# step to finish, so a run stopped before the drain has BOOT_OUT but no drain
# output yet, and stops before the WAKE QUEUE it never drained.
# shellcheck disable=SC2329 # Invoked through capture and the EXIT trap.
render_head() {
  section "SESSION START - $FM_HOME"
  subsection "LOCK"
  printf '%s\n' "$LOCK_OUT"
  if [ "$READ_ONLY" -eq 1 ]; then
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: PR-check migration, stale Herdr child\n'
    printf '●  cleanup, shared no-mistakes daemon rooting, secondmate convergence,\n'
    printf '●  secondmate liveness, pending remote handoff retry, X-mode artifacts,\n'
    printf '●  fleet sync, and wake-queue drain. Detect-only bootstrap diagnostics\n'
    printf '●  and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  fi

  subsection "BOOTSTRAP"
  if [ -n "$BOOT_OUT" ]; then
    printf '%s\n' "$BOOT_OUT"
  else
    printf '(silent - all good)\n'
  fi

  [ -n "${DRAIN_OUT+set}${GUARD_OUT+set}" ] || return 0
  subsection "WAKE QUEUE"
  if [ "$READ_ONLY" -eq 1 ]; then
    printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
    [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
  elif [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi

  printf '%s' "$EXTENSION_DIAG"
  printf '%s' "$SUPERVISION_OUT"
}

# print_head_on_exit: the EXIT trap until the final print. The wake drain
# removes records from the queue as it reads them, so a run stopped before the
# final print still prints the never-cut head it gathered.
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
print_head_on_exit() {
  printf 'INTERRUPTED: session start stopped before its digest was complete; rerun it for the rest.\n'
  render_head
}

# --- 1. lock -----------------------------------------------------------
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
READ_ONLY=0
[ "$LOCK_RC" -eq 0 ] || READ_ONLY=1
if [ "$READ_ONLY" -eq 0 ]; then
  rm -f "$STATE/.captain-hold"
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
fi
unset DRAIN_OUT GUARD_OUT
QLEN=0
EXTENSION_DIAG=
SUPERVISION_OUT=
trap print_head_on_exit EXIT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 130' INT

# --- 2. bootstrap --------------------------------------------------------
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi

# --- 3. supervision operating instructions ----------------------------------
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

EXTENSION_DIAG=
if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf -v EXTENSION_DIAG 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
if [ "$PRIMARY_HARNESS" = omp ]; then
  OMP_EXT="$FM_ROOT/.omp/extensions/fm-primary-omp.ts"
  if ! pi_extension_loaded "$STATE/.omp-extension-loaded" "$(hash_file "$OMP_EXT" || printf '')" "$STATE/.lock"; then
    printf -v EXTENSION_DIAG 'OMP_EXTENSION: not loaded - restart omp from %s without --no-extensions so %s auto-loads for the turn-end guard and the watcher-arm seatbelt\n' "$FM_ROOT" "$OMP_EXT"
  fi
fi
capture "$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"
SUPERVISION_OUT=$CAPTURED

# --- 4. context digest: rule files -----------------------------------------
# Index order is the printed order; RULE_FILL_ORDER is the budget priority.
# shellcheck disable=SC2329 # Invoked through capture.
render_context_preamble() {
  section "CONTEXT"
  cat <<'EOF'
ABSENT below is meaningful and never the same as a present-but-empty file:
data/captain.md absent = use the firstmate repo's built-in defaults;
data/captain-shared.md absent = no shared captain preferences;
data/secondmates.md absent = no registered secondmates;
data/learnings.md absent = no captured learnings yet;
data/projects.md absent or stale = rebuild the registry from the clones under
projects/ before dispatching any work.
EOF
}
capture render_context_preamble
CONTEXT_PREAMBLE=$CAPTURED

RULE_COUNT=6
RULE_FILL_ORDER='2 5 3 4 0 1'
RULE_NAME=(data/projects.md data/secondmates.md data/captain.md data/captain-shared.md data/learnings.md CLAUDE.local.md)
RULE_PATH=("$DATA/projects.md" "$DATA/secondmates.md" "$DATA/captain.md" "$DATA/captain-shared.md" "$DATA/learnings.md" "$FM_HOME/CLAUDE.local.md")
RULE_LABEL=(data/projects.md data/secondmates.md data/captain.md "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)" data/learnings.md "")
RULE_CANDIDATE=()
RULE_PRINTED=()
RULE_FIXED=()
RULE_FULL=()
RULE_HELD=()
RULE_STOP=()

# rule_full_block <label> <path>: a labeled subsection with the file's exact bytes.
# shellcheck disable=SC2329 # Invoked through capture.
rule_full_block() {
  subsection "$1"
  cat "$2"
}

# rule_held_block <label> <abs-path>: what stands in for a rule file that did
# not fit; its content never appears, only where to read it.
# shellcheck disable=SC2329 # Invoked through capture.
rule_held_block() {
  subsection "$1"
  printf 'NOT PRINTED - read %s in full first (see the STOP line at the top)\n' "$2"
}

i=0
while [ "$i" -lt "$RULE_COUNT" ]; do
  RULE_CANDIDATE[i]=0
  RULE_PRINTED[i]=0
  RULE_FIXED[i]=
  path=${RULE_PATH[i]}
  label=${RULE_LABEL[i]}
  if [ "$i" -eq 5 ]; then
    # The home's personal rules: printed for every primary except Claude, which
    # loads them natively. Missing rules are silent.
    label=$path
    RULE_LABEL[i]=$label
    if [ "$PRIMARY_HARNESS" = claude ]; then
      :
    elif [ -e "$path" ] || [ -L "$path" ]; then
      if [ -f "$path" ] && LOCAL_RULES_TEXT=$(cat "$path" 2>/dev/null); then
        RULE_CANDIDATE[i]=1
        capture subsection "$label"
        RULE_FULL[i]="$CAPTURED$LOCAL_RULES_TEXT"$'\n'
      else
        printf -v line 'CLAUDE_LOCAL: unreadable %s; personal rules could not be loaded\n' "$path"
        RULE_FIXED[i]=$line
      fi
    fi
  elif [ -f "$path" ] && [ -s "$path" ]; then
    RULE_CANDIDATE[i]=1
    capture rule_full_block "$label" "$path"
    RULE_FULL[i]=$CAPTURED
  elif [ -f "$path" ]; then
    capture subsection "$label"
    RULE_FIXED[i]=$CAPTURED$'(present, empty)\n'
  else
    capture subsection "$label"
    RULE_FIXED[i]=$CAPTURED$'ABSENT\n'
  fi
  if [ "${RULE_CANDIDATE[i]}" -eq 1 ]; then
    abs_path "$path"
    capture rule_held_block "$label" "$REPLY"
    RULE_HELD[i]=$CAPTURED
    printf -v line 'STOP: rule file not printed - read %s in full with your file-read tool before any other action (%s bytes)\n' \
      "$REPLY" "$(file_bytes "$path")"
    RULE_STOP[i]=$line
  fi
  i=$((i + 1))
done

# --- 5. fleet-state digest -------------------------------------------------
# Every source is read once here; render_fleet only re-renders these strings
# at the shortening level the budget allows.
abs_path "$DATA/backlog.md"
BACKLOG_ABS=$REPLY
abs_path "$STATE"
STATE_ABS=$REPLY

# backlog_records_tasks_axi: reads `tasks-axi list` output on stdin and emits
# "inflight|held <TAB> id <TAB> title" records plus one "scanned" record.
# tasks-axi's own "... (truncated, ...)" title suffix shortens to "...".
backlog_records_tasks_axi() {
  awk '
    function parse(line,   i, c, n, inq, f, len) {
      n = 0; f = ""; inq = 0; len = length(line)
      for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\\" && i < len) {
            i++
            c = substr(line, i, 1)
            if (c == "n" || c == "t") c = " "
            f = f c
          } else if (c == "\"") {
            inq = 0
          } else {
            f = f c
          }
        } else if (c == "\"") {
          inq = 1
        } else if (c == ",") {
          F[++n] = f; f = ""
        } else {
          f = f c
        }
      }
      F[++n] = f
      return n
    }
    /^count: / {
      shown = $2
      total = ($3 == "of") ? $4 : $2
      next
    }
    /^tasks\[[0-9]+\]\{.*\}:$/ {
      cols = $0
      sub(/^[^{]*\{/, "", cols)
      sub(/\}:$/, "", cols)
      ncols = split(cols, names, ",")
      for (k = 1; k <= ncols; k++) col[names[k]] = k
      rows = 1
      next
    }
    rows && /^  / {
      parse(substr($0, 3))
      id = F[col["id"]]; state = F[col["state"]]; title = F[col["title"]]
      hold = ("hold_kind" in col) ? F[col["hold_kind"]] : ""
      gsub(/\t/, " ", title)
      sub(/ *\.\.\. \(truncated, [0-9]+ chars total - use show [^ ]+ --full to see complete text\)$/, "...", title)
      if (state == "in_flight") print "inflight\t" id "\t" title
      else if (state == "queued" && hold == "captain") print "held\t" id "\t" title
      next
    }
    rows { rows = 0 }
    END { printf "scanned\t%s\t%s\n", shown + 0, total + 0 }
  '
}

# backlog_records_manual <path>: the same records from data/backlog.md title
# lines, scanning at most BACKLOG_LIMIT items, plus one "heldtotal" record
# counting the captain-held items in the whole file.
backlog_records_manual() {
  awk -v max="$BACKLOG_LIMIT" '
    /^##[[:space:]]+/ {
      heading = $0
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      state = ""
      if (heading == "In flight") state = "inflight"
      else if (heading == "Queued") state = "queued"
      else if (heading == "Done") state = "done"
      next
    }
    state != "" && /^[-*][[:space:]]+/ {
      total++
      captain_held = (state == "queued" && index($0, "(hold-kind: captain)"))
      if (captain_held) held_total++
      if (total > max) next
      line = $0
      sub(/^[-*][[:space:]]+(\[[ xX]\][[:space:]]+)?/, "", line)
      id = line
      sub(/[[:space:]].*$/, "", id)
      title = substr(line, length(id) + 1)
      sub(/^[[:space:]]+-[[:space:]]+/, "", title)
      if (match(title, /[[:space:]]+(\([a-z][a-z_-]*:[[:space:]]|blocked-by:)/)) title = substr(title, 1, RSTART - 1)
      if (state == "inflight") print "inflight\t" id "\t" title
      else if (captain_held) print "held\t" id "\t" title
    }
    END {
      shown = (total > max) ? max : total
      printf "scanned\t%d\t%d\n", shown, total
      printf "heldtotal\t%d\t\n", held_total
    }
  ' "$1"
}

BACKLOG_MODE=absent
BACKLOG_NOTICE=
BACKLOG_RECORDS=
if [ -f "$DATA/backlog.md" ]; then
  if [ ! -s "$DATA/backlog.md" ]; then
    BACKLOG_MODE=empty
  else
    BACKLOG_MODE=manual
    BACKLOG_SOURCE='manual backend'
    if fm_tasks_axi_backend_available "$CONFIG"; then
      # The second, unbounded held listing makes the captain-held count exact
      # even when the scan stops short; either failure falls back to the file.
      if TASKS_AXI_OUT=$(tasks-axi list --file "$DATA/backlog.md" --limit "$BACKLOG_LIMIT" --fields hold_kind 2>&1) \
        && TASKS_AXI_RECORDS=$(printf '%s\n' "$TASKS_AXI_OUT" | backlog_records_tasks_axi) \
        && TASKS_AXI_OUT=$(tasks-axi list --file "$DATA/backlog.md" --state held --limit "$BACKLOG_HELD_COUNT_LIMIT" --fields hold_kind 2>&1); then
        BACKLOG_MODE=tasks-axi
        held_count=$(printf '%s\n' "$TASKS_AXI_OUT" | backlog_records_tasks_axi | grep -c '^held')
        BACKLOG_RECORDS=$TASKS_AXI_RECORDS$'\n'"heldtotal"$'\t'"$held_count"
      else
        BACKLOG_SOURCE=fallback
        printf -v BACKLOG_NOTICE 'tasks-axi compact listing failed; falling back to title-line rendering.\n%s\n' "$TASKS_AXI_OUT"
      fi
    elif ! fm_backlog_backend_manual "$CONFIG"; then
      BACKLOG_SOURCE='tasks-axi unavailable or incompatible'
    fi
    [ "$BACKLOG_MODE" = tasks-axi ] || BACKLOG_RECORDS=$(backlog_records_manual "$DATA/backlog.md")
  fi
fi
# BACKLOG_HELD_CMD prints exactly the rows the captain-held count counts:
# queued items whose hold kind is captain, never in-flight or other holds.
if [ "$BACKLOG_MODE" = tasks-axi ]; then
  BACKLOG_OTHER_CMD="tasks-axi list --file=$BACKLOG_ABS"
  BACKLOG_HELD_CMD="tasks-axi list --file=$BACKLOG_ABS --state held --fields hold_kind | grep -E '^  [^,]+,queued,.*,captain\$'"
else
  BACKLOG_OTHER_CMD=$BACKLOG_ABS
  if [ "$BACKLOG_MODE" = manual ] && [ "$BACKLOG_SOURCE" != fallback ] && fm_tasks_axi_compatible; then
    BACKLOG_OTHER_CMD="tasks-axi list --file=$BACKLOG_ABS"
  fi
  BACKLOG_HELD_CMD="awk '/^##[[:space:]]/ { q = /^##[[:space:]]+Queued[[:space:]]*\$/; next } q && /^[-*][[:space:]]/ && index(\$0, \"(hold-kind: captain)\")' $BACKLOG_ABS"
fi

# render_backlog <reduced 0|1>
# shellcheck disable=SC2329 # Invoked through capture.
render_backlog() {
  local reduced=$1 kind id title shown=0 total=0 inflight=0 held=0 held_total=0
  subsection "data/backlog.md"
  case "$BACKLOG_MODE" in
    absent) printf 'ABSENT\n'; return ;;
    empty) printf '(present, empty)\n'; return ;;
  esac
  if [ "$reduced" -eq 0 ]; then
    case "$BACKLOG_MODE" in
      tasks-axi) printf 'compact backlog listing (tasks-axi; in-flight and captain-held items only; max %s item(s) scanned; task bodies omitted)\n' "$BACKLOG_LIMIT" ;;
      *) printf 'compact backlog listing (%s; in-flight and captain-held items only; max %s item(s) scanned; indented task bodies omitted)\n' "$BACKLOG_SOURCE" "$BACKLOG_LIMIT" ;;
    esac
  fi
  printf '%s' "$BACKLOG_NOTICE"
  while IFS=$'\t' read -r kind id title; do
    case "$kind" in
      inflight) inflight=$((inflight + 1)) ;;
      held) held=$((held + 1)) ;;
      heldtotal) held_total=$id ;;
      scanned) shown=$id; total=$title ;;
    esac
  done <<EOF
$BACKLOG_RECORDS
EOF
  printf 'In flight (%s):\n' "$inflight"
  while IFS=$'\t' read -r kind id title; do
    [ "$kind" = inflight ] || continue
    if [ "$reduced" -eq 1 ]; then
      printf '%s\n' "$id"
    else
      printf '%s - %s\n' "$id" "$title"
    fi
  done <<EOF
$BACKLOG_RECORDS
EOF
  if [ "$reduced" -eq 1 ]; then
    printf 'Captain-held items: %s - list them with: %s\n' "$held_total" "$BACKLOG_HELD_CMD"
  else
    if [ "$held" -eq "$held_total" ]; then
      printf 'Captain-held (%s):\n' "$held"
    else
      printf 'Captain-held (%s in the backlog; %s of them within the scanned items listed below - list all with: %s):\n' \
        "$held_total" "$held" "$BACKLOG_HELD_CMD"
    fi
    while IFS=$'\t' read -r kind id title; do
      [ "$kind" = held ] && printf '%s - %s\n' "$id" "$title"
    done <<EOF
$BACKLOG_RECORDS
EOF
  fi
  [ "$shown" -lt "$total" ] && printf '(scanned %s of %s backlog item(s); raise FM_SESSION_START_BACKLOG_LIMIT to scan more)\n' "$shown" "$total"
  [ "$reduced" -eq 0 ] || return 0
  printf 'Other backlog items: %s\n' "$BACKLOG_OTHER_CMD"
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}
capture render_backlog 0
BACKLOG_FULL=$CAPTURED
capture render_backlog 1
BACKLOG_REDUCED=$CAPTURED

META_IDS=()
META_TEXT=()
META_REDUCED=()
META_ENDPOINT=()
META_ENDPOINT_SHORT=()
META_TAIL=()
META_TAIL_ONE=()
META_COUNT=0
META_SHRINKS=0
TAIL_SHRINKS=0

# status_tail_block <path> <lines>
# shellcheck disable=SC2329 # Invoked through capture.
status_tail_block() {
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$2" "$1"
  tail -n "$2" "$1"
}

# status_last_line_block <path>: the one-line form; its FLEET_TRUNCATED line
# names where the full logs live.
# shellcheck disable=SC2329 # Invoked through capture.
status_last_line_block() {
  printf 'last status line (wake-EVENT history, not current state):\n'
  tail -n 1 "$1"
}

# The endpoint-liveness reads run external CLIs that can hang, so they run
# here, before the wake drain; read_task_records runs after it.
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  META_IDS[META_COUNT]=$id
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      liveness=alive
    else
      liveness=dead
    fi
    printf -v line 'endpoint: %s (backend=%s window=%s)\n' "$liveness" "$backend" "$window"
    META_ENDPOINT[META_COUNT]=$line
    # The shortened meta keeps its window= line, so the endpoint drops the copy.
    printf -v line 'endpoint: %s (backend=%s)\n' "$liveness" "$backend"
    META_ENDPOINT_SHORT[META_COUNT]=$line
  else
    META_ENDPOINT[META_COUNT]=$'endpoint: unknown (no window recorded)\n'
    META_ENDPOINT_SHORT[META_COUNT]=${META_ENDPOINT[META_COUNT]}
  fi
  META_COUNT=$((META_COUNT + 1))
done

ORPHAN_IDS=()
ORPHAN_TAIL=()
ORPHAN_COUNT=0

# read_task_records: every task record body and status tail, and the orphan
# status tails. Called after the wake drain, whose PR auto-registration writes
# pr= into state/<id>.meta, so the printed records include it.
read_task_records() {
  local n=0 meta status id line
  while [ "$n" -lt "$META_COUNT" ]; do
    meta="$STATE/${META_IDS[n]}.meta"
    capture cat "$meta"
    META_TEXT[n]=$CAPTURED
    capture grep -E '^(window|kind|harness|model|mode|pr)=' "$meta"
    META_REDUCED[n]=$CAPTURED
    [ "${META_TEXT[n]}" = "${META_REDUCED[n]}" ] || META_SHRINKS=1

    status="$STATE/${META_IDS[n]}.status"
    if [ -f "$status" ]; then
      capture status_tail_block "$status" "$STATUS_TAIL"
      META_TAIL[n]=$CAPTURED
      capture status_last_line_block "$status"
      META_TAIL_ONE[n]=$CAPTURED
      [ "$(tail -n "$STATUS_TAIL" "$status")" = "$(tail -n 1 "$status")" ] || TAIL_SHRINKS=1
    else
      printf -v line 'status tail: (no status file yet: %s)\n' "$status"
      META_TAIL[n]=$line
      META_TAIL_ONE[n]=$line
    fi
    n=$((n + 1))
  done

  for status in "$STATE"/*.status; do
    [ -f "$status" ] || continue
    id=$(basename "$status" .status)
    [ -f "$STATE/$id.meta" ] && continue
    ORPHAN_IDS[ORPHAN_COUNT]=$id
    capture status_tail_block "$status" "$STATUS_TAIL"
    ORPHAN_TAIL[ORPHAN_COUNT]=$CAPTURED
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
  done
}

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
PUBLIC_FOLLOWUP=
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
fi

# shellcheck disable=SC2329 # Invoked through capture.
render_fleet_tail() {
  subsection "AFK"
  if [ -e "$STATE/.afk" ]; then
    printf 'present - away-mode supervision is active; follow /afk.\n'
  else
    printf 'absent\n'
  fi
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments awaiting delivery"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public reply this home still owes. Reconcile terminal results with\n'
    printf '%s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Load fmx-respond for the procedure.\n' "$FM_ROOT"
  fi
}
capture render_fleet_tail
FLEET_TAIL=$CAPTURED

# set_fleet_level <0-4>: the cumulative shortening steps in force. A step
# that would change nothing is not applied, so it never claims a shortening.
set_fleet_level() {
  TRUNC_ORPHANS=0 TRUNC_TAILS=0 TRUNC_METAS=0 TRUNC_BACKLOG=0
  [ "$1" -ge 1 ] && [ "$ORPHAN_COUNT" -gt 0 ] && TRUNC_ORPHANS=1
  [ "$1" -ge 2 ] && [ "$TAIL_SHRINKS" -eq 1 ] && TRUNC_TAILS=1
  [ "$1" -ge 3 ] && [ "$META_SHRINKS" -eq 1 ] && TRUNC_METAS=1
  [ "$1" -ge 4 ] && [ "$BACKLOG_FULL" != "$BACKLOG_REDUCED" ] && TRUNC_BACKLOG=1
  return 0
}

# shellcheck disable=SC2329 # Invoked through capture.
render_fleet() {
  local n
  section "FLEET STATE"
  [ "$TRUNC_ORPHANS" -eq 1 ] && printf 'FLEET_TRUNCATED: orphan status tails dropped - see %s/<id>.status for each orphan listed below\n' "$STATE_ABS"
  [ "$TRUNC_TAILS" -eq 1 ] && printf 'FLEET_TRUNCATED: per-task status tails cut to 1 line - see %s/<id>.status\n' "$STATE_ABS"
  [ "$TRUNC_METAS" -eq 1 ] && printf 'FLEET_TRUNCATED: state/*.meta bodies reduced to window, kind, harness, model, mode, pr lines - see %s/<id>.meta\n' "$STATE_ABS"
  [ "$TRUNC_BACKLOG" -eq 1 ] && printf 'FLEET_TRUNCATED: backlog reduced to in-flight ids and a captain-held count - see %s\n' "$BACKLOG_OTHER_CMD"
  if [ "$TRUNC_BACKLOG" -eq 1 ]; then
    printf '%s' "$BACKLOG_REDUCED"
  else
    printf '%s' "$BACKLOG_FULL"
  fi

  subsection "Work under way (state/*.meta)"
  n=0
  while [ "$n" -lt "$META_COUNT" ]; do
    printf '\n--- %s ---\n' "${META_IDS[n]}"
    if [ "$TRUNC_METAS" -eq 1 ]; then
      printf '%s%s' "${META_REDUCED[n]}" "${META_ENDPOINT_SHORT[n]}"
    else
      printf '%s%s' "${META_TEXT[n]}" "${META_ENDPOINT[n]}"
    fi
    if [ "$TRUNC_TAILS" -eq 1 ]; then
      printf '%s' "${META_TAIL_ONE[n]}"
    else
      printf '%s' "${META_TAIL[n]}"
    fi
    n=$((n + 1))
  done
  [ "$META_COUNT" -gt 0 ] || printf '(none)\n'

  subsection "Orphan status logs (state/*.status without matching .meta)"
  n=0
  while [ "$n" -lt "$ORPHAN_COUNT" ]; do
    printf '\n--- %s ---\n' "${ORPHAN_IDS[n]}"
    if [ "$TRUNC_ORPHANS" -eq 1 ]; then
      printf 'status tail dropped; full log: %s/%s.status\n' "$STATE_ABS" "${ORPHAN_IDS[n]}"
    else
      printf '%s' "${ORPHAN_TAIL[n]}"
    fi
    n=$((n + 1))
  done
  [ "$ORPHAN_COUNT" -gt 0 ] || printf '(none)\n'
  printf '%s' "$FLEET_TAIL"
}

# --- 6. closing reminder -----------------------------------------------
# Generated from what this run actually printed, so it never tells the reader
# to skip a file that was not printed in full.
# shellcheck disable=SC2329 # Invoked through capture.
render_next() {
  local i printed='' deferred=0
  section "NEXT STEP"
  for i in $RULE_FILL_ORDER; do
    [ "${RULE_CANDIDATE[i]}" -eq 1 ] && [ "${RULE_PRINTED[i]}" -eq 0 ] || continue
    if [ "$deferred" -eq 0 ]; then
      printf 'These rule files were NOT printed (see the STOP lines at the top):\n'
      deferred=1
    fi
    abs_path "${RULE_PATH[i]}"
    printf '  %s - read it first, in full, before any other action.\n' "$REPLY"
  done
  [ "$deferred" -eq 0 ] || printf '\n'

  if [ "$READ_ONLY" -eq 1 ]; then
    cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
  elif [ "$AFK_PRESENT" -eq 1 ]; then
    cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk for the selected supervision owner.

EOF
  elif [ "$X_MODE_PRESENT" -eq 1 ]; then
    cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
  else
    cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
  fi

  if [ "$deferred" -eq 1 ]; then
    printf 'The digest above is NOT complete: read every file named on a STOP line first.\n'
  else
    printf 'The digest above is complete for this session start.\n'
  fi
  i=0
  while [ "$i" -lt "$RULE_COUNT" ]; do
    if [ "${RULE_CANDIDATE[i]}" -eq 1 ] && [ "${RULE_PRINTED[i]}" -eq 1 ]; then
      if [ "$i" -eq 5 ]; then
        printed="$printed, ${RULE_PATH[i]}"
      else
        printed="$printed, ${RULE_NAME[i]}"
      fi
    elif [ "${RULE_CANDIDATE[i]}" -eq 0 ] && [ -f "${RULE_PATH[i]}" ] && [ "$i" -ne 5 ]; then
      printed="$printed, ${RULE_NAME[i]}"
    fi
    i=$((i + 1))
  done
  [ "$META_COUNT" -gt 0 ] && [ "$TRUNC_METAS" -eq 0 ] && printed="$printed, state/*.meta"
  [ -z "$printed" ] || printf 'Printed in full above - do NOT re-read now: %s.\n' "${printed#, }"
  [ "$TRUNC_METAS" -eq 0 ] || printf 'state/*.meta were shortened; read one when its task needs the rest.\n'
  if [ "$TRUNC_BACKLOG" -eq 1 ]; then
    printf 'data/backlog.md was reduced; list the rest with the FLEET_TRUNCATED command when needed.\n'
  else
    printf 'Do NOT bulk-read data/backlog.md now either: its in-flight and captain-held\nitems were just printed with a pointer for the rest.\n'
  fi
  cat <<'EOF'
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed; read one full log only when older wake-event history is needed.
Re-read a file only if this digest flagged it ABSENT (then rebuild or create
it per AGENTS.md) or its contents looked unparseable/corrupt.
EOF
}

# --- 7. wake drain, after every step that can hang -----------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land in WAKE QUEUE too, ahead of the bulk digest.
# It runs after every step that can hang, still under the session lock, so a run
# killed before it leaves every record queued; its output is never cut and is
# measured in the head below before any budget decision. The read-only path
# never touches the queue because it lacks mutation authority, and another
# session may be actively draining it. It still runs fm-guard.sh directly with non-mutating
# advisory text, so the same alarms surface without repair commands.
if [ "$READ_ONLY" -eq 1 ]; then
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
else
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
fi
capture render_head
HEAD_TEXT=$CAPTURED
read_task_records

# --- 8. assemble under the byte budget ---------------------------------
# assemble: DIGEST and its byte size in REPLY, from the current decisions.
assemble() {
  local i next fleet
  DIGEST=
  for i in $RULE_FILL_ORDER; do
    [ "${RULE_CANDIDATE[i]}" -eq 1 ] && [ "${RULE_PRINTED[i]}" -eq 0 ] && DIGEST+=${RULE_STOP[i]}
  done
  DIGEST+=$HEAD_TEXT$CONTEXT_PREAMBLE
  i=0
  while [ "$i" -lt "$RULE_COUNT" ]; do
    if [ "${RULE_CANDIDATE[i]}" -eq 0 ]; then
      DIGEST+=${RULE_FIXED[i]}
    elif [ "${RULE_PRINTED[i]}" -eq 1 ]; then
      DIGEST+=${RULE_FULL[i]}
    else
      DIGEST+=${RULE_HELD[i]}
    fi
    i=$((i + 1))
  done
  capture render_fleet
  fleet=$CAPTURED
  capture render_next
  next=$CAPTURED
  DIGEST+=$fleet$next
  byte_len "$DIGEST"
}

# Rule files take what remains after the never-cut lines, in fill order, each
# whole or not at all; the fully shortened fleet state is reserved first so a
# printed rule file can never push the digest past the budget.
set_fleet_level 4
for i in $RULE_FILL_ORDER; do
  [ "${RULE_CANDIDATE[i]}" -eq 1 ] || continue
  RULE_PRINTED[i]=1
  assemble
  [ "$REPLY" -le "$SESSION_BUDGET_BYTES" ] || RULE_PRINTED[i]=0
done
level=0
while :; do
  set_fleet_level "$level"
  assemble
  [ "$REPLY" -le "$SESSION_BUDGET_BYTES" ] && break
  [ "$level" -ge 4 ] && break
  level=$((level + 1))
done

# The drained records are in this print, so a stop signal must not cut it.
trap '' TERM HUP INT
trap - EXIT
printf '%s' "$DIGEST"
exit 0
