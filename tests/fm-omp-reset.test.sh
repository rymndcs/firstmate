#!/usr/bin/env bash
# Registered omp reset transitions exercised through the extension API.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-omp-reset)
FM_TEST_CLEANUP_DIRS+=("$LAB")
trap fm_test_cleanup EXIT
mkdir -p "$LAB/.omp/extensions" "$LAB/bin" "$LAB/state"
cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$LAB/.omp/extensions/"
cat > "$LAB/bin/fm-omp-reset-submit.sh" <<'SH'
#!/usr/bin/env bash
[ ! -f "$FM_HOME/state/refuse" ] || exit 1
if [ "$1" = check ]; then exit 0; fi
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
mkdir -p "$LAB/.agents/skills/stow"
cp "$ROOT/.agents/skills/stow/SKILL.md" "$LAB/.agents/skills/stow/"
chmod +x "$LAB"/bin/*.sh
FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" node --experimental-strip-types "$ROOT/tests/fixtures/omp-reset/transitions.mjs"
