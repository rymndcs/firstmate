#!/usr/bin/env bash
# Native command transport keeps the existing primary composer boundary.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-omp-reset-submit)
FM_TEST_CLEANUP_DIRS+=("$LAB")
trap fm_test_cleanup EXIT
mkdir -p "$LAB/home/state" "$LAB/root/bin" "$LAB/fakebin" "$LAB/helper-bin"
for owner in "$ROOT"/bin/*; do
  [ "${owner##*/}" = fm-omp-reset-submit.sh ] || ln -s "$owner" "$LAB/helper-bin/${owner##*/}"
done
cp "${FM_RESET_HELPER_SOURCE:-$ROOT/bin/fm-omp-reset-submit.sh}" "$LAB/helper-bin/"
HELPER="$LAB/helper-bin/fm-omp-reset-submit.sh"
git init -q "$LAB/root"
touch "$LAB/root/AGENTS.md"
printf '%s\n' "$$" > "$LAB/home/state/.lock"
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message)
    if [[ "$(cat "$PROBE/mode")" =~ ^(busy|background)$ ]]; then echo '3 2'; else echo '3 1'; fi
    ;;
  capture-pane)
    mode=$(cat "$PROBE/mode")
    case "$mode" in
      unknown) echo '$ ' ;;
      busy|background) printf '  󱊷 Working…\n╭── omp ─╮\n╰─       ─╯\n' ;;
      draft) printf '╭── omp ─╮\n╰─ draft ─╯\n' ;;
      *) printf '╭── omp ─╮\n╰─       ─╯\n' ;;
    esac
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$PROBE/sent"
    if [ "$4" = -l ]; then
      # Typing arrives after the empty capture, before the transport write.
      printf 'Wai%s' "$5" > "$PROBE/composer"
    elif [ "$4" = Enter ]; then
      cat "$PROBE/composer" > "$PROBE/submitted"
    fi
    ;;
esac
SH
chmod +x "$LAB/fakebin/tmux"
export PROBE="$LAB" FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" FM_ROOT_OVERRIDE="$LAB/root"
export FM_SUPERVISOR_TARGET='%42' FM_SUPERVISOR_BACKEND=tmux OMPCODE=1
export PATH="$LAB/fakebin:$PATH"
for mode in draft unknown; do
  echo "$mode" > "$LAB/mode"
  if "$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$"; then fail "transport accepted $mode composer"; fi
  [ ! -e "$LAB/sent" ] || fail "transport typed into $mode composer"
done
echo background > "$LAB/mode"
"$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$" || fail 'background-job display blocked the native idle-checked reset trigger'
[ ! -e "$LAB/submitted" ] || fail 'background trigger sent external Enter'
: > "$LAB/sent"
echo empty > "$LAB/mode"
"$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$" || fail 'empty idle primary was refused'
[ ! -e "$LAB/submitted" ] || fail 'transport submitted the interleaved Wai draft'
[ "$(wc -l < "$LAB/sent" | tr -d ' ')" = 1 ] || fail 'expected one literal trigger and no external Enter'
assert_contains "$(cat "$LAB/sent")" $'\033[?9001;4660;22136;4660;4660;4660;4660;22136;39612~' 'native trigger nonce was not encoded exactly'
if env FM_ROOT_OVERRIDE="$ROOT" "$HELPER" check "$$"; then fail 'task directory was accepted as a primary'; fi
printf '1\n' > "$LAB/home/state/.lock"
if "$HELPER" check "$$"; then fail 'another lock holder was accepted'; fi
printf '%s\n' "$$" > "$LAB/home/state/.lock"
for bad in 'bad nonce' abc123 12345678123412341234123456789abc ''; do
  rc=0
  "$HELPER" submit "$bad" "$$" || rc=$?
  [ "$rc" -eq 2 ] || fail 'malformed nonce must be rejected as a usage error before encoding'
done
touch "$LAB/home/state/.captain-hold"
if "$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$"; then fail 'transport ignored global hold'; fi
if "$HELPER" check "$$"; then fail 'readiness check ignored global hold'; fi
if env -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
  "$HELPER" check "$$"; then fail 'transport guessed a pane'; fi
pass 'omp reset transport: one literal trigger, no external Enter, no guessed pane or global hold bypass'
