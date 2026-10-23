#!/usr/bin/env bash
# Claude UserPromptSubmit context for an active captain hold, primary homes only.
# Real captain replies never clear it; operational injections receive no context.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
payload=$(cat 2>/dev/null) || exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ -e "$STATE/.captain-hold" ] || exit 0
prompt=$(printf '%s' "$payload" | jq -er '.prompt | select(type == "string")' 2>/dev/null) || exit 0
fm_operational_input_classify "$prompt" operational_kind && exit 0
case "$prompt" in
  "$FM_OPERATIONAL_PREFIX"*|"$FM_INJECT_MARK"*) exit 0 ;;
esac
cat <<'EOF'
Captain hold is active. Automatic supervision must remain held across your reply; a captain message alone does not clear it. End your reply by asking the captain to /stow then /clear, or explicitly dismiss the hold. Repeat that question on subsequent replies until the captain decides. Only when the captain explicitly dismisses it, run bin/fm-captain-hold.sh clear; a new session clears it through bin/fm-session-start.sh. Do not arm supervision or take automatic wake turns while it remains active.
EOF
