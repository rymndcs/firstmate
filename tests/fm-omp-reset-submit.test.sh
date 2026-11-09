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
    if [ -f "$PROBE/takeover" ]; then
      case "$(cat "$PROBE/takeover")" in
        flag) touch "$FM_STATE_OVERRIDE/.afk" ;;
        owner) printf 'none\t-\tomp\n' > "$FM_STATE_OVERRIDE/.afk-daemon-terminal" ;;
        hold) touch "$FM_STATE_OVERRIDE/.captain-hold" ;;
      esac
    fi
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
echo empty > "$LAB/mode"
for signal in flag owner; do
  if [ "$signal" = flag ]; then
    touch "$LAB/home/state/.afk"
  else
    printf 'none\t-\tomp\n' > "$LAB/home/state/.afk-daemon-terminal"
  fi
  if "$HELPER" check "$$"; then fail "$signal permitted reset readiness while away"; fi
  "$HELPER" recover-check "$$" || fail "$signal suppressed owned-home supervision recovery"
  if "$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$"; then fail "$signal permitted reset transport while away"; fi
  [ ! -e "$LAB/sent" ] || fail "$signal typed a reset trigger while away"
  rm -f "${LAB:?}/home/state/.afk" "${LAB:?}/home/state/.afk-daemon-terminal"
done
for record in $'none\t-\tdesktop' $'none\t-\tnative' $'none\t-\tomp-extra' $'none\t-\tomp\nextra'; do
  printf '%s\n' "$record" > "$LAB/home/state/.afk-daemon-terminal"
  "$HELPER" check "$$" || fail 'unrelated or malformed owner record selected omp away'
done
rm -f "${LAB:?}/home/state/.afk-daemon-terminal"
for mode in draft unknown; do
  echo "$mode" > "$LAB/mode"
  if "$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$"; then fail "transport accepted $mode composer"; fi
  [ ! -e "$LAB/sent" ] || fail "transport typed into $mode composer"
done
echo empty > "$LAB/mode"
for signal in flag owner hold; do
  echo "$signal" > "$LAB/takeover"
  if "$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$"; then fail "$signal takeover during composer inspection permitted transport"; fi
  [ ! -e "$LAB/sent" ] || fail "$signal takeover typed a trigger"
  [ "$signal" = hold ] || "$HELPER" recover-check "$$" || fail 'takeover suppressed continuation'
  rm -f "${LAB:?}/takeover" "${LAB:?}/home/state/.afk" "${LAB:?}/home/state/.afk-daemon-terminal" "${LAB:?}/home/state/.captain-hold"
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
if env -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
  "$HELPER" check "$$"; then fail 'transport guessed a pane'; fi
touch "$LAB/home/state/.captain-hold"
if "$HELPER" submit 12345678-1234-1234-1234-123456789abc "$$"; then fail 'transport ignored global hold'; fi
if "$HELPER" check "$$"; then fail 'readiness check ignored global hold'; fi
if "$HELPER" recover-check "$$"; then fail 'recovery ignored global hold'; fi
pass 'omp reset transport: one literal trigger, no external Enter, no guessed pane or global hold bypass'
