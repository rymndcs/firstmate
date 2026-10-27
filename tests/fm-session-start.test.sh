#!/usr/bin/env bash
# tests/fm-session-start.test.sh - behavior tests for bin/fm-session-start.sh,
# the single command that collapses AGENTS.md sections 3 (bootstrap) and 5
# (recovery) into one ordered digest.
#
# Coverage:
#   - absent-file markers vs empty-but-present files in the context digest
#   - the lock-refusal read-only path: banner leads, every mutating step is
#     skipped (including bootstrap's MUTATING sweeps, verified by their
#     ABSENCE; bin/fm-bootstrap.sh's header owns their enumeration under
#     FM_BOOTSTRAP_DETECT_ONLY), the digest still completes
#   - output section ordering: diagnostics/banners lead, bulk file dumps follow
#   - context-aware next-step guidance for read-only, AFK, X mode, and normal
#     watcher ownership
#   - status-tail bounding, default and FM_SESSION_START_STATUS_TAIL override
#   - the output budget: leading STOP lines for rule files that do not fit,
#     never-cut lines, FLEET_TRUNCATED shortening, and a real-size fixture
#   - orphan status logs whose task meta has already disappeared
#   - per-task endpoint-liveness lines for a live and a dead recorded target,
#     tmux and herdr both
#   - composition: the script invokes the real fm-lock.sh/fm-bootstrap.sh/
#     fm-wake-drain.sh (their real, distinctive output appears verbatim), it
#     does not reimplement their logic
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-start-tests)
SESSION_START_SECOND_MATE_ID="fmtest-sm-${TMP_ROOT##*.}"
SESSION_START_SECOND_MATE_TMP="/tmp/fm-$SESSION_START_SECOND_MATE_ID"
SESSION_START_HERDR_SECOND_MATE_ID="fmtest-herdr-${TMP_ROOT##*.}"
SESSION_START_HERDR_SECOND_MATE_TMP="/tmp/fm-$SESSION_START_HERDR_SECOND_MATE_ID"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT" "$SESSION_START_SECOND_MATE_TMP" "$SESSION_START_HERDR_SECOND_MATE_TMP")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

# --- world builders ----------------------------------------------------------

# new_world <name>: a real, throwaway git repo on `main` (so the worktree-tangle
# and default-branch checks behave exactly as they do against the real
# firstmate repo) to use as FM_ROOT_OVERRIDE, plus an empty FM_HOME with
# state/, data/, config/, and a fakebin. Echoes "<root-dir>|<home-dir>|<fakebin>".
new_world() {
  local name=$1 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" config --local commit.gpgsign false
  git -C "$root" config --local tag.gpgsign false
  git -C "$root" commit -q --allow-empty -m init
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

# make_fake_toolchain <fakebin>: every tool fm-bootstrap.sh detects, present
# and compatible, so its own detect-only section stays quiet except where a
# test deliberately breaks one. Mirrors fm-bootstrap.test.sh's fixture.
make_fake_toolchain() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' manual > "${fakebin%/*}/home-placeholder" 2>/dev/null || true
}

make_fake_tasks_axi_compact() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TASKS_AXI_LOG:-}
[ -n "$log" ] && printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' '0.2.3'
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'
      exit 0
    fi
    ;;
  list)
    case "$*" in
      *'--fields '*'body'*|*'--fields='*'body'*)
        printf '%s\n' 'unexpected body field requested' >&2
        exit 9
        ;;
    esac
    case "$*" in *'--file '*|*'--file='*) : ;; *) printf '%s\n' 'missing explicit backlog file' >&2; exit 9 ;; esac
    case "$*" in
      *'--state held'*)
        if [ -n "${FM_FAKE_TASKS_AXI_HELD_FAIL:-}" ]; then
          printf '%s\n' 'HELD-LISTING-FAILED' >&2
          exit 7
        fi
        case "$*" in *'--fields hold_kind'*) : ;; *) printf '%s\n' 'missing hold_kind field' >&2; exit 9 ;; esac
        cat <<'OUT'
count: 5
tasks[5]{id,state,kind,repo,title,hold_kind}:
  compact-startup,in_flight,ship,firstmate,Compact startup digest,captain
  title-says-queued,in_flight,ship,firstmate,"A title with ,queued, inside",captain
  held-decision,queued,captain,firstmate,"Pick, then \"ship\" the library",captain
  held-past-scan,queued,captain,firstmate,Held beyond the scanned items,captain
  external-wait,queued,ship,firstmate,Waits on upstream,external
OUT
        exit 0
        ;;
    esac
    case "$*" in *'--limit 80'*) : ;; *) printf '%s\n' 'missing compact limit' >&2; exit 9 ;; esac
    cat <<'OUT'
count: 5 of 6 total
tasks[5]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:
  compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending
  long-title-task,in_flight,ship,firstmate,"Restore deleted-trigger names in automation logs https://github.com/advisorfirst\n... (truncated, 98 chars total - use show long-title-task --full to see complete text)",none,"-","-"
  blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"
  held-decision,queued,captain,firstmate,"Pick, then \"ship\" the library",none,captain,"HOLD-REASON-TEXT, quoted"
  done-captain-item,done,captain,firstmate,Finished captain decision,none,captain,"-"
help[2]:
  - Run `tasks-axi show <id> --full` for full notes on a task
  - Run `tasks-axi ready` to see unblocked queued work
OUT
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
}

make_fake_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' '0.1.16'
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

# make_fake_ps_claude <fakebin>: harness_pid()/holder_alive() (fm-lock.sh) walk
# `ps` output looking for a harness command name; this fake reports EVERY
# queried pid as a live `claude` harness, so the very first ancestry check
# (this test process's own pid) matches and lock acquisition succeeds
# deterministically. Mirrors fm-grok-harness.test.sh's fake ps.
make_fake_ps_claude() {
  local fakebin=$1
  make_fake_ps_harness "$fakebin" claude
}

make_fake_ps_harness() {
  local fakebin=$1 harness=$2
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
harness=${FM_FAKE_HARNESS:-claude}
case "$*" in
  *"comm="*) printf '/usr/local/bin/%s\n' "$harness"; exit 0 ;;
  *"args="*) printf '%s\n' "$harness"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$harness" > "$fakebin/.harness-name"
}

make_fake_ps_pi_holder() {  # <fakebin> <holder-pid> [harness]
  local fakebin=$1 holder_pid=$2 harness=${3:-pi}
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"comm="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf '/usr/local/bin/$harness\n'
    else
      printf '/bin/zsh\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf '$harness\n'
    else
      printf 'zsh\n'
    fi
    exit 0
    ;;
  *"ppid="*) printf '%s\n' "$holder_pid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_tmux <fakebin> <live-target>: display-message succeeds only for
# the given "session:window" target - the exact primitive
# fm_backend_target_exists uses for a tmux endpoint liveness read.
make_fake_tmux() {
  local fakebin=$1 live=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    target=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "-t" ] && target="\$a"
      prev="\$a"
    done
    [ "\$target" = "$live" ] && { printf '%%1\n'; exit 0; }
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# make_fake_tmux_gated <fakebin>: the liveness probe for fm-sess:hung writes
# one line to the FM_FAKE_REACHED FIFO, then blocks until the test writes to
# the FM_FAKE_GATE FIFO, so a signal lands mid-probe with no timed wait.
make_fake_tmux_gated() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-} $*" in
  display-message*' -t fm-sess:hung '*)
    printf 'reached\n' > "$FM_FAKE_REACHED"
    cat "$FM_FAKE_GATE" > /dev/null
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# make_fake_no_mistakes_gated <fakebin>: bootstrap's first version check
# blocks the same way, so a signal lands before the wake drain runs.
make_fake_no_mistakes_gated() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  if [ ! -e "$FM_FAKE_GATE.used" ]; then
    : > "$FM_FAKE_GATE.used"
    printf 'reached\n' > "$FM_FAKE_REACHED"
    cat "$FM_FAKE_GATE" > /dev/null
  fi
  printf '%s\n' 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# make_fake_git_gated_after_drain <fakebin> <home>: the first worktree check
# once the wake queue is empty - the drain's own watcher guard, after the drain
# has written and deleted its records - blocks the same way; every other call
# runs the real git.
make_fake_git_gated_after_drain() {
  local fakebin=$1 home=$2 real_git
  real_git=$(PATH=$BASE_PATH command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${3:-} \${4:-}" = 'rev-parse --is-inside-work-tree' ] && [ ! -s '$home/state/.wake-queue' ] \\
  && [ ! -e "\$FM_FAKE_GATE.used" ]; then
  : > "\$FM_FAKE_GATE.used"
  printf 'reached\n' > "\$FM_FAKE_REACHED"
  cat "\$FM_FAKE_GATE" > /dev/null
fi
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin/git"
}

# sigint_ignored_on_entry: true when this shell started with SIGINT ignored
# (for example as a background job of a non-interactive shell). bash can then
# neither trap nor restore it, so a child cannot be interrupted with INT.
sigint_ignored_on_entry() {
  [ "$(bash -c 'trap "echo caught" INT; kill -INT $$')" != caught ]
}

# make_fake_tmux_secondmate_recovery <fakebin>: a stateful tmux boundary
# fixture for the real session-start -> bootstrap -> spawn path.
# FM_FAKE_TMUX_MODE selects missing, ambiguous, unreadable, or shell; missing
# reproduces real tmux's active-window fallback while inventory omits the mate.
make_fake_tmux_secondmate_recovery() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_FAKE_TMUX_MODE:?}
log=${FM_FAKE_TMUX_LOG:?}
spawned=${FM_FAKE_TMUX_SPAWNED:?}
killed=${spawned}.killed
mate_home=${FM_FAKE_SECOND_MATE_HOME:?}
mate_id=${FM_FAKE_SECOND_MATE_ID:?}
mate_window="fm-$mate_id"
case "${1:-}" in
  display-message)
    target=
    format=
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && target=$arg
      prev=$arg
      case "$arg" in '#{'*) format=$arg ;; esac
    done
    if [ "${target#%}" != "$target" ]; then
      case "$format" in
        *pane_current_path*) printf '%s\n' "$mate_home" ;;
        *pane_current_command*) printf '%s\n' node ;;
        *) printf '%s\n' "$target" ;;
      esac
      exit 0
    fi
    if [ -e "$spawned" ]; then
      case "$format" in
        *pane_current_command*) printf '%s\n' node ;;
        *) printf '%%1\n' ;;
      esac
      exit 0
    fi
    case "$mode" in
      ambiguous)
        case "$format" in *pane_current_command*) printf '%s\n' node ;; *) printf '%%1\n' ;; esac
        exit 0
        ;;
      shell)
        case "$format" in *pane_current_command*) printf '%s\n' zsh ;; *) printf '%%1\n' ;; esac
        exit 0
        ;;
      missing)
        case "$format" in *pane_current_command*) printf '%s\n' node ;; *) printf '%%fallback\n' ;; esac
        exit 0
        ;;
      unreadable) exit 1 ;;
    esac
    ;;
  list-windows)
    if [ "$mode" = unreadable ] && [ ! -e "$spawned" ] && [ ! -e "$killed" ]; then
      exit 1
    fi
    if [ -e "$spawned" ]; then
      printf '%s\n' "$mate_window"
    elif [ ! -e "$killed" ] && { [ "$mode" = ambiguous ] || [ "$mode" = shell ]; }; then
      printf '%s\n' "$mate_window"
    else
      printf '%s\n' main
    fi
    exit 0
    ;;
  has-session) exit 0 ;;
  kill-window)
    printf '%s\n' "$*" >> "$log"
    : > "$killed"
    exit 0
    ;;
  new-window)
    printf '%s\n' "$*" >> "$log"
    : > "$spawned"
    printf '%%1\n'
    exit 0
    ;;
  set-window-option|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

make_fake_herdr_secondmate_recovery() {
  local fakebin=$1
  # The recovery kill now requires the shared named-session lock and an exact
  # focus snapshot. Keep a focused sibling tab so this test's husk close is
  # provably non-workspace-emptying and never needs to signal a fake shell pid.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_HERDR_LOG:?}
state=${FM_FAKE_HERDR_STATE:?}
mate_id=${FM_FAKE_SECOND_MATE_ID:?}
killed="${state}.killed"
spawned="${state}.spawned"
printf '%s\n' "$*" >> "$log"
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"protocol":14,"version":"test"},"server":{"running":true}}'
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s.sock"}]}\n' "$state"
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"ws1","label":"2ndmate-%s","focused":true,"active_tab_id":"t-focus"}]}}\n' "$mate_id"
    ;;
  "tab list")
    if [ -e "$spawned" ]; then
      printf '{"result":{"tabs":[{"tab_id":"t-focus","workspace_id":"ws1","label":"captain","focused":true},{"tab_id":"t-new","workspace_id":"ws1","label":"fm-%s","focused":false}]}}\n' "$mate_id"
    elif [ -e "$killed" ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"t-focus","workspace_id":"ws1","label":"captain","focused":true}]}}'
    else
      printf '{"result":{"tabs":[{"tab_id":"t-focus","workspace_id":"ws1","label":"captain","focused":true},{"tab_id":"t-old","workspace_id":"ws1","label":"fm-%s","focused":false}]}}\n' "$mate_id"
    fi
    ;;
  "tab create")
    : > "$spawned"
    printf '%s\n' '{"result":{"tab":{"tab_id":"t-new"},"root_pane":{"pane_id":"p-new"}}}'
    ;;
  "pane list")
    if [ -e "$spawned" ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"p-new","tab_id":"t-new"}]}}'
    elif [ ! -e "$killed" ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"p-old","tab_id":"t-old"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[]}}'
    fi
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" = p-new ] && [ -e "$spawned" ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"p-new","tab_id":"t-new","workspace_id":"ws1"}}}'
    elif [ "$pane" = p-old ] && [ ! -e "$killed" ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"p-old","tab_id":"t-old","workspace_id":"ws1"}}}'
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    ;;
  "agent get")
    if [ "${3:-}" = p-new ] && [ -e "$spawned" ]; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    ;;
  "pane close")
    [ "${3:-}" = p-old ] && : > "$killed"
    ;;
  "pane run"|"pane send-text"|"pane send-keys"|"tab close")
    ;;
  *)
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

# make_fake_herdr <fakebin> <live-pane>: `herdr pane get <pane>` succeeds only
# for the given pane id - the exact primitive fm_backend_target_exists uses
# for a herdr endpoint liveness read. No version/server-start calls: a
# liveness check must never auto-start a server (fm-backend.sh's contract).
make_fake_herdr() {
  local fakebin=$1 live=$2
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  [ "\${3:-}" = "$live" ] && exit 0
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/herdr"
}

# run_session_start <home> <root> <path>
# Drop every harness env marker from bin/fm-harness.sh detect_own so the
# surrounding interactive shell cannot leak past the suite's fake ps harness.
# Markers today: CLAUDECODE (claude), PI_CODING_AGENT plus FM_PI_HARNESS
# (Pi family), GROK_AGENT (grok).
# codex and opencode have no env markers (ancestry only). Without this, a local
# claude/pi/grok session fails cases that pin a different fake harness while CI
# (no ambient markers) still passes.
run_session_start() {
  local home=$1 root=$2 path=$3 pi_harness=${4:-}
  if [ -n "$pi_harness" ]; then
    env -u CLAUDECODE -u GROK_AGENT PI_CODING_AGENT=true FM_PI_HARNESS="$pi_harness" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  else
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  fi
}

# prepare_session_start_secondmate <name>: a throwaway main home and Pi
# secondmate home wired to the real spawn implementation through the fixture
# root. Echoes root|home|fakebin|mate|log|spawned.
prepare_session_start_secondmate() {
  local name=$1 rec root home fakebin w mate log spawned id=$SESSION_START_SECOND_MATE_ID
  rec=$(new_world "$name")
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  w=${root%/root}
  mate="$w/secondmate-$id"
  log="$w/tmux.log"
  spawned="$w/tmux.spawned"
  mkdir -p "$mate/bin" "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'Second mate charter.\n' > "$mate/data/charter.md"
  printf '%s\n' pi > "$home/config/secondmate-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'harness=pi\n'
    printf 'home=%s\n' "$mate"
  } > "$home/state/$id.meta"
  ln -s "$ROOT/bin" "$root/bin"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux_secondmate_recovery "$fakebin"
  : > "$log"
  printf '%s|%s|%s|%s|%s|%s\n' "$root" "$home" "$fakebin" "$mate" "$log" "$spawned"
}

run_session_start_secondmate() {
  local root=$1 home=$2 fakebin=$3 mate=$4 log=$5 spawned=$6 mode=$7
  TMUX='' FM_BACKEND=tmux FM_FAKE_TMUX_MODE="$mode" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_SPAWNED="$spawned" FM_FAKE_SECOND_MATE_HOME="$mate" \
    FM_FAKE_SECOND_MATE_ID="$SESSION_START_SECOND_MATE_ID" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH"
}

prepare_session_start_herdr_secondmate() {
  local name=$1 rec root home fakebin w mate log state id=$SESSION_START_HERDR_SECOND_MATE_ID
  rec=$(new_world "$name")
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  w=${root%/root}
  mate="$w/secondmate-$id"
  log="$w/herdr.log"
  state="$w/herdr.state"
  mkdir -p "$mate/bin" "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'Second mate charter.\n' > "$mate/data/charter.md"
  printf '%s\n' herdr > "$home/config/backend"
  printf '%s\n' pi > "$home/config/secondmate-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  {
    printf 'window=default:p-old\n'
    printf 'kind=secondmate\n'
    printf 'harness=pi\n'
    printf 'home=%s\n' "$mate"
    printf 'backend=herdr\n'
    printf 'herdr_session=default\n'
    printf 'herdr_workspace_id=ws1\n'
    printf 'herdr_tab_id=t-old\n'
    printf 'herdr_pane_id=p-old\n'
  } > "$home/state/$id.meta"
  ln -s "$ROOT/bin" "$root/bin"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr_secondmate_recovery "$fakebin"
  : > "$log"
  printf '%s|%s|%s|%s|%s|%s\n' "$root" "$home" "$fakebin" "$mate" "$log" "$state"
}

run_session_start_herdr_secondmate() {
  local root=$1 home=$2 fakebin=$3 mate=$4 log=$5 state=$6
  FM_BACKEND=herdr FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_SECOND_MATE_ID="$SESSION_START_HERDR_SECOND_MATE_ID" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH"
}

hash_file_for_test() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

install_pi_turnend_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$root/.pi/extensions/fm-primary-turnend-guard.ts"
}

install_pi_watch_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$root/.pi/extensions/fm-primary-pi-watch.ts"
}

write_pi_watch_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n%s\n' "$version" "$pid" > "$home/state/.pi-watch-extension-loaded"
}

write_pi_turnend_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-turnend-guard.ts")
  printf '%s\n%s\n' "$version" "$pid" > "$home/state/.pi-turnend-extension-loaded"
}

write_pi_loaded_markers() {
  local home=$1 root=$2 pid=$3
  write_pi_watch_loaded_marker "$home" "$root" "$pid"
  write_pi_turnend_loaded_marker "$home" "$root" "$pid"
}

# --- context digest: absent vs empty vs present -----------------------------

test_context_digest_absent_empty_present() {
  local rec root home fakebin out printed
  rec=$(new_world context-digest)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf '%s\n' '- demo [no-mistakes] - a demo project (added 2026-07-01)' > "$home/data/projects.md"
  : > "$home/data/captain.md"
  # secondmates.md, captain-shared.md, and learnings.md deliberately absent

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "data/projects.md" "digest did not label the projects.md section"
  assert_contains "$out" "- demo [no-mistakes] - a demo project (added 2026-07-01)" "digest did not print projects.md content"

  assert_contains "$out" "data/captain.md" "digest did not label the captain.md section"
  assert_contains "$out" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)" \
    "digest did not label the shared captain section"

  assert_contains "$out" "data/secondmates.md" "digest did not label the secondmates.md section"
  assert_contains "$out" "data/learnings.md" "digest did not label the learnings.md section"

  # Exactly four context ABSENT markers (secondmates.md, captain-shared.md,
  # learnings.md; backlog.md is covered by its own test) - and the
  # present-but-empty captain.md must NOT print ABSENT.
  absent_count=$(printf '%s\n' "$out" | grep -c '^ABSENT$')
  [ "$absent_count" -eq 4 ] || fail "expected 4 ABSENT markers (secondmates.md, captain-shared.md, learnings.md, backlog.md), got $absent_count: $out"

  cap_section=$(printf '%s\n' "$out" | awk '/^data\/captain\.md$/{flag=1;next}/^data\//{flag=0}flag')
  assert_contains "$cap_section" "(present, empty)" "empty-but-present captain.md was not distinguished from ABSENT"
  printed=$(printf '%s\n' "$out" | grep '^Printed in full above')
  assert_contains "$printed" "data/projects.md, data/captain.md." "NEXT STEP omitted a printed or empty rule file"
  assert_not_contains "$printed" "data/secondmates.md" "NEXT STEP named an ABSENT rule file as printed in full"

  pass "context digest distinguishes ABSENT, empty-but-present, and populated files"
}

# --- lock refusal: read-only path --------------------------------------------

test_lock_refusal_read_only_path() {
  local rec root home fakebin holder_pid out status
  rec=$(new_world lock-refusal)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf "held\n" > "$home/state/.captain-hold"

  # A live secondmate meta with a window pointed at nothing real - if the
  # bootstrap sweep's secondmate_sync ran (a MUTATING step), it would try to
  # fast-forward this "home" and/or report a SECONDMATE_SYNC/NUDGE_SECONDMATES
  # line. Absence of any such line is this test's proof that
  # FM_BOOTSTRAP_DETECT_ONLY=1 actually suppressed the mutating sweep.
  mkdir -p "$home/other-secondmate/state"
  fm_write_secondmate_meta "$home/state/sm-x.meta" "$home/other-secondmate" "firstmate:fm-sm-x" alpha
  append_wake "$home/state" signal sm-x "done: surfaced before refusal" || fail "seed wake failed"
  git -C "$root" checkout -q -B fm/read-only-tangle

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"

  status=0
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  expect_code 0 "$status" "fm-session-start.sh must exit 0 even on a lock refusal"
  assert_contains "$out" "READ-ONLY SESSION" "read-only banner missing on lock refusal"
  assert_contains "$out" "another live firstmate session holds the lock" "read-only banner did not surface fm-lock.sh's own error text"
  assert_contains "$out" "Skipping every mutating step" "read-only banner did not explain what was skipped"
  assert_contains "$out" "skipped (read-only session)" "wake-queue section did not report itself skipped"
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "read-only guard did not surface watcher-liveness alarm"
  assert_contains "$out" "queued wakes pending - left untouched because this session lacks verified fleet-lock ownership" "read-only guard did not leave queued wakes untouched without verified lock ownership"
  assert_contains "$out" "TANGLE: primary checkout on feature branch 'fm/read-only-tangle'" "read-only bootstrap did not surface the tangle diagnostic"
  assert_contains "$out" "read-only session must leave restore work" "read-only tangle diagnostic did not explain restore ownership"
  assert_contains "$out" "Stay read-only: do not arm" "read-only next step did not block direct watcher repair"
  assert_not_contains "$out" "drain them with bin/fm-wake-drain.sh" "read-only guard printed a mutating drain instruction"
  assert_not_contains "$out" "After draining queued wakes" "read-only guard printed a drain-then-rearm instruction"
  assert_not_contains "$out" "run bin/fm-watch-arm.sh" "read-only guard printed a mutating watcher-arm instruction"
  assert_not_contains "$out" "git -C $root checkout main" "read-only bootstrap printed a state-changing checkout remediation"

  # Detect-only bootstrap diagnostics still ran (the fakebin's PATH excludes
  # tasks-axi, so bootstrap's own read-only tool-detection line fires
  # deterministically regardless of what is installed on the test host).
  assert_contains "$out" "MISSING: tasks-axi (install:" "detect-only bootstrap diagnostics did not run on the read-only path"

  # The mutating secondmate sweep must NOT have run: no SECONDMATE_SYNC/
  # NUDGE_SECONDMATES line, and the sowed secondmate meta's target dir is
  # untouched (fm-ff-lib would have tried to fast-forward it otherwise).
  assert_not_contains "$out" "SECONDMATE_SYNC" "mutating secondmate sweep ran during a lock refusal"
  assert_not_contains "$out" "NUDGE_SECONDMATES" "mutating secondmate sweep ran during a lock refusal"

  # The rest of the digest (read-only-safe) still completed.
  assert_contains "$out" "FLEET STATE" "fleet-state digest section missing on the read-only path"
  assert_contains "$out" "NEXT STEP" "closing reminder missing on the read-only path"

  [ -e "$home/state/.captain-hold" ] || fail "read-only session cleared captain hold"
  pass "a lock refusal prints a loud read-only banner, skips every mutating step, and still completes the digest"
}

test_lock_write_failure_read_only_path() {
  local rec root home fakebin out status
  rec=$(new_world lock-write-failure)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  append_wake "$home/state" signal task-a "done: must remain queued" || fail "seed wake failed"
  chmod 0500 "$home/state"

  status=0
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?
  chmod 0700 "$home/state"

  expect_code 0 "$status" "fm-session-start.sh must exit 0 when lock publication fails"
  assert_contains "$out" "cannot write session lock" "lock publication failure was not surfaced"
  assert_contains "$out" "READ-ONLY SESSION" "lock publication failure did not force a read-only session"
  assert_contains "$out" "FLEET LOCK OWNERSHIP WAS NOT VERIFIED" "lock publication failure was misreported as a live holder"
  assert_contains "$out" "lacks verified fleet-lock ownership" "lock publication failure did not explain why queued wakes remain untouched"
  assert_not_contains "$out" "ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK" "lock publication failure falsely claimed a live lock holder"
  [ -s "$home/state/.wake-queue" ] || fail "lock publication failure allowed the wake queue to mutate"

  pass "session start stays read-only when lock ownership cannot be published"
}

test_trace_context_effective_state_is_frozen_after_lock() {
  local rec root home fakebin out frozen
  rec=$(new_world trace-context-session-state)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  : > "$home/config/trace-context"

  FM_TRACE_CONTEXT=off run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  [ "$(awk '{print $2}' "$home/state/.trace-context-effective")" = off ] \
    || fail "session start must freeze an env-off override over a present config flag"

  rm "$home/config/trace-context"
  FM_TRACE_CONTEXT=on run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  [ "$(awk '{print $2}' "$home/state/.trace-context-effective")" = on ] \
    || fail "a new session start must freeze an env-on override over an absent config flag"
  frozen=$(cat "$home/state/.trace-context-effective")

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  out=$(FM_TRACE_CONTEXT=off run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  assert_contains "$out" "READ-ONLY SESSION" "trace-context refusal fixture did not enter read-only mode"
  [ "$(cat "$home/state/.trace-context-effective")" = "$frozen" ] \
    || fail "a lock-refused session must not mutate the frozen trace-context state"

  pass "locked session start freezes trace context and lock refusal leaves it unchanged"
}

test_session_lock_concurrent_single_winner() {
  local rec root home fakebin ready completed winners pids i pid count
  rec=$(new_world lock-concurrency)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  ready="$home/ready"
  completed="$home/done"
  winners="$home/winners"
  mkdir -p "$ready" "$completed"
  : > "$winners"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ -f "$FM_FAKE_LOCK_STATE/harness-$pid" ]; then
      printf '%s\n' /usr/local/bin/claude
    else
      printf '%s\n' /bin/bash
    fi
    ;;
  *"args="*)
    if [ -f "$FM_FAKE_LOCK_STATE/harness-$pid" ]; then
      printf '%s\n' claude
    else
      printf '%s\n' bash
    fi
    ;;
  *"ppid="*) printf '%s\n' "$FM_FAKE_HARNESS_PID" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  pids=
  i=1
  while [ "$i" -le 40 ]; do
    (
      harness_pid=$(sh -c 'printf "%s\n" "$PPID"')
      : > "$home/state/harness-$harness_pid"
      : > "$ready/$i"
      while [ "$(find "$ready" -type f | wc -l | tr -d ' ')" -lt 40 ]; do
        sleep 0.01
      done
      if FM_HOME="$home" FM_FAKE_LOCK_STATE="$home/state" \
        FM_FAKE_HARNESS_PID="$harness_pid" PATH="$fakebin:$BASE_PATH" \
        "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1; then
        printf '%s\n' "$harness_pid" >> "$winners"
      fi
      : > "$completed/$i"
      while [ "$(find "$completed" -type f | wc -l | tr -d ' ')" -lt 40 ]; do
        sleep 0.01
      done
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  count=$(awk 'NF { count++ } END { print count + 0 }' "$winners")
  [ "$count" -eq 1 ] || fail "concurrent session-lock acquisition produced $count winners"

  pass "concurrent session-lock acquisition admits exactly one live harness"
}

# --- output ordering ----------------------------------------------------------

test_output_ordering_diagnostics_lead() {
  local rec root home fakebin out lock_line boot_line wake_line context_line fleet_line next_line
  rec=$(new_world ordering)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # Force a MISSING diagnostic line so the bootstrap section is non-trivial.
  rm -f "$fakebin/node"

  printf 'window=fm-sess:w1\nkind=ship\n' > "$home/state/task-a.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  lock_line=$(printf '%s\n' "$out" | grep -n '^LOCK$' | head -1 | cut -d: -f1)
  boot_line=$(printf '%s\n' "$out" | grep -n '^BOOTSTRAP$' | head -1 | cut -d: -f1)
  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  fleet_line=$(printf '%s\n' "$out" | grep -n '^FLEET STATE$' | head -1 | cut -d: -f1)
  next_line=$(printf '%s\n' "$out" | grep -n '^NEXT STEP$' | head -1 | cut -d: -f1)

  if [ -z "$lock_line" ] || [ -z "$boot_line" ] || [ -z "$wake_line" ] || [ -z "$context_line" ] || [ -z "$fleet_line" ] || [ -z "$next_line" ]; then
    fail "one or more section headers missing from digest: $out"
  fi

  [ "$lock_line" -lt "$boot_line" ] || fail "LOCK did not precede BOOTSTRAP"
  [ "$boot_line" -lt "$wake_line" ] || fail "BOOTSTRAP did not precede WAKE QUEUE"
  [ "$wake_line" -lt "$context_line" ] || fail "WAKE QUEUE did not precede CONTEXT"
  [ "$context_line" -lt "$fleet_line" ] || fail "CONTEXT did not precede FLEET STATE"
  [ "$fleet_line" -lt "$next_line" ] || fail "FLEET STATE did not precede NEXT STEP"

  missing_line=$(printf '%s\n' "$out" | grep -n 'MISSING: node' | head -1 | cut -d: -f1)
  [ -n "$missing_line" ] || fail "MISSING diagnostic did not appear at all"
  [ "$missing_line" -lt "$fleet_line" ] || fail "actionable MISSING diagnostic was buried after the bulk fleet-state digest"

  pass "digest sections are ordered diagnostics-first, bulk-context-last"
}

test_herdr_backend_diagnostics_follow_real_session_start() {
  local mode rec root home fakebin mask out
  for mode in configured autodetected; do
    rec=$(new_world "herdr-$mode")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    rm -f "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" herdr jq
    printf '%s\n' manual > "$home/config/backlog-backend"
    mask="$home/mask-tmux.bash"
    cat > "$mask" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = tmux ]; then
    return 1
  fi
  builtin command "$@"
}
SH
    if [ "$mode" = configured ]; then
      printf '%s\n' herdr > "$home/config/backend"
      out=$(TMUX='' HERDR_ENV='' BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_not_contains "$out" "NOTICE: auto-detected herdr runtime" \
        "an explicit Herdr home should not be reported as auto-detected"
    else
      out=$(TMUX='' HERDR_ENV=1 BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_contains "$out" "NOTICE: auto-detected herdr runtime (HERDR_ENV=1)" \
        "session start did not preserve the Herdr runtime auto-detection fallback"
    fi
    assert_contains "$out" "SESSION START - $home" "the real session-start path did not run in the throwaway home"
    assert_not_contains "$out" "MISSING: tmux" "Herdr session start falsely required masked tmux"
    assert_not_contains "$out" "MISSING: herdr" "Herdr session start missed its available session CLI"
    assert_not_contains "$out" "MISSING: jq" "Herdr session start missed its available JSON dependency"
    assert_not_contains "$out" "MISSING: treehouse" "Herdr session start missed its available worktree provider"
  done
  pass "session start: configured and auto-detected Herdr homes never require tmux"
}

# --- status tail bounding -----------------------------------------------------

test_status_tail_bounding() {
  local rec root home fakebin out
  rec=$(new_world status-tail)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live"

  printf 'window=fm-sess:live\nkind=ship\n' > "$home/state/task-a.meta"
  printf 'working: step 1\nworking: step 2\nworking: step 3\nworking: step 4\nworking: step 5\nworking: step 6\nworking: step 7\n' \
    > "$home/state/task-a.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "default status tail missing the most recent line"
  assert_contains "$out" "working: step 5" "default status tail (3 lines) missing an expected recent line"
  assert_not_contains "$out" "working: step 4" "default status tail (3 lines) leaked an older line"
  assert_contains "$out" "$home/state/task-a.status" "digest did not print the full status log path for a deeper read"
  assert_contains "$out" "Do NOT bulk-read state/*.status now either: their bounded tails were just" "closing reminder does not distinguish bounded status tails"
  assert_not_contains "$out" "state/*.status now - they were just" "closing reminder still describes status logs as fully printed"

  out=$(FM_SESSION_START_STATUS_TAIL=2 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "working: step 7" "FM_SESSION_START_STATUS_TAIL=2 tail missing the most recent line"
  assert_not_contains "$out" "working: step 5" "FM_SESSION_START_STATUS_TAIL=2 did not bound the tail to 2 lines"

  pass "status tail is bounded to the configured line count, with the full log path always printed"
}

test_orphan_status_logs_are_printed() {
  local rec root home fakebin out matched_count orphan_count
  rec=$(new_world orphan-status)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf 'kind=ship\n' > "$home/state/task-a.meta"
  printf 'matched: surfaced once\n' > "$home/state/task-a.status"
  printf 'orphan: step 1\norphan: step 2\norphan: step 3\norphan: step 4\norphan: step 5\norphan: step 6\n' \
    > "$home/state/task-orphan.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "Orphan status logs (state/*.status without matching .meta)" "digest did not label orphan status logs"
  assert_contains "$out" "--- task-orphan ---" "digest did not print the orphan status id"
  assert_contains "$out" "orphan: step 6" "orphan status tail missing the newest line"
  assert_contains "$out" "orphan: step 4" "orphan status tail (3 lines) missing an expected recent line"
  assert_not_contains "$out" "orphan: step 3" "orphan status tail was not bounded to the 3-line default"
  assert_contains "$out" "$home/state/task-orphan.status" "orphan status tail did not print the full log path"

  matched_count=$(printf '%s\n' "$out" | grep -F -c 'matched: surfaced once')
  orphan_count=$(printf '%s\n' "$out" | grep -F -c 'orphan: step 6')
  [ "$matched_count" -eq 1 ] || fail "matched status log was printed $matched_count times: $out"
  [ "$orphan_count" -eq 1 ] || fail "orphan status log was printed $orphan_count times: $out"

  pass "orphan status logs are printed once with bounded tails"
}

# --- session-start secondmate recovery boundary -----------------------------

test_session_start_relaunches_missing_pi_secondmate() {
  local rec root home fakebin mate log spawned out first_calls second_calls
  rec=$(prepare_session_start_secondmate secondmate-missing-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing)

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful missing-window recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "new-window" "session start did not relaunch the missing Pi secondmate"
  assert_not_contains "$(cat "$log")" "kill-window" "session start tried to kill an already-absent window"
  assert_contains "$out" "endpoint: alive (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later fleet read did not confirm the relaunched window"
  assert_grep 'harness=pi' "$home/state/$SESSION_START_SECOND_MATE_ID.meta" \
    "the real respawn path did not preserve the Pi harness: $(cat "$home/state/$SESSION_START_SECOND_MATE_ID.meta")"

  first_calls=$(grep -c 'new-window' "$log" || true)
  rm -f "$home/state/.lock"
  run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" missing >/dev/null
  second_calls=$(grep -c 'new-window' "$log" || true)
  [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ] \
    || fail "a second session-start pass duplicated the relaunched Pi secondmate: $(cat "$log")"
  pass "session start: an absent recorded tmux window relaunches its Pi secondmate exactly once"
}

test_session_start_preserves_ambiguous_pi_process() {
  local rec root home fakebin mate log spawned out
  rec=$(prepare_session_start_secondmate secondmate-ambiguous-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" ambiguous)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate $SESSION_START_SECOND_MATE_ID: skipped: existing endpoint has ambiguous agent process (backend=tmux)" \
    "session start did not distinguish an existing Pi-shaped process from a missing window"
  [ ! -s "$log" ] || fail "session start touched an ambiguous existing Pi process: $(cat "$log")"
  assert_contains "$out" "endpoint: alive (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later fleet read should still see the ambiguous endpoint"
  pass "session start: an existing ambiguous Pi process prevents duplicate recovery"
}

test_session_start_preserves_transiently_unreadable_tmux() {
  local rec root home fakebin mate log spawned out
  rec=$(prepare_session_start_secondmate secondmate-unreadable-pi)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" unreadable)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate $SESSION_START_SECOND_MATE_ID: skipped: endpoint probe unreadable (backend=tmux)" \
    "session start did not distinguish transient unreadability from absence"
  [ ! -s "$log" ] || fail "session start touched a transiently unreadable target: $(cat "$log")"
  assert_contains "$out" "endpoint: dead (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later cheap presence read should preserve the visible offline symptom"
  pass "session start: transient tmux unreadability never licenses a relaunch"
}

test_session_start_preserves_proven_bare_shell_recovery() {
  local rec root home fakebin mate log spawned out
  rec=$(prepare_session_start_secondmate secondmate-bare-shell)
  IFS='|' read -r root home fakebin mate log spawned <<EOF
$rec
EOF

  out=$(run_session_start_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$spawned" shell)

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful bare-shell recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-$SESSION_START_SECOND_MATE_ID" \
    "the proven bare-shell path did not remove its existing dead endpoint"
  assert_contains "$(cat "$log")" "new-window" "the proven bare-shell path did not relaunch"
  assert_contains "$out" "endpoint: alive (backend=tmux window=firstmate:fm-$SESSION_START_SECOND_MATE_ID)" \
    "the later fleet read did not confirm the bare-shell relaunch"
  pass "session start: the proven bare-shell recovery path remains intact"
}

test_session_start_relaunches_herdr_husk_secondmate() {
  local rec root home fakebin mate log state out
  rec=$(prepare_session_start_herdr_secondmate secondmate-herdr-husk)
  IFS='|' read -r root home fakebin mate log state <<EOF
$rec
EOF

  out=$(run_session_start_herdr_secondmate "$root" "$home" "$fakebin" "$mate" "$log" "$state")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "successful Herdr husk recovery should stay non-actionable"
  assert_contains "$(cat "$log")" "pane close p-old" "session start did not close the confirmed Herdr husk"
  assert_contains "$(cat "$log")" "tab create" "session start did not relaunch the Herdr secondmate"
  assert_contains "$out" "endpoint: alive (backend=herdr window=default:p-new)" \
    "the later fleet read did not confirm the relaunched Herdr endpoint"
  assert_grep 'herdr_pane_id=p-new' "$home/state/$SESSION_START_HERDR_SECOND_MATE_ID.meta" \
    "the real respawn path did not record the replacement Herdr pane"
  pass "session start: a confirmed Herdr husk is closed and relaunched"
}

# --- endpoint liveness: tmux and herdr, live and dead ------------------------

test_endpoint_liveness_tmux() {
  local rec root home fakebin out
  rec=$(new_world liveness-tmux)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tmux "$fakebin" "fm-sess:live-window"

  printf 'window=fm-sess:live-window\nkind=ship\n' > "$home/state/task-live.meta"
  printf 'window=fm-sess:dead-window\nkind=ship\n' > "$home/state/task-dead.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "endpoint: alive (backend=tmux window=fm-sess:live-window)" "live tmux endpoint not reported alive"
  assert_contains "$out" "endpoint: dead (backend=tmux window=fm-sess:dead-window)" "dead tmux endpoint not reported dead"

  pass "tmux endpoint liveness is reported per task: alive for a live window, dead for a gone one"
}

test_endpoint_liveness_herdr() {
  local rec root home fakebin out
  rec=$(new_world liveness-herdr)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr "$fakebin" "p-live"

  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-live.meta"
  printf 'window=sess:p-dead\nkind=ship\nbackend=herdr\n' > "$home/state/task-dead.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "endpoint: alive (backend=herdr window=sess:p-live)" "live herdr endpoint not reported alive"
  assert_contains "$out" "endpoint: dead (backend=herdr window=sess:p-dead)" "dead herdr endpoint not reported dead"

  pass "herdr endpoint liveness is reported per task: alive for a live pane, dead for a gone one"
}

test_pr_registered_by_drain_is_in_printed_meta() {
  local rec root home fakebin out
  rec=$(new_world drain-registers-pr)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"

  printf 'kind=ship\n' > "$home/state/task-pr.meta"
  printf 'done: PR https://github.com/o/r/pull/7 checks green\n' > "$home/state/task-pr.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  grep -qx 'pr=https://github.com/o/r/pull/7' "$home/state/task-pr.meta" \
    || fail "the wake drain did not register the PR, so this test proves nothing: $(cat "$home/state/task-pr.meta")"
  printf '%s\n' "$out" | awk '/^--- task-pr ---$/ { found = 1; next } found && /^endpoint: / { exit } found' \
    | grep -qx 'pr=https://github.com/o/r/pull/7' \
    || fail "the printed task record predates the PR the drain registered: $out"
  assert_contains "$(next_step_section "$out")" "Printed in full above - do NOT re-read now: state/*.meta." \
    "NEXT STEP no longer says the task records were printed in full"

  pass "a PR the wake drain registers appears in the printed task record that NEXT STEP calls complete"
}

# --- composition: real scripts run, not reimplemented ------------------------

test_composition_invokes_real_scripts() {
  local rec root home fakebin out
  rec=$(new_world composition)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  rm -f "$fakebin/node"

  printf 'needs-decision: pick a library\n' > "$home/state/task-z.status"
  append_wake "$home/state" signal task-z.status "needs-decision: pick a library"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # fm-lock.sh's own exact success text.
  assert_contains "$out" "lock acquired: harness pid" "fm-lock.sh's real output did not appear (composition, not reimplementation)"
  # fm-bootstrap.sh's own exact MISSING-tool line format.
  assert_contains "$out" "MISSING: node (install:" "fm-bootstrap.sh's real detect line did not appear verbatim"
  # fm-wake-drain.sh's real drained record (raw tab-separated queue line).
  assert_contains "$out" "$(printf 'signal\ttask-z.status\tneeds-decision: pick a library')" "fm-wake-drain.sh's real drained record did not appear"
  assert_contains "$out" "wake annotation: latest wake-EVENT observed at drain, not current state: task-z.status: needs-decision: pick a library" "fm-session-start.sh did not preserve the drain's separate annotation line"
  [ "$(printf '%s\n' "$out" | grep -c "$(printf 'signal\ttask-z.status')")" = 1 ] \
    || fail "a finished run printed its drained wake record more than once"
  assert_not_contains "$out" "INTERRUPTED:" "a finished run printed the interrupted-run head"

  pass "fm-session-start.sh composes the real fm-lock.sh, fm-bootstrap.sh, and fm-wake-drain.sh output verbatim"
}

# --- interrupted run: drained wakes still print -----------------------------

# interrupt_session_start <sigs> <run-dir> <home> <root> <fakebin>: start
# session start in the background, wait on the <run-dir>/reached FIFO until a
# gated fake blocks, send each signal in <sigs> in turn, open the gate and wait
# for the exit, all without a timed wait. Job control keeps INT deliverable to a
# background run; the wrapper records the script's pid, then reports its exit
# on the same FIFO, and its stderr drops the shell's notice of a killed run.
interrupt_session_start() {
  local sigs=$1 run=$2 home=$3 root=$4 fakebin=$5 line group sig
  mkdir -p "$run"
  mkfifo "$run/reached" "$run/gate"
  set -m
  {
    /bin/sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' sh "$run/pid" \
      env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
      FM_FAKE_REACHED="$run/reached" FM_FAKE_GATE="$run/gate" \
      "$SESSION_START" > "$run/out" 2>&1
    printf 'exited\n' > "$run/reached"
  } 2>/dev/null &
  group=$!
  set +m
  read -r line < "$run/reached"
  [ "$line" = reached ] || fail "$sigs run exited before its gated step: $(cat "$run/out")"
  for sig in $sigs; do
    kill -"$sig" "$(cat "$run/pid")"
  done
  printf 'release\n' > "$run/gate"
  read -r line < "$run/reached"
  wait "$group"
}

# skip_int_if_ignored <sig>: true, with a SKIP line, for INT when this shell
# started with SIGINT ignored, so the test reports why instead of failing.
skip_int_if_ignored() {
  [ "$1" = INT ] && sigint_ignored_on_entry || return 1
  pass "SKIP (SIGINT ignored on entry, so INT cannot reach session start): $2"
}

test_killed_liveness_probe_leaves_wakes_queued() {
  local sigs rec root home fakebin n=0
  for sigs in KILL 'TERM KILL'; do
    n=$((n + 1))
    rec=$(new_world "killed-probe-$n")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    make_fake_tmux_gated "$fakebin"
    printf '%s\n' manual > "$home/config/backlog-backend"
    printf 'window=fm-sess:hung\nkind=ship\n' > "$home/state/task-hung.meta"
    append_wake "$home/state" signal task-wake "done: WAKE-RECORD-MUST-SURVIVE" || fail "seed wake failed"

    interrupt_session_start "$sigs" "$home/../interrupt" "$home" "$root" "$fakebin"

    [ "$(grep -c 'WAKE-RECORD-MUST-SURVIVE' "$home/state/.wake-queue")" = 1 ] \
      || fail "$sigs during a hung liveness check did not leave the wake record queued: $(cat "$home/../interrupt/out")"
  done

  pass "a run killed during a hung liveness check, with or without TERM first, leaves its wake records queued"
}

test_interrupted_drain_prints_drained_wakes() {
  local sig rec root home fakebin out
  for sig in TERM HUP INT; do
    skip_int_if_ignored "$sig" "an interrupted drain prints its records" && continue
    rec=$(new_world "interrupted-drain-$sig")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    make_fake_git_gated_after_drain "$fakebin" "$home"
    printf '%s\n' manual > "$home/config/backlog-backend"
    append_wake "$home/state" signal task-wake "done: WAKE-RECORD-MUST-SURVIVE" || fail "seed wake failed"

    interrupt_session_start "$sig" "$home/../interrupt" "$home" "$root" "$fakebin"
    out=$(cat "$home/../interrupt/out")

    case "$(first_nonempty_line "$out")" in INTERRUPTED:*) ;; *) fail "$sig run did not lead with the INTERRUPTED line: $out" ;; esac
    [ "$(printf '%s\n' "$out" | grep -c 'WAKE-RECORD-MUST-SURVIVE')" = 1 ] \
      || fail "$sig run did not print the drained wake record exactly once: $out"
    assert_not_contains "$(cat "$home/state/.wake-queue")" "WAKE-RECORD-MUST-SURVIVE" "$sig run left the record queued, so the drain never ran"
    assert_contains "$out" "lock acquired: harness pid" "$sig run lost the LOCK output"
    printf '%s\n' "$out" | grep -qx 'BOOTSTRAP' || fail "$sig run lost the BOOTSTRAP section"
    printf '%s\n' "$out" | grep -qx 'WAKE QUEUE' || fail "$sig run lost the WAKE QUEUE section"
    assert_not_contains "$out" "NEXT STEP" "$sig run printed a digest it never finished"
  done

  pass "a run stopped by TERM, HUP or INT after the drain wrote its records still prints LOCK, BOOTSTRAP and the drained wake records"
}

test_interrupted_bootstrap_prints_only_finished_steps() {
  local sig rec root home fakebin out
  for sig in TERM HUP INT; do
    skip_int_if_ignored "$sig" "an interrupted bootstrap prints only finished steps" && continue
    rec=$(new_world "interrupted-bootstrap-$sig")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    make_fake_no_mistakes_gated "$fakebin"
    printf '%s\n' manual > "$home/config/backlog-backend"
    append_wake "$home/state" signal task-wake "done: WAKE-RECORD-STAYS-QUEUED" || fail "seed wake failed"

    interrupt_session_start "$sig" "$home/../interrupt" "$home" "$root" "$fakebin"
    out=$(cat "$home/../interrupt/out")

    case "$(first_nonempty_line "$out")" in INTERRUPTED:*) ;; *) fail "$sig during bootstrap did not lead with the INTERRUPTED line: $out" ;; esac
    assert_contains "$out" "lock acquired: harness pid" "$sig during bootstrap lost the LOCK output"
    printf '%s\n' "$out" | grep -qx 'BOOTSTRAP' || fail "$sig during bootstrap lost the finished BOOTSTRAP section"
    assert_not_contains "$out" "WAKE QUEUE" "$sig during bootstrap reported a wake drain that never ran"
    assert_not_contains "$out" "unbound variable" "$sig during bootstrap read an unfinished step's output"
    assert_contains "$(cat "$home/state/.wake-queue")" "WAKE-RECORD-STAYS-QUEUED" "$sig during bootstrap lost a record it never drained"
  done

  pass "a run stopped by TERM, HUP or INT during bootstrap prints only the steps that finished and leaves the queue intact"
}

# A rule file larger than any pipe buffer keeps the final print writing into a
# reader that has taken one byte, so the signal lands mid-print with no timed
# wait.
test_signal_during_final_print_does_not_cut_the_digest() {
  local sig rec root home fakebin run group rc
  for sig in TERM HUP INT; do
    skip_int_if_ignored "$sig" "a signal during the final print does not cut the digest" && continue
    rec=$(new_world "signal-during-print-$sig")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    printf '%s\n' manual > "$home/config/backlog-backend"
    write_sized_file "$home/data/captain.md" 300000 CAPTAIN
    append_wake "$home/state" signal task-wake "done: WAKE-RECORD-PRINTED-ONCE" || fail "seed wake failed"
    run="$home/../print-signal"
    mkdir -p "$run"
    mkfifo "$run/out"

    set -m
    {
      /bin/sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' sh "$run/pid" \
        env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
        FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
        FM_SESSION_START_BUDGET_BYTES=1000000 \
        "$SESSION_START" > "$run/out" 2> "$run/err"
      printf '%s\n' "$?" > "$run/rc"
    } 2>/dev/null &
    group=$!
    set +m
    exec 3< "$run/out"
    dd bs=1 count=1 <&3 > "$run/digest" 2>/dev/null
    kill -"$sig" "$(cat "$run/pid")"
    cat <&3 >> "$run/digest"
    exec 3<&-
    wait "$group"
    rc=$(cat "$run/rc")

    [ "$rc" = 0 ] || fail "$sig during the final print stopped the run (exit $rc): $(cat "$run/err")"
    grep -qx 'CAPTAIN-LAST' "$run/digest" || fail "$sig during the final print cut data/captain.md short"
    [ "$(tail -n 1 "$run/digest")" = 'it per AGENTS.md) or its contents looked unparseable/corrupt.' ] \
      || fail "$sig during the final print cut the digest before the end of NEXT STEP: $(tail -n 3 "$run/digest")"
    [ "$(grep -c 'WAKE-RECORD-PRINTED-ONCE' "$run/digest")" = 1 ] \
      || fail "$sig during the final print did not print the drained wake record exactly once"
  done

  pass "a TERM, HUP or INT during the final print is ignored, so the whole digest still prints"
}

# --- fleet-state digest: compact backlog rendering --------------------------

# assert_held_hint_lists_count <out> <path>: the reduced backlog's "list them
# with" command, run on <path>, prints exactly as many rows as the count it
# follows.
assert_held_hint_lists_count() {
  local out=$1 path=$2 line count cmd rows
  line=$(printf '%s\n' "$out" | grep '^Captain-held items: ') || fail "no reduced captain-held line: $out"
  count=${line#Captain-held items: }
  count=${count%% *}
  cmd=${line#* - list them with: }
  rows=$(PATH=$path bash -c "$cmd" | grep -c .)
  [ "$rows" = "$count" ] || fail "the captain-held hint lists $rows row(s), not the $count it counts: $cmd"
}

write_long_body_backlog() {
  local path=$1
  cat > "$path" <<'EOF'
# Backlog

## In flight
- [ ] compact-startup - Compact startup digest (repo: firstmate) (kind: ship) (since 2026-07-15) (hold: captain choice pending) (hold-kind: captain)
  OVERSIZED-BODY-LINE current startup leaks task note bodies into the session digest.
  Another long body line that should not be printed after the fix.

## Queued
- [ ] blocked-followup - Follow compact startup blocked-by: compact-startup - waits for implementation (repo: firstmate) (kind: scout) (since 2026-07-15)
  QUEUED-BODY-LINE this is another long multiline note.
- [ ] held-decision - Pick the library (Option A) (repo: firstmate) (kind: captain) (since 2026-07-15) (hold: HOLD-REASON-TEXT) (hold-kind: captain)

## Done
EOF
}

test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata() {
  local rec root home fakebin out log held_cmd
  rec=$(new_world backlog-compact-tasks-axi)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  mkdir -p "$home/projects/firstmate"
  printf 'window=fm-sess:compact\nworktree=%s\nproject=firstmate\nkind=ship\n' "$home/projects/firstmate" \
    > "$home/state/compact-startup.meta"
  log="$home/tasks-axi.log"
  held_cmd="tasks-axi list --file=$home/data/backlog.md --state held --fields hold_kind | grep -E '^  [^,]+,queued,.*,captain\$'"

  out=$(FM_FAKE_TASKS_AXI_LOG="$log" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi; in-flight and captain-held items only; max 80 item(s) scanned; task bodies omitted)" \
    "compatible tasks-axi backend did not render the compact backlog listing"
  assert_contains "$out" "$(printf 'In flight (2):\ncompact-startup - Compact startup digest\nlong-title-task - Restore deleted-trigger names in automation logs https://github.com/advisorfirst...\nCaptain-held (2 in the backlog; 1 of them within the scanned items listed below - list all with: %s):\nheld-decision - Pick, then "ship" the library\n' "$held_cmd")" \
    "tasks-axi listing did not render in-flight and captain-held items as id - title under the exact captain-held count"
  assert_not_contains "$out" "(truncated," "tasks-axi listing kept the truncated-title suffix"
  assert_not_contains "$out" "done-captain-item" "tasks-axi listing printed a done item as captain-held"
  assert_not_contains "$out" "held-past-scan" "tasks-axi listing printed an item past the scanned items"
  assert_not_contains "$out" "blocked-followup" "tasks-axi listing printed a queued item that is not captain-held"
  assert_not_contains "$out" "HOLD-REASON-TEXT" "tasks-axi listing printed hold_reason text"
  assert_not_contains "$out" "captain choice pending" "tasks-axi listing printed in-flight hold_reason text"
  assert_contains "$out" "Other backlog items: tasks-axi list --file=$home/data/backlog.md" \
    "tasks-axi listing omitted the pointer to the other backlog items"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "tasks-axi compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "tasks-axi compact digest leaked a queued task body"
  assert_contains "$out" "--- compact-startup ---" "in-flight meta identity disappeared from startup recovery digest"
  assert_contains "$out" "worktree=$home/projects/firstmate" "in-flight recovery worktree identity disappeared from startup digest"
  assert_contains "$out" "Full task bodies remain available on demand: tasks-axi show <id> --full" \
    "compact digest omitted the full-body lookup pointer"
  assert_grep "list --file $home/data/backlog.md --limit 80 --fields hold_kind" "$log" \
    "session start did not ask tasks-axi for the bounded compact field set"
  assert_grep "list --file $home/data/backlog.md --state held --limit 1000000 --fields hold_kind" "$log" \
    "session start did not count captain-held items over every held item"

  out=$(FM_SESSION_START_BUDGET_BYTES=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "Captain-held items: 2 - list them with: $held_cmd" \
    "the reduced backlog did not give the exact captain-held count"
  assert_held_hint_lists_count "$out" "$fakebin:$BASE_PATH"

  out=$(FM_FAKE_TASKS_AXI_HELD_FAIL=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "$(printf 'tasks-axi compact listing failed; falling back to title-line rendering.\nHELD-LISTING-FAILED')" \
    "a failed captain-held count did not fall back to title-line rendering"
  assert_contains "$out" "$(printf 'Captain-held (1):\nheld-decision - Pick the library (Option A)\n')" \
    "the fallback after a failed captain-held count did not count the backlog file"

  pass "compatible tasks-axi backlog rendering is compact, bounded, counts captain-held items exactly, and preserves recovery metadata"
}

test_backlog_compact_manual_backend_skips_indented_bodies() {
  local rec root home fakebin out held_cmd
  rec=$(new_world backlog-compact-manual)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_long_body_backlog "$home/data/backlog.md"
  held_cmd="awk '/^##[[:space:]]/ { q = /^##[[:space:]]+Queued[[:space:]]*\$/; next } q && /^[-*][[:space:]]/ && index(\$0, \"(hold-kind: captain)\")' $home/data/backlog.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (manual backend; in-flight and captain-held items only; max 80 item(s) scanned; indented task bodies omitted)" \
    "manual backend did not use compact title-line rendering"
  assert_contains "$out" "$(printf 'In flight (1):\ncompact-startup - Compact startup digest\nCaptain-held (1):\nheld-decision - Pick the library (Option A)\n')" \
    "manual rendering did not list in-flight and captain-held items as id - title"
  assert_not_contains "$out" "blocked-followup" "manual rendering printed a queued item that is not captain-held"
  assert_not_contains "$out" "HOLD-REASON-TEXT" "manual rendering printed hold reason text"
  assert_not_contains "$out" "captain choice pending" "manual rendering printed in-flight hold reason text"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "manual compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "manual compact digest leaked a queued task body"
  assert_not_contains "$out" "(scanned " "manual rendering reported a scan bound it did not hit"
  assert_contains "$out" "Other backlog items: $home/data/backlog.md" \
    "manual rendering omitted the pointer to the other backlog items"
  assert_contains "$out" "or data/backlog.md" "manual compact digest omitted the data/backlog.md full-body pointer"

  out=$(FM_SESSION_START_BACKLOG_LIMIT=2 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "(scanned 2 of 3 backlog item(s); raise FM_SESSION_START_BACKLOG_LIMIT to scan more)" \
    "manual rendering did not report that its scan bound hid items"
  assert_not_contains "$out" "held-decision" "manual rendering listed an item past its scan bound"
  assert_contains "$out" "Captain-held (1 in the backlog; 0 of them within the scanned items listed below - list all with: $held_cmd):" \
    "manual rendering did not count captain-held items over the whole file"

  out=$(FM_SESSION_START_BUDGET_BYTES=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "Captain-held items: 1 - list them with: $held_cmd" \
    "the reduced manual backlog did not give the exact captain-held count"
  assert_held_hint_lists_count "$out" "$fakebin:$BASE_PATH"

  # Only bullets directly under a "## Queued" heading count, whatever trails it.
  printf '# Backlog\n\n## In flight\n- [ ] inflight-held - In flight (hold-kind: captain)\n\n## Queued  \n- [ ] queued-held - Queued (hold-kind: captain)\n  a body line (hold-kind: captain)\n- [ ] queued-external - Waits upstream (hold-kind: external)\n\n## Queued later\n- [ ] later-held - Under another heading (hold-kind: captain)\n' \
    > "$home/data/backlog.md"
  out=$(FM_SESSION_START_BUDGET_BYTES=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "Captain-held items: 1 - list them with: " "the manual count did not count only queued captain-held bullets"
  assert_held_hint_lists_count "$out" "$fakebin:$BASE_PATH"

  pass "manual backlog rendering lists only in-flight and captain-held items without hold reasons"
}

test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-unavailable)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi unavailable or incompatible; in-flight and captain-held items only; max 80 item(s) scanned; indented task bodies omitted)" \
    "unavailable tasks-axi did not fall back to compact title-line rendering"
  assert_contains "$out" "compact-startup - Compact startup digest" \
    "unavailable tasks-axi fallback omitted a backlog title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "unavailable tasks-axi fallback leaked an in-flight task body"

  pass "unavailable or incompatible tasks-axi falls back to compact manual backlog rendering"
}

# --- output budget ----------------------------------------------------------

# write_sized_file <path> <bytes> <marker>: exactly <bytes> bytes whose first
# and last lines carry <marker>, so a partial print is detectable.
write_sized_file() {
  local path=$1 bytes=$2 marker=$3 body
  body=$((bytes - ${#marker} * 2 - 14))
  {
    printf '%s-FIRST\n' "$marker"
    yes "$marker rule text padding the fixture to its measured size." | head -c "$body"
    printf '\n%s-LAST\n' "$marker"
  } > "$path"
}

first_nonempty_line() { printf '%s\n' "$1" | grep -m1 -v '^$'; }
next_step_section() { printf '%s\n' "$1" | awk '/^NEXT STEP$/ { found = 1 } found'; }

# assert_never_cut_lines <out> <harness> <home> <root>: what LOCK, BOOTSTRAP,
# WAKE QUEUE and the supervision block print survives any budget decision.
assert_never_cut_lines() {
  local out=$1 harness=$2 home=$3 root=$4
  assert_contains "$out" "lock acquired: harness pid" "budget cut the LOCK output"
  assert_contains "$out" "MISSING: node (install:" "budget cut the BOOTSTRAP diagnostic"
  assert_contains "$out" "$(printf 'signal\ttask-wake\tdone: never-cut wake record')" "budget cut a drained wake record"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: $harness" "budget cut the supervision block"
  assert_contains "$out" "$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness" --read-only 0 --afk 0 --x-mode 0)" \
    "budget shortened the supervision block"
}

test_budget_defers_rule_files_that_do_not_fit() {
  local rec root home fakebin out first next printed bytes
  rec=$(new_world budget-stop)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  rm -f "$fakebin/node"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_sized_file "$home/data/captain.md" 50000 CAPTAIN_BIG
  write_sized_file "$home/data/learnings.md" 3000 LEARNINGS_FIT
  write_sized_file "$home/data/secondmates.md" 60000 SECONDMATES_BIG
  write_sized_file "$home/data/projects.md" 2000 PROJECTS_FIT
  append_wake "$home/state" signal task-wake "done: never-cut wake record" || fail "seed wake failed"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  first=$(first_nonempty_line "$out")
  case "$first" in STOP:*) ;; *) fail "digest did not begin with a STOP line: $first" ;; esac
  assert_contains "$out" "STOP: rule file not printed - read $home/data/captain.md in full with your file-read tool before any other action (50000 bytes)" \
    "oversized captain.md was not named on a STOP line"
  assert_contains "$out" "STOP: rule file not printed - read $home/data/secondmates.md in full with your file-read tool before any other action (60000 bytes)" \
    "oversized secondmates.md was not named on a STOP line"
  assert_not_contains "$out" "CAPTAIN_BIG" "a deferred captain.md was partially printed"
  assert_not_contains "$out" "SECONDMATES_BIG" "a deferred secondmates.md was partially printed"
  assert_contains "$out" "$(cat "$home/data/learnings.md")" "a later rule file that fits was not printed in full"
  assert_contains "$out" "$(cat "$home/data/projects.md")" "projects.md that fits was not printed in full"
  assert_not_contains "$out" "STOP: rule file not printed - read $home/data/learnings.md" "a printed rule file was also named on a STOP line"
  assert_never_cut_lines "$out" claude "$home" "$root"
  bytes=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH" | LC_ALL=C wc -c | tr -d ' ')
  [ "$bytes" -le 46080 ] || fail "digest with deferred rule files is $bytes bytes, over the 46080-byte budget"

  next=$(next_step_section "$out")
  assert_contains "$next" "$home/data/captain.md - read it first" "NEXT STEP did not send the reader to deferred captain.md first"
  assert_contains "$next" "$home/data/secondmates.md - read it first" "NEXT STEP did not send the reader to deferred secondmates.md first"
  assert_not_contains "$next" "The digest above is complete" "NEXT STEP called a digest with deferred rule files complete"
  printed=$(printf '%s\n' "$next" | grep '^Printed in full above')
  assert_contains "$printed" "data/learnings.md" "NEXT STEP omitted a printed rule file"
  assert_not_contains "$printed" "data/captain.md" "NEXT STEP told the reader to skip deferred captain.md"
  assert_not_contains "$printed" "data/secondmates.md" "NEXT STEP told the reader to skip deferred secondmates.md"

  pass "rule files that do not fit are named on leading STOP lines and never partially printed"
}

test_budget_setting_override_and_validation() {
  local rec root home fakebin out
  rec=$(new_world budget-setting)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_sized_file "$home/data/captain.md" 20000 CAPTAIN_MID

  out=$(FM_SESSION_START_BUDGET_BYTES=10000 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "STOP: rule file not printed - read $home/data/captain.md" "FM_SESSION_START_BUDGET_BYTES did not lower the budget"
  assert_not_contains "$out" "CAPTAIN_MID" "a lowered budget still printed captain.md"

  out=$(FM_SESSION_START_BUDGET_BYTES=not-a-number run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "$(cat "$home/data/captain.md")" "an invalid budget did not fall back to the default"
  assert_not_contains "$out" "STOP:" "an invalid budget deferred a rule file that fits the default"

  out=$(FM_SESSION_START_BUDGET_BYTES=0 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "$(cat "$home/data/captain.md")" "a zero budget did not fall back to the default"
  assert_not_contains "$out" "STOP:" "a zero budget deferred a rule file that fits the default"

  pass "FM_SESSION_START_BUDGET_BYTES overrides the budget and invalid values fall back to the default"
}

test_budget_counts_bytes_not_characters() {
  local rec root home fakebin out bytes wide
  rec=$(new_world budget-bytes)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  # 3000 three-byte characters: 9000 bytes, but only 3000 characters, so a
  # character count would let the 33000-byte captain.md through.
  wide=$(awk 'BEGIN { for (i = 0; i < 3000; i++) printf "\342\224\201" }')
  append_wake "$home/state" signal task-wide "done: $wide" || fail "seed wake failed"
  write_sized_file "$home/data/captain.md" 33000 CAPTAIN_WIDE

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "STOP: rule file not printed - read $home/data/captain.md" \
    "the budget counted characters instead of bytes"
  assert_contains "$out" "$wide" "budget cut a multibyte wake record"
  bytes=$(printf '%s\n' "$out" | LC_ALL=C wc -c | tr -d ' ')
  [ "$bytes" -le 46080 ] || fail "multibyte digest is $bytes bytes, over the 46080-byte budget"

  pass "the budget counts bytes, so multibyte never-cut output cannot push the digest over it"
}

test_budget_stop_line_path_is_absolute_for_relative_home() {
  local rec root home fakebin out
  rec=$(new_world budget-relative-home)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_sized_file "$home/data/captain.md" 50000 CAPTAIN_RELATIVE

  out=$(cd "${home%/home}" && run_session_start home "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "STOP: rule file not printed - read $home/data/captain.md" \
    "a relative FM_HOME produced a STOP line without an absolute path"

  pass "STOP lines name absolute paths even when FM_HOME is relative"
}

test_budget_claims_only_shortenings_that_change_something() {
  local rec root home fakebin out n
  rec=$(new_world budget-no-op-steps)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf 'window=fm-sess:w1\nkind=ship\n' > "$home/state/task-a.meta"
  printf 'working: only line\n' > "$home/state/task-a.status"

  # A 1-byte budget forces every shortening step; none of them changes this fleet.
  out=$(FM_SESSION_START_BUDGET_BYTES=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_not_contains "$out" "FLEET_TRUNCATED" "a shortening step that changed nothing was claimed"
  assert_contains "$out" "$(printf -- '--- task-a ---\nwindow=fm-sess:w1\nkind=ship\nendpoint:')" "an unshortened meta lost its lines"
  assert_contains "$(printf '%s\n' "$out" | grep '^Printed in full above')" "state/*.meta" \
    "NEXT STEP did not name metas printed in full"

  printf 'harness=claude\nworktree=/tmp/example\n' >> "$home/state/task-a.meta"
  n=1
  while [ "$n" -le 4 ]; do printf 'working: step %s\n' "$n"; n=$((n + 1)); done >> "$home/state/task-a.status"
  write_long_body_backlog "$home/data/backlog.md"
  out=$(FM_SESSION_START_BUDGET_BYTES=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "FLEET_TRUNCATED: per-task status tails cut to 1 line" "the status-tail shortening was not claimed"
  assert_contains "$out" "FLEET_TRUNCATED: state/*.meta bodies reduced" "the meta shortening was not claimed"
  assert_contains "$out" "FLEET_TRUNCATED: backlog reduced" "the backlog shortening was not claimed"
  assert_not_contains "$out" "worktree=/tmp/example" "the meta shortening kept a line outside window, kind, harness, model, mode and pr"

  pass "FLEET_TRUNCATED names only shortening steps that actually changed the digest"
}

# write_real_size_backlog <path>: 9 in-flight, 60 captain-held and 10 other
# queued items with real-length hold reasons, plus one done item.
write_real_size_backlog() {
  local path=$1 n reason
  reason='The export matches the later list through the cut-off and then carries only a fraction of the orders, so the captain must choose between re-pulling the tail, moving the cut-off, or warning in the app; options are not exclusive.'
  {
    printf '# Backlog\n\n## In flight\n'
    n=1
    while [ "$n" -le 9 ]; do
      printf -- '- [ ] inflight-task-%02d - In-flight task %02d keeps its title visible at session start (repo: firstmate) (kind: ship) (since 2026-10-28)\n' "$n" "$n"
      printf '  INFLIGHT-BODY-LINE %02d\n' "$n"
      n=$((n + 1))
    done
    printf '\n## Queued\n'
    n=1
    while [ "$n" -le 60 ]; do
      printf -- '- [ ] captain-held-decision-%02d - Captain decision %02d on how the import handles trailing rows (repo: racingr-wms) (kind: captain) (since 2026-08-03) (hold: %s) (hold-kind: captain)\n' "$n" "$n" "$reason"
      n=$((n + 1))
    done
    n=1
    while [ "$n" -le 10 ]; do
      printf -- '- [ ] other-queued-%02d - Other queued work %02d (repo: firstmate) (kind: ship) (since 2026-10-01)\n' "$n" "$n"
      n=$((n + 1))
    done
    printf '\n## Done\n- [x] finished-task - Finished task (repo: firstmate) (kind: ship) (since 2026-09-01)\n'
  } > "$path"
}

# write_real_size_worker <state> <n>: a ~800-byte meta and six long status lines.
write_real_size_worker() {
  local state=$1 n=$2 id k
  id=$(printf 'worker-task-%02d' "$n")
  {
    printf 'window=firstmate:fm-%s\nkind=ship\nharness=claude\nmodel=claude-opus-5-5\nmode=no-mistakes\n' "$id"
    printf 'pr=https://github.com/example/firstmate/pull/%s\n' "$((100 + n))"
    printf 'worktree=/Users/example/.treehouse/ai-workspace-cdc954/%s/ai-workspace\n' "$n"
    printf 'project=ai-workspace\nbranch=fm/%s\nbackend=tmux\nyolo=off\n' "$id"
    k=1
    while [ "$k" -le 7 ]; do
      printf 'context_%s=recorded spawn context line kept for recovery and teardown of this task\n' "$k"
      k=$((k + 1))
    done
  } > "$state/$id.meta"
  k=1
  while [ "$k" -le 6 ]; do
    printf 'working: step %s of %s - long status line describing what the worker just finished, what it verified, and what it will do next before reporting\n' "$k" "$id"
    k=$((k + 1))
  done > "$state/$id.status"
}

test_budget_real_size_fixture_prints_every_rule_file() {
  local rec root home fakebin out bytes n next printed TMP_ROOT
  # Every printed path costs bytes, so this world sits under a short root
  # close to a real home's path length instead of the long platform TMPDIR.
  TMP_ROOT=$(TMPDIR=/tmp fm_test_tmproot fmss)
  FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
  rec=$(new_world budget-real-size)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_quota_axi "$fakebin"
  fm_fake_exit0 "$fakebin" dispatch-axi
  make_fake_ps_harness "$fakebin" omp
  rm -f "$fakebin/node"
  printf '%s\n' manual > "$home/config/backlog-backend"
  # Sizes measured on 2026-10-28 (1 KB = 1000 bytes, matching the measured files).
  write_sized_file "$home/data/captain.md" 15500 CAPTAIN_REAL
  write_sized_file "$home/data/learnings.md" 5600 LEARNINGS_REAL
  write_sized_file "$home/CLAUDE.local.md" 6600 LOCAL_REAL
  write_sized_file "$home/data/projects.md" 6400 PROJECTS_REAL
  write_real_size_backlog "$home/data/backlog.md"
  n=1
  while [ "$n" -le 7 ]; do
    write_real_size_worker "$home/state" "$n"
    n=$((n + 1))
  done
  append_wake "$home/state" signal task-wake "done: never-cut wake record" || fail "seed wake failed"

  out=$(HERDR_ENV='' FM_FAKE_HARNESS=omp run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  bytes=$(HERDR_ENV='' FM_FAKE_HARNESS=omp run_session_start "$home" "$root" "$fakebin:$BASE_PATH" | LC_ALL=C wc -c | tr -d ' ')

  # Byte arithmetic for this fixture (measured 2026-10-28, re-check when the
  # supervision block, the rule files or the shortened forms grow):
  #   LOCK + BOOTSTRAP + WAKE QUEUE + extension diagnostic   1752
  #   omp supervision block                                  3748
  #   CONTEXT preamble, absent-file markers                   725
  #   captain.md 15500 + learnings.md 5600 + CLAUDE.local.md
  #   6600 + projects.md 6400, each with its label          34455
  #   FLEET STATE after all of (b), (c) and (d)               4205
  #   NEXT STEP                                                864
  #   total                                                 45749 of 46080
  # Level (c) alone leaves the 69-item backlog listing (~7 KB) in place, so
  # (d) is what makes room; only ~330 bytes stay spare. Ambient bootstrap and
  # guard output varies by machine; another environment measured about 800
  # bytes less.
  [ "$bytes" -le 46080 ] || fail "real-size digest is $bytes bytes, over the 46080-byte budget"
  assert_not_contains "$out" "STOP:" "a real-size rule file was deferred"
  assert_contains "$out" "$(cat "$home/data/captain.md")" "real-size captain.md was not printed in full"
  assert_contains "$out" "$(cat "$home/data/learnings.md")" "real-size learnings.md was not printed in full"
  assert_contains "$out" "$(cat "$home/CLAUDE.local.md")" "real-size CLAUDE.local.md was not printed in full"
  assert_contains "$out" "$(cat "$home/data/projects.md")" "real-size projects.md was not printed in full"
  assert_contains "$out" "OMP_EXTENSION: not loaded" "budget cut the extension diagnostic"
  assert_never_cut_lines "$out" omp "$home" "$root"
  assert_contains "$out" "FLEET_TRUNCATED: per-task status tails cut to 1 line - see $home/state/<id>.status" \
    "real-size digest did not name the status-tail shortening"
  assert_contains "$out" "FLEET_TRUNCATED: state/*.meta bodies reduced to window, kind, harness, model, mode, pr lines - see $home/state/<id>.meta" \
    "real-size digest did not name the meta shortening"
  assert_contains "$out" "FLEET_TRUNCATED: backlog reduced to in-flight ids and a captain-held count - see tasks-axi list --file=$home/data/backlog.md" \
    "real-size digest did not name the backlog shortening"
  assert_not_contains "$out" "FLEET_TRUNCATED: orphan" "real-size digest claimed an orphan shortening with no orphans"
  assert_contains "$out" "$(printf 'inflight-task-09\nCaptain-held items: 60 - list them with: %s %s' "awk '/^##[[:space:]]/ { q = /^##[[:space:]]+Queued[[:space:]]*\$/; next } q && /^[-*][[:space:]]/ && index(\$0, \"(hold-kind: captain)\")'" "$home/data/backlog.md")" \
    "reduced backlog did not keep in-flight ids and the captain-held count"
  assert_contains "$out" "$(printf -- '--- worker-task-07 ---\nwindow=firstmate:fm-worker-task-07\nkind=ship\nharness=claude\nmodel=claude-opus-5-5\nmode=no-mistakes\npr=https://github.com/example/firstmate/pull/107\nendpoint: alive (backend=tmux)\nlast status line')" \
    "reduced meta did not keep exactly the window, kind, harness, model, mode and pr lines"

  next=$(next_step_section "$out")
  printed=$(printf '%s\n' "$next" | grep '^Printed in full above')
  assert_contains "$printed" "data/captain.md" "NEXT STEP omitted printed captain.md"
  assert_contains "$printed" "$home/CLAUDE.local.md" "NEXT STEP omitted printed CLAUDE.local.md"
  assert_not_contains "$printed" "state/*.meta" "NEXT STEP claimed shortened metas were printed in full"
  assert_contains "$next" "The digest above is complete for this session start." "NEXT STEP did not confirm a complete digest"

  pass "real-size rule files all print in full under the budget while fleet state shortens with FLEET_TRUNCATED lines"
}

# --- fleet-state digest: no in-flight tasks ----------------------------------

test_fleet_digest_empty_fleet() {
  local rec root home fakebin out
  rec=$(new_world empty-fleet)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "(none)" "empty fleet did not report (none) for in-flight tasks"
  assert_contains "$out" "absent" "empty fleet's AFK section did not report absent"
  assert_not_contains "$out" "state/*.meta." "NEXT STEP named metas as printed when there were none"

  pass "an empty fleet reports (none) for in-flight tasks and an absent AFK flag"
}

test_next_step_sources_x_mode_cadence() {
  local rec root home fakebin out
  rec=$(new_world next-step-x)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_fake_exit0 "$fakebin" curl jq
  printf 'FMX_PAIRING_TOKEN=tok-next-step\n' > "$home/.env"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "FMX: X mode on" "bootstrap did not activate X mode"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude" "supervision block missing"
  assert_contains "$out" "- X mode: active" "supervision block did not mention X cadence"
  assert_contains "$out" "Follow the supervision operating instructions block above" "next step did not point back to the emitted supervision block"

  pass "session start emits X-mode cadence guidance in the harness supervision block"
}

test_next_step_afk_delegates_to_daemon() {
  local rec root home fakebin out
  rec=$(new_world next-step-afk)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  : > "$home/state/.afk"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "away-mode supervision is active" "AFK digest did not report away mode"
  assert_contains "$out" "Away mode is active" "next step did not switch to AFK guidance"
  assert_contains "$out" "daemon owns the watcher" "next step did not delegate watcher ownership to the daemon"
  assert_contains "$out" "- Away mode: active" "supervision block did not include active AFK state"
  assert_not_contains "$out" "  bin/fm-watch-arm.sh" "AFK next step still told the agent to arm the watcher directly"

  pass "next step delegates watcher ownership to the AFK daemon"
}

test_supervision_block_exactly_one_and_pi_diagnostic() {
  local rec root home fakebin out block_count wake_line sup_line context_line
  rec=$(new_world pi-supervision-block)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  block_count=$(printf '%s\n' "$out" | grep -c '^SUPERVISION OPERATING INSTRUCTIONS - primary harness:')
  [ "$block_count" -eq 1 ] || fail "expected exactly one supervision block, got $block_count"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi" "pi supervision block missing"
  assert_contains "$out" "Mode: Pi extension background wake." "pi snippet missing from session start"
  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi extension load diagnostic missing"
  assert_contains "$out" "restart plain pi so $root/.pi/extensions/fm-primary-turnend-guard.ts and $root/.pi/extensions/fm-primary-pi-watch.ts auto-load" "pi extension load diagnostic omits the turn-end guard extension"

  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  sup_line=$(printf '%s\n' "$out" | grep -n '^SUPERVISION OPERATING INSTRUCTIONS' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  [ "$wake_line" -lt "$sup_line" ] || fail "supervision block did not follow wake queue"
  [ "$sup_line" -lt "$context_line" ] || fail "supervision block did not precede context"

  pass "session start emits exactly one detected harness block and reports Pi extension load state"
}

test_pi_signed_primary_uses_pi_extensions_without_identity_normalization() {
  local rec root home fakebin out
  rec=$(new_world pi-signed-supervision-block)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi-signed

  out=$(FM_FAKE_HARNESS=pi-signed run_session_start "$home" "$root" "$fakebin:$BASE_PATH" pi-signed)

  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi-signed" \
    "session start normalized a pi-signed primary to pi"
  assert_contains "$out" "Mode: Pi extension background wake." \
    "pi-signed primary did not reuse Pi's supervision protocol"
  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" \
    "pi-signed primary skipped Pi extension validation"
  assert_contains "$out" "restart pi-signed so $root/.pi/extensions/fm-primary-turnend-guard.ts and $root/.pi/extensions/fm-primary-pi-watch.ts auto-load" \
    "pi-signed extension diagnostic did not preserve the executable identity"

  pass "session start preserves pi-signed primary identity while applying Pi extension guarantees"
}

test_pi_diagnostic_rejects_stale_loaded_marker() {
  local rec root home fakebin out marker holder_pid
  rec=$(new_world pi-stale-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  printf 'stale-extension-version\n%s\n' "$holder_pid" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"
  touch -t 203001010000 "$marker" 2>/dev/null || touch "$marker"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a stale loaded marker"

  pass "session start rejects stale Pi loaded markers"
}

test_pi_diagnostic_accepts_prelock_loaded_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-prelock-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_loaded_markers "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_not_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic rejected a current pre-lock loaded marker"

  pass "session start accepts current Pi markers written before lock acquisition"
}

test_pi_diagnostic_rejects_missing_turnend_guard_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-missing-turnend-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_watch_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a session without the turn-end guard extension"

  pass "session start rejects Pi sessions missing the turn-end guard marker"
}

test_pi_diagnostic_rejects_previous_session_loaded_marker() {
  local rec root home fakebin out marker version holder_pid
  rec=$(new_world pi-previous-session-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n999999\n' "$version" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a marker from a previous Pi process"

  pass "session start rejects Pi loaded markers from previous sessions"
}

test_omp_extension_marker_survives_fresh_home_without_state() {
  local rec root home fakebin out ext ready holder_pid i
  rec=$(new_world omp-fresh-home)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  # A fresh clone: omp's session_start fires before bin/fm-lock.sh creates state/.
  rm -rf "$home/state"
  ext="$root/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$root/.omp/extensions"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$ext"
  ready="$TMP_ROOT/omp-fresh-home.ready"
  # The real extension runs its main-agent session_start in a live process that
  # then stays up as the omp session holding the lock.
  PLUGIN="$ext" READY="$ready" FM_HOME="$home" node --input-type=module >/dev/null 2>&1 <<'EOF' &
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, { agent: { kind: "main" } });
writeFileSync(process.env.READY, "ready\n");
setTimeout(() => {}, 300000);
EOF
  holder_pid=$!
  i=0
  while [ ! -s "$ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$ready" ] || { kill "$holder_pid" 2>/dev/null; fail "the omp extension never finished session_start"; }
  make_fake_ps_pi_holder "$fakebin" "$holder_pid" omp

  out=$(OMPCODE=1 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: omp" "session start did not run as an omp primary"
  [ "$(sed -n '1p' "$home/state/.lock" 2>/dev/null)" = "$holder_pid" ] \
    || fail "the omp session did not take the lock, so the marker check proves nothing"
  assert_not_contains "$out" "OMP_EXTENSION: not loaded" \
    "a fresh home falsely reported the loaded omp extension as missing"

  pass "session start accepts the omp extension marker written before a fresh home had state/"
}

test_local_rules_in_detected_primary_digest() {
  local rec root fixture_home fakebin harness out rc
  rec=$(new_world local-rules)
  IFS='|' read -r root fixture_home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  printf '%s\n' manual > "$fixture_home/config/backlog-backend"
  printf '%s\n' 'LOCAL_RULE_FIRST: preserve captain instructions.' \
    'LOCAL_RULE_LAST: never commit this file.' > "$fixture_home/CLAUDE.local.md"
  for harness in omp codex opencode pi pi-signed grok kimi claude; do
    make_fake_ps_harness "$fakebin" "$harness"
    rc=0
    if [ "$harness" = pi-signed ]; then
      out=$(FM_FAKE_HARNESS="$harness" run_session_start "$fixture_home" "$root" "$fakebin:$BASE_PATH" pi-signed) || rc=$?
    else
      out=$(FM_FAKE_HARNESS="$harness" run_session_start "$fixture_home" "$root" "$fakebin:$BASE_PATH") || rc=$?
    fi
    expect_code 0 "$rc" "$harness local-rules digest"
    assert_contains "$out" "for harness '$harness'" "test did not detect $harness"
    if [ "$harness" = claude ]; then
      assert_not_contains "$out" 'LOCAL_RULE_FIRST' 'Claude duplicated natively loaded rules'
      assert_not_contains "$(printf '%s\n' "$out" | grep '^Printed in full above')" 'CLAUDE.local.md' \
        'Claude was told its unprinted local rules were printed in full'
    else
      assert_contains "$out" "$(cat "$fixture_home/CLAUDE.local.md")" "$harness omitted full local rules"
      assert_not_contains "$out" "$root/CLAUDE.local.md" 'digest used code root instead of active home'
    fi
  done
  pass 'session start supplies full home-local rules to every non-Claude primary'
}

test_local_rules_absent_and_unreadable_digest() {
  local rec root fixture_home fakebin out rc shape
  rec=$(new_world local-rules-errors)
  IFS='|' read -r root fixture_home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" omp
  out=$(FM_FAKE_HARNESS=omp run_session_start "$fixture_home" "$root" "$fakebin:$BASE_PATH")
  assert_not_contains "$out" 'CLAUDE.local.md' 'absent local rules printed noise'
  for shape in directory dangling permission fifo; do
    case "$shape" in
      directory) mkdir "$fixture_home/CLAUDE.local.md" ;;
      dangling) ln -s "$fixture_home/missing-rules" "$fixture_home/CLAUDE.local.md" ;;
      fifo) mkfifo "$fixture_home/CLAUDE.local.md" ;;
      permission)
        printf 'SECRET_LOCAL_RULE\n' > "$fixture_home/CLAUDE.local.md"
        chmod 000 "$fixture_home/CLAUDE.local.md"
        [ ! -r "$fixture_home/CLAUDE.local.md" ] || fail 'unreadable fixture is readable'
        ;;
    esac
    rc=0
    [ "$shape" != fifo ] || fm_fifo_feed "$fixture_home/CLAUDE.local.md" 'SECRET_LOCAL_RULE'
    out=$(FM_FAKE_HARNESS=omp run_session_start "$fixture_home" "$root" "$fakebin:$BASE_PATH") || rc=$?
    [ "$shape" != fifo ] || fm_fifo_release "$fixture_home/CLAUDE.local.md"
    expect_code 0 "$rc" "unreadable $shape local rules must not abort startup"
    [ "$(printf '%s\n' "$out" | grep -c 'CLAUDE_LOCAL: unreadable')" = 1 ] \
      || fail "$shape rules need one diagnostic"
    assert_contains "$out" "$fixture_home/CLAUDE.local.md" 'diagnostic omitted local rule path'
    assert_contains "$out" 'NEXT STEP' 'unreadable rules stopped digest'
    assert_not_contains "$out" 'SECRET_LOCAL_RULE' 'unreadable rules leaked into digest'
    if [ "$shape" = directory ]; then
      rmdir "$fixture_home/CLAUDE.local.md"
    else
      chmod 600 "$fixture_home/CLAUDE.local.md" 2>/dev/null || true
      rm -f "${fixture_home:?}/CLAUDE.local.md"
    fi
  done
  pass 'absent local rules are silent and unreadable rules diagnose without aborting'
}

test_local_rules_in_detected_primary_digest
test_local_rules_absent_and_unreadable_digest
test_context_digest_absent_empty_present
test_omp_extension_marker_survives_fresh_home_without_state
test_lock_refusal_read_only_path
test_lock_write_failure_read_only_path
test_trace_context_effective_state_is_frozen_after_lock
test_session_lock_concurrent_single_winner
test_output_ordering_diagnostics_lead
test_herdr_backend_diagnostics_follow_real_session_start
test_session_start_relaunches_missing_pi_secondmate
test_session_start_preserves_ambiguous_pi_process
test_session_start_preserves_transiently_unreadable_tmux
test_session_start_preserves_proven_bare_shell_recovery
test_session_start_relaunches_herdr_husk_secondmate
test_status_tail_bounding
test_orphan_status_logs_are_printed
test_endpoint_liveness_tmux
test_endpoint_liveness_herdr
test_pr_registered_by_drain_is_in_printed_meta
test_composition_invokes_real_scripts
test_killed_liveness_probe_leaves_wakes_queued
test_interrupted_drain_prints_drained_wakes
test_interrupted_bootstrap_prints_only_finished_steps
test_signal_during_final_print_does_not_cut_the_digest
test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata
test_backlog_compact_manual_backend_skips_indented_bodies
test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback
test_budget_defers_rule_files_that_do_not_fit
test_budget_setting_override_and_validation
test_budget_counts_bytes_not_characters
test_budget_stop_line_path_is_absolute_for_relative_home
test_budget_claims_only_shortenings_that_change_something
test_budget_real_size_fixture_prints_every_rule_file
test_fleet_digest_empty_fleet
test_next_step_sources_x_mode_cadence
test_next_step_afk_delegates_to_daemon
test_supervision_block_exactly_one_and_pi_diagnostic
test_pi_signed_primary_uses_pi_extensions_without_identity_normalization
test_pi_diagnostic_rejects_stale_loaded_marker
test_pi_diagnostic_accepts_prelock_loaded_marker
test_pi_diagnostic_rejects_missing_turnend_guard_marker
test_pi_diagnostic_rejects_previous_session_loaded_marker

echo "# fm-session-start.test.sh: all assertions passed"

test_new_session_clears_captain_hold() {
  local rec root home fakebin out
  rec=$(new_world captain-hold-start)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf 'context reminder - timestamp\n' > "$home/state/.captain-hold"
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH" 2>&1)
  [ ! -e "$home/state/.captain-hold" ] || fail 'new owned session did not clear hold'
  pass 'session start: clears captain hold after lock acquisition'
}
test_new_session_clears_captain_hold
