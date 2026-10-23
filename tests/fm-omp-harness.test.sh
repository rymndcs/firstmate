#!/usr/bin/env bash
# Behavior tests for detecting omp as firstmate's own primary harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Fake ps whose ancestry is: this script -> bash -> <FM_TEST_PARENT> (pid 4343).
make_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid= prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4343) printf '%s\n' "${FM_TEST_PARENT:?}" ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4343) printf '1\n' ;;
  ppid=:*) printf '4343\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_omp_marker_outranks_claude_marker() {
  local fakebin cfg out
  fakebin=$(fm_fakebin "$TMP_ROOT/marker")
  cfg="$TMP_ROOT/marker/config"
  mkdir -p "$cfg"
  make_ps "$fakebin"
  # omp exports both markers into every bash-tool command.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT OMPCODE=1 CLAUDECODE=1 FM_TEST_PARENT=/bin/zsh \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "omp's marker pair resolved '$out', expected omp"
  out=$(env -u OMPCODE -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 FM_TEST_PARENT=/bin/zsh \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "Claude's own marker resolved '$out', expected claude"
  pass "fm-harness: omp's OMPCODE marker wins over the CLAUDECODE it also exports"
}

test_markerless_omp_is_detected_by_exact_ancestry_name() {
  local fakebin cfg out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry")
  cfg="$TMP_ROOT/ancestry/config"
  mkdir -p "$cfg"
  make_ps "$fakebin"
  # Extension-launched owner scripts inherit omp's process env, not its
  # bash-tool env, so they reach detection without any marker.
  out=$(env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT FM_TEST_PARENT=omp \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "markerless omp parent resolved '$out', expected omp"
  out=$(env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT FM_TEST_PARENT=/usr/local/bin/omptool \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "a process merely named like omp resolved '$out', expected unknown"
  pass "fm-harness: markerless omp ancestry matches only the exact omp name"
}

# --- launch-boundary marker leaks (real tmux on a dedicated socket) ----------

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LEAK_SOCKET="fm-omp-harness-$$"
cleanup_leak_server() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$LEAK_SOCKET" kill-server >/dev/null 2>&1
  fm_test_cleanup
}
trap cleanup_leak_server EXIT
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")

# A world where every bare `tmux` reaches the dedicated socket, pane shells start
# without startup files, `treehouse get` enters the prepared worktree, and a
# stand-in `claude` reports what bin/fm-harness.sh resolves inside it. Claude
# exports CLAUDECODE=1 to the commands it runs, so the stand-in does the same.
make_leak_world() {  # <name> <id> -> prints the world dir
  local name=$1 id=$2 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/data/$id" "$w/home/projects" "$w/home/state" "$w/home/config"
  printf 'claude\n' > "$w/home/config/crew-harness"
  printf 'tmux\n' > "$w/home/config/backend"
  printf 'brief for %s\n' "$id" > "$w/home/data/$id/brief.md"
  touch "$w/home/state/.last-watcher-beat"
  fm_git_worktree "$w/project" "$w/wt" "wt-$name"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$LEAK_SOCKET" "\$@"
SH
  cat > "$fakebin/pane-shell" <<'SH'
#!/usr/bin/env bash
exec bash --noprofile --norc "$@"
SH
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = get ] || exit 0
cd "$w/wt" && exec bash --noprofile --norc
SH
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\${OMPCODE-unset}" "\${CLAUDECODE-unset}" > "$w/inherited"
CLAUDECODE=1 "$ROOT/bin/fm-harness.sh" > "$w/detected.tmp" && mv "$w/detected.tmp" "$w/detected"
SH
  chmod +x "$fakebin/tmux" "$fakebin/pane-shell" "$fakebin/treehouse" "$fakebin/claude"
  printf '%s\n' "$w"
}

# Run the real fm-spawn.sh the way an omp primary's bash tool does: with both of
# the markers omp exports to every command it runs.
spawn_from_omp() {  # <world> <id> [env...]
  local w=$1 id=$2
  shift 2
  env -u TMUX -u HERDR_ENV -u CLAUDE_CONFIG_DIR "$@" OMPCODE=1 CLAUDECODE=1 SHELL="$w/fakebin/pane-shell" \
    PATH="$w/fakebin:$BASE_PATH" FM_ROOT_OVERRIDE='' FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$w/project" --mode local-only --yolo off --captain-pick claude 2>&1
}

wait_for_file() {  # <file>
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$1" ]
}

test_server_started_from_omp_keeps_its_markers_out() {
  local w id=omp-leak-server-z1 out
  [ -n "$REAL_TMUX" ] || { echo "skip: tmux not found"; return 0; }
  "$REAL_TMUX" -L "$LEAK_SOCKET" kill-server >/dev/null 2>&1
  w=$(make_leak_world leak-server "$id")
  out=$(spawn_from_omp "$w" "$id") || fail "spawn from an omp primary failed: $out"
  "$REAL_TMUX" -L "$LEAK_SOCKET" has-session -t firstmate 2>/dev/null \
    || fail "spawn did not start its own firstmate session on the dedicated server"
  # A later session the captain opens in that server inherits its global env.
  "$REAL_TMUX" -L "$LEAK_SOCKET" new-window -d -t firstmate: -n later \
    "CLAUDECODE=1 '$ROOT/bin/fm-harness.sh' > '$w/later.tmp' && mv '$w/later.tmp' '$w/later'; sleep 30"
  wait_for_file "$w/later" || fail "the later window never reported its harness"
  [ "$(cat "$w/later")" = claude ] \
    || fail "a Claude session opened later in a server started from omp resolved '$(cat "$w/later")'"
  # A markerless harness (codex, opencode, kimi) opened there must not read as Claude either.
  "$REAL_TMUX" -L "$LEAK_SOCKET" new-window -d -t firstmate: -n markerless \
    "'$ROOT/bin/fm-harness.sh' > '$w/markerless.tmp' && mv '$w/markerless.tmp' '$w/markerless'; sleep 30"
  wait_for_file "$w/markerless" || fail "the markerless window never reported its harness"
  case "$(cat "$w/markerless")" in
    claude|omp) fail "a markerless session in a server started from omp resolved '$(cat "$w/markerless")'" ;;
  esac
  pass "fm-spawn: a tmux server started from an omp primary does not hand omp's markers to later sessions"
}

test_spawned_claude_ignores_omp_markers_in_its_server() {
  local w id=omp-leak-pane-z1 out
  [ -n "$REAL_TMUX" ] || { echo "skip: tmux not found"; return 0; }
  "$REAL_TMUX" -L "$LEAK_SOCKET" kill-server >/dev/null 2>&1
  w=$(make_leak_world leak-pane "$id")
  # A server that already carries omp's markers, as one started from an omp
  # terminal does; firstmate must not rewrite the captain's server.
  env OMPCODE=1 CLAUDECODE=1 SHELL="$w/fakebin/pane-shell" PATH="$w/fakebin:$BASE_PATH" \
    "$REAL_TMUX" -L "$LEAK_SOCKET" new-session -d -s captain -x 200 -y 50
  [ "$("$REAL_TMUX" -L "$LEAK_SOCKET" show-environment -g OMPCODE 2>/dev/null)" = OMPCODE=1 ] \
    || fail "the fixture server does not carry omp's marker, so the leak is not exercised"
  out=$(spawn_from_omp "$w" "$id" TMUX="/tmp/fm-omp-harness-fake,1,0") \
    || fail "spawn from an omp primary failed: $out"
  wait_for_file "$w/detected" || fail "the spawned claude never reported its harness"
  [ "$(cat "$w/detected")" = claude ] \
    || fail "a Claude worker launched from an omp primary resolved '$(cat "$w/detected")'"
  [ "$(cat "$w/inherited")" = "unset unset" ] \
    || fail "the launched worker inherited omp's markers (OMPCODE CLAUDECODE: $(cat "$w/inherited"))"
  [ "$("$REAL_TMUX" -L "$LEAK_SOCKET" show-environment -g OMPCODE 2>/dev/null)" = OMPCODE=1 ] \
    || fail "spawn rewrote the existing server's global environment"
  pass "fm-spawn: a Claude worker resolves claude even when its server carries omp's markers"
}

# --- away-mode injection into an omp primary (real tmux pane) ---------------

# A pane that draws omp's composer the way omp 18.12.6 renders it: the status
# line on the top border, the draft on the bottom border row, the cursor at the
# draft's end, and a Working… turn while "$dir/busy" exists. The idle frame keeps
# the status line's async-job counter running, as it does for the whole away
# stretch while the away daemon runs as an omp async job. Enter logs the
# submitted line and clears the draft; Ctrl-U clears it unsubmitted.
write_omp_shaped_pane() {  # <dir>
  cat > "$1/omp-pane.sh" <<'LOOP'
#!/usr/bin/env bash
dir=$1
stty -echo -icanon min 1 time 0 2>/dev/null
buf=
draw() {
  local top='╭── ⠹ 34s  󰪣 GPT-6.1 Sol ──2%─────────────╮' loader=''
  if [ -e "$dir/busy" ]; then
    top='╭── ⠧ 4s  󰪣 GPT-6.1 Sol ──2%──────────────╮'
    loader='  󱊷 Working…'
  fi
  printf '\033[H\033[2J DONE\r\n%s\r\n\033[38;2;0;180;255m%s\033[39m\r\n\033[38;2;0;180;255m╰─ \033[38;2;229;229;231m%-36s\033[38;2;0;180;255m ─╯\033[39m' \
    "$loader" "$top" "$buf"
  printf '\033[4;%dH' $((4 + ${#buf}))
}
drawn=
draw_if_changed() {
  local now=idle
  [ -e "$dir/busy" ] && now=busy
  [ "$now" = "$drawn" ] && return 0
  drawn=$now
  draw
}
draw_if_changed
printf 'ready\n' > "$dir/ready"
while :; do
  if IFS= read -r -n 1 -t 1 ch; then
    case "$ch" in
      ''|$'\r'|$'\n') printf '%s\n' "$buf" >> "$dir/submitted"; buf= ;;
      $'\025') buf= ;;
      *) buf="$buf$ch" ;;
    esac
    draw
  else
    draw_if_changed
  fi
done
LOOP
  chmod +x "$1/omp-pane.sh"
}

# Source the real daemon once for inject_msg, afk_enter, and the inject marker.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

omp_inject() {  # <dir> <harness> -> the daemon log lines this attempt wrote
  local rc
  : > "$1/daemon.log"
  PATH="$1/fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$1/state" FM_SUPERVISOR_TARGET=omp:0 \
    FM_SUPERVISOR_BACKEND=tmux FM_DAEMON_PRIMARY_HARNESS="$2" LOG="$1/daemon.log" \
    FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=5 \
    inject_msg "escalation: omp probe" "$1/state" >/dev/null 2>&1
  rc=$?
  cat "$1/daemon.log"
  return "$rc"
}

test_away_mode_injection_reaches_an_idle_omp_primary_only() {
  local dir out rc
  [ -n "$REAL_TMUX" ] || { echo "skip: tmux not found"; return 0; }
  "$REAL_TMUX" -L "$LEAK_SOCKET" kill-server >/dev/null 2>&1
  dir="$TMP_ROOT/omp-inject"
  mkdir -p "$dir/state" "$(fm_fakebin "$dir")"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$LEAK_SOCKET" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"
  write_omp_shaped_pane "$dir"
  afk_enter "$dir/state"
  "$REAL_TMUX" -L "$LEAK_SOCKET" new-session -d -s omp -x 80 -y 20 "bash '$dir/omp-pane.sh' '$dir'"
  wait_for_file "$dir/ready" || fail "the omp-shaped pane never drew"
  sleep 0.3

  out=$(omp_inject "$dir" claude); rc=$?
  [ "$rc" -ne 0 ] || fail "a Claude-scoped reader injected into omp's composer shape"
  out=$(omp_inject "$dir" omp); rc=$?
  [ "$rc" -eq 0 ] || fail "away-mode injection into an idle omp primary was refused: $out"
  wait_for_file "$dir/submitted" || fail "the injected wake never reached the omp pane"
  case "$(head -1 "$dir/submitted")" in
    $'\xE2\x81\xA3'*"escalation: omp probe"*) ;;
    *) fail "the omp pane did not receive the marked wake: $(head -1 "$dir/submitted")" ;;
  esac
  [ "$(wc -l < "$dir/submitted")" -eq 1 ] || fail "one wake produced $(wc -l < "$dir/submitted") submissions"

  "$REAL_TMUX" -L "$LEAK_SOCKET" send-keys -t omp:0 -l 'half typed'
  sleep 0.3
  out=$(omp_inject "$dir" omp); rc=$?
  [ "$rc" -ne 0 ] || fail "away-mode injection merged into the captain's half-typed omp draft"
  assert_contains "$out" "not confirmed-empty" "a pending omp draft was not refused by the composer guard"
  [ "$(wc -l < "$dir/submitted")" -eq 1 ] || fail "a refused injection still submitted something"
  "$REAL_TMUX" -L "$LEAK_SOCKET" send-keys -t omp:0 C-u
  : > "$dir/busy"
  sleep 1.5
  out=$(omp_inject "$dir" omp); rc=$?
  [ "$rc" -ne 0 ] || fail "away-mode injection typed into an omp primary mid-turn"
  assert_contains "$out" "busy" "an omp turn was not refused by the busy guard"
  pass "away mode: an idle omp primary receives one marked wake; a draft or a running turn defers it"
}

test_omp_busy_signals_each_carry_the_verdict() {
  local capture key_re
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  capture="$TMP_ROOT/omp-busy-pane"
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  unset FM_BUSY_REGEX
  key_re='^[[:space:]]*(󱊷|⎋)[[:space:]]'
  # omp 18.12.6 frames. A tool call replaces the loader's Working… with the
  # tool's own status, and a rebound interrupt key replaces the key symbol.
  printf '│ $ sleep 25 │\n╰─── elapsed 7.0s ───╯\n  󱊷 Waiting for requested duration\n╭── ⠸ 16s  󰪣 GPT-6.1 Sol ──2%%──╮\n╰─            ─╯\n' > "$capture"
  grep -q 'Working…' "$capture" && fail "the tool-phase frame also carries Working…, so it cannot isolate the key signal"
  fm_pane_is_busy fake omp || fail "omp's interrupt-key loader during a tool call did not read busy"
  printf '  ^C Working…\n╭── ⠧ 1s  󰪣 GPT-6.1 Sol ──2%%──╮\n╰─            ─╯\n' > "$capture"
  grep -Eq "$key_re" "$capture" && fail "the rebound-key frame also carries the default key, so it cannot isolate Working…"
  fm_pane_is_busy fake omp || fail "omp's Working… loader under a rebound interrupt key did not read busy"
  printf '  ⎋ Waiting for requested duration\n╭── - 1s  gpt ──╮\n╰─            ─╯\n' > "$capture"
  fm_pane_is_busy fake omp || fail "omp's unicode-preset interrupt-key loader did not read busy"
  printf '  Esc Working…\n╭── - 1s  gpt ──╮\n╰─            ─╯\n' > "$capture"
  fm_pane_is_busy fake omp || fail "omp's ascii-preset Working… loader did not read busy"
  # An async job (the away daemon, a watcher arm) keeps the counter running after
  # the reply, while omp takes new input at once.
  printf ' STARTED\n Reply with the single word PONG.\n PONG\n╭── ⠹ 34s  󰪣 GPT-6.1 Sol ──2%%──╮\n╰─            ─╯\n' > "$capture"
  if fm_pane_is_busy fake omp; then fail "an idle omp with an async job outstanding read busy"; fi
  printf ' Still Working… on the docs\n  • Background job completed [bash] bg_1 (2m)\n╭── 󰵗  󰪣 GPT-6.1 Sol ──2%%──╮\n╰─            ─╯\n' > "$capture"
  if fm_pane_is_busy fake omp; then fail "an idle omp below Working… prose and a job notice read busy"; fi
  printf '│ Command aborted │\n╰─── Timeout: 40s ───╯\n  F5 to retry\n╭── 󰵗  󰪣 GPT-6.1 Sol ──2%%──╮\n╰─            ─╯\n' > "$capture"
  if fm_pane_is_busy fake omp; then fail "an omp composer idle after an interrupted tool read busy"; fi
  printf '  󱊷 Working…\n╭── ⠸ 16s  󰪣 GPT-6.1 Sol ──2%%──╮\n' > "$capture"
  if fm_pane_is_busy fake claude; then fail "omp's busy frame leaked into Claude's matcher"; fi
  printf 'esc to interrupt\n╭── 󰵗  gpt ──╮\n' > "$capture"
  if fm_pane_is_busy fake omp; then fail "Claude's busy footer leaked into omp's matcher"; fi
  unset -f tmux
  pass "fm_pane_is_busy: omp's loader reads busy by its interrupt key or Working…, never by the async-job counter"
}

test_omp_marker_outranks_claude_marker
test_markerless_omp_is_detected_by_exact_ancestry_name
test_server_started_from_omp_keeps_its_markers_out
test_spawned_claude_ignores_omp_markers_in_its_server
test_omp_busy_signals_each_carry_the_verdict
test_away_mode_injection_reaches_an_idle_omp_primary_only

# Herdr exposes native agent identity but no cursor coordinates. These frames
# match a real omp 18.12.6 pane: the last draft line is the bottom border.
# shellcheck disable=SC2329 # The real adapter invokes these fixture capture/identity functions indirectly.
test_herdr_omp_draft_protection() (
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source herdr
  local frame native out expected label
  native=$'omp\tidle'
  fm_backend_herdr_capture_ansi() { printf '%s\n' "$frame"; }
  fm_backend_herdr_agent_identity_raw() { printf '%s\n' "$native"; }
  for label in pending idle multiline clipped trailing working foreign; do
    native=$'omp\tidle'
    case "$label" in
      pending) frame=$'│ stale blank output │\n╭── GPT-6.1 Sol ─╮\n╰─ captain half typed ─╯'; expected=pending ;;
      idle) frame=$'│ stale output │\n╭── GPT-6.1 Sol ─╮\n╰─                    ─╯'; expected=empty ;;
      multiline) frame=$'╭── GPT-6.1 Sol ─╮\n│ earlier draft line │\n╰─                   ─╯'; expected=pending ;;
      clipped) frame=$'│ stale blank output │\n╰─              ─╯'; expected=unknown ;;
      trailing) frame=$'╭── GPT-6.1 Sol ─╮\n╰─               ─╯\n$ '; expected=unknown ;;
      working) frame=$'╭── GPT-6.1 Sol ─╮\n╰─               ─╯'; native=$'omp\tworking'; expected=unknown ;;
      foreign) frame=$'╭── GPT-6.1 Sol ─╮\n╰─               ─╯'; native=$'claude\tidle'; expected=unknown ;;
    esac
    out=$(FM_COMPOSER_HARNESS=omp fm_backend_herdr_composer_state fm-lab-fixture:w1:p1)
    [ "$out" = "$expected" ] || fail "Herdr omp $label composer returned '$out', expected '$expected'"
  done
  pass "Herdr omp: native idle plus complete bottom-border composer permits delivery, drafts and ambiguous panes do not"
)
test_herdr_omp_draft_protection

# shellcheck disable=SC2329 # The real submit adapter invokes these fixture transport functions indirectly.
test_herdr_omp_submit_with_delayed_native_status() (
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source herdr
  local submit_frame verdict cleared
  fm_backend_herdr_capture_ansi() { printf '%s\n' "$submit_frame"; }
  fm_backend_herdr_agent_identity_raw() { printf 'omp\tidle\n'; }
  fm_backend_herdr_agent_status_raw() { printf 'idle'; }
  fm_backend_herdr_wait_for_working() { printf 'idle'; }
  fm_backend_herdr_send_literal() { submit_frame=$'╭── GPT-6.1 Sol ─╮\n╰─ wake message ─╯'; }
  fm_backend_herdr_send_key() {
    if [ "$cleared" = yes ]; then submit_frame=$'╭── GPT-6.1 Sol ─╮\n╰─              ─╯'; fi
  }
  for cleared in yes no; do
    verdict=$(FM_COMPOSER_HARNESS=omp fm_backend_herdr_send_text_submit fm-lab-fixture:w1:p1 'wake message' 1 0 0)
    if [ "$cleared" = yes ]; then
      [ "$verdict" = empty ] || fail "Herdr omp reported '$verdict' after accepted Enter cleared the draft"
    else
      [ "$verdict" = pending ] || fail "Herdr omp reported '$verdict' after Enter left the draft pending"
    fi
  done
  pass "Herdr omp: cleared draft confirms submission despite delayed native status; swallowed Enter does not"
)
test_herdr_omp_submit_with_delayed_native_status
