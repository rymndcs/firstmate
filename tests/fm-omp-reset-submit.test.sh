#!/usr/bin/env bash
# Native command transport keeps the existing primary composer boundary.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-omp-reset-submit)
FM_TEST_CLEANUP_DIRS+=("$LAB")
trap fm_test_cleanup EXIT
mkdir -p "$LAB/home/state" "$LAB/root/bin" "$LAB/fakebin"
git init -q "$LAB/root"
touch "$LAB/root/AGENTS.md"
printf '%s\n' "$$" > "$LAB/home/state/.lock"
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message)
    if [ "$(cat "$PROBE/mode")" = busy ]; then echo '3 2'; else echo '3 1'; fi
    ;;
  capture-pane)
    mode=$(cat "$PROBE/mode")
    case "$mode" in
      unknown) echo '$ ' ;;
      busy) printf '  󱊷 Working…\n╭── omp ─╮\n╰─       ─╯\n' ;;
      draft) printf '╭── omp ─╮\n╰─ draft ─╯\n' ;;
      *) printf '╭── omp ─╮\n╰─       ─╯\n' ;;
    esac
    ;;
  send-keys) printf '%s\n' "$*" >> "$PROBE/sent" ;;
esac
SH
chmod +x "$LAB/fakebin/tmux"
export PROBE="$LAB" FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" FM_ROOT_OVERRIDE="$LAB/root"
export FM_SUPERVISOR_TARGET='%42' FM_SUPERVISOR_BACKEND=tmux OMPCODE=1
export PATH="$LAB/fakebin:$PATH"
for mode in busy draft unknown; do
  echo "$mode" > "$LAB/mode"
  if "$ROOT/bin/fm-omp-reset-submit.sh" submit abc123 "$$"; then fail "transport accepted $mode composer"; fi
  [ ! -e "$LAB/sent" ] || fail "transport typed into $mode composer"
done
echo empty > "$LAB/mode"
"$ROOT/bin/fm-omp-reset-submit.sh" submit abc123 "$$" || fail 'empty idle primary was refused'
assert_contains "$(cat "$LAB/sent")" '/fm-reset abc123' 'reset command was not submitted'
[ "$(wc -l < "$LAB/sent" | tr -d ' ')" = 2 ] || fail 'expected one type and one Enter'
if env FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-omp-reset-submit.sh" check "$$"; then fail 'task directory was accepted as a primary'; fi
printf '1\n' > "$LAB/home/state/.lock"
if "$ROOT/bin/fm-omp-reset-submit.sh" check "$$"; then fail 'another lock holder was accepted'; fi
printf '%s\n' "$$" > "$LAB/home/state/.lock"
if "$ROOT/bin/fm-omp-reset-submit.sh" submit 'bad nonce' "$$"; then fail 'malformed nonce was accepted'; fi
touch "$LAB/home/state/.captain-hold"
if "$ROOT/bin/fm-omp-reset-submit.sh" submit abc123 "$$"; then fail 'transport ignored global hold'; fi
if "$ROOT/bin/fm-omp-reset-submit.sh" check "$$"; then fail 'readiness check ignored global hold'; fi
if env -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
  "$ROOT/bin/fm-omp-reset-submit.sh" check "$$"; then fail 'transport guessed a pane'; fi
pass 'omp reset transport: empty idle primary only, one submit, no guessed pane or global hold bypass'
