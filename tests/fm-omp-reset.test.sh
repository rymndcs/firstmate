#!/usr/bin/env bash
# Registered omp reset transitions exercised through the extension API.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-omp-reset)
FM_TEST_CLEANUP_DIRS+=("$LAB")
trap fm_test_cleanup EXIT
mkdir -p "$LAB/.omp/extensions" "$LAB/bin" "$LAB/state"
cp "${FM_RESET_EXTENSION:-$ROOT/.omp/extensions/fm-primary-omp.ts}" "$LAB/.omp/extensions/fm-primary-omp.ts"
cp "$ROOT/bin/fm-operational-input.sh" "$LAB/bin/fm-operational-input.real.sh"
cat > "$LAB/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = encode ] && [ -f "$FM_HOME/state/encoding-failures" ]; then
  count=0
  [ ! -f "$FM_HOME/state/encoding-count" ] || count=$(cat "$FM_HOME/state/encoding-count")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_HOME/state/encoding-count"
  case ",$(cat "$FM_HOME/state/encoding-failures")," in
    *",$count,"*) echo 'injected encoding failure' >&2; exit 1 ;;
  esac
fi
exec "$FM_HOME/bin/fm-operational-input.real.sh" "$@"
SH
export FM_RESET_SOURCE_ROOT="$ROOT"
cat > "$LAB/bin/fm-omp-reset-submit.sh" <<'SH'
#!/usr/bin/env bash
[ ! -f "$FM_HOME/state/refuse" ] || exit 1
if [ "$1" = recover-check ]; then
  printf 'checked\n' >> "$FM_HOME/state/recovery-checks"
  [ ! -f "$FM_HOME/state/recovery-refused" ]
  exit $?
fi
if [ "$1" = check ]; then
  [ ! -e "$FM_HOME/state/.afk" ] && [ ! -e "$FM_HOME/state/.afk-daemon-terminal" ]
  exit $?
fi
if [ -f "$FM_HOME/state/submit-pauses" ]; then
  touch "$FM_HOME/state/submit-started"
  read -r _ < "$FM_HOME/state/submit-resume"
  [ -f "$FM_HOME/state/submit-succeeds" ]
  exit $?
fi
printf '%s\n' "$2" >> "$FM_HOME/state/submissions"
[ ! -f "$FM_HOME/state/submit-fails" ]
SH
cat > "$LAB/bin/fm-startup-memory-budget.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/state/budget-takeover" ]; then
  case "$(cat "$FM_HOME/state/budget-takeover")" in
    flag) touch "$FM_HOME/state/.afk" ;;
    owner) printf 'none\t-\tomp\n' > "$FM_HOME/state/.afk-daemon-terminal" ;;
  esac
fi
if [ -f "$FM_HOME/state/budget-fails" ]; then echo budget_status=within-budget; exit 2; fi
if [ -f "$FM_HOME/state/over-budget" ]; then
  echo budget_status=over-budget
else
  echo budget_status=within-budget
fi
SH
for file in fm-turnend-guard.sh fm-sessionstart-nudge.sh fm-cd-pretool-check.sh fm-arm-pretool-check.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/$file"
done
cat > "$LAB/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *' | head -1'*) exit 2 ;; esac
SH
mkfifo "$LAB/state/submit-resume"
mkdir -p "$LAB/.agents/skills/stow"
cp "$ROOT/.agents/skills/stow/SKILL.md" "$LAB/.agents/skills/stow/"
chmod +x "$LAB"/bin/*.sh
if [ -n "${FM_RESET_REGRESSION:-}" ]; then
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" node --experimental-strip-types "$ROOT/tests/fixtures/omp-reset/regressions.mjs" "$FM_RESET_REGRESSION"
  exit
fi
node "$ROOT/tests/fixtures/omp-reset/live-reporter.mjs" "$ROOT" "$LAB/reporter"
if [ -n "${FM_RESET_REPORTER_CASE:-}" ]; then exit; fi
for scenario in startup-refused startup-encoding startup-enqueue startup-recovery-encoding startup-recovery-enqueue recovery-encoding recovery-enqueue normal-seed unquoted-arm away-flag-prepare away-flag-ready away-flag-ready-budget away-flag-command-budget away-flag-scheduled away-flag-input away-flag-command away-flag-in-flight away-flag-in-flight-clean away-owner-prepare away-owner-ready away-owner-ready-budget away-owner-command-budget away-owner-scheduled away-owner-input away-owner-command away-owner-in-flight away-owner-in-flight-clean arm-gate draft-race in-flight cancelled-switch thrown-switch partial-switch running-watcher veto-draft veto-busy veto-queued veto-forged veto-foreign-job; do
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" node --experimental-strip-types "$ROOT/tests/fixtures/omp-reset/regressions.mjs" "$scenario"
done
FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" node --experimental-strip-types "$ROOT/tests/fixtures/omp-reset/transitions.mjs"
