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
cat > "$LAB/bin/fm-omp-reset-submit.sh" <<'SH'
#!/usr/bin/env bash
[ ! -f "$FM_HOME/state/refuse" ] || exit 1
if [ "$1" = check ]; then exit 0; fi
if [ -f "$FM_HOME/state/submit-pauses" ]; then
  touch "$FM_HOME/state/submit-started"
  read -r _ < "$FM_HOME/state/submit-resume"
  exit 1
fi
printf '%s\n' "$2" >> "$FM_HOME/state/submissions"
[ ! -f "$FM_HOME/state/submit-fails" ]
SH
cat > "$LAB/bin/fm-startup-memory-budget.sh" <<'SH'
#!/usr/bin/env bash
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
for scenario in arm-gate draft-race in-flight cancelled-switch thrown-switch partial-switch running-watcher veto-draft veto-busy veto-queued veto-forged veto-foreign-job; do
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" node --experimental-strip-types "$ROOT/tests/fixtures/omp-reset/regressions.mjs" "$scenario"
done
FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" node --experimental-strip-types "$ROOT/tests/fixtures/omp-reset/transitions.mjs"
