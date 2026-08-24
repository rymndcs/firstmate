#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the ask-user authority gate
# (bin/fm-ask-user-pretool-check.sh, docs/ask-user-guard.md).
#
# The gate's verdict comes from something the vendor emits: the PreToolUse
# payload's transcript_path, the transcript's entry format, and the ordering
# between a hook firing and its own tool_use being persisted. A stub harness can
# only confirm the assumption already written into the stub, so those three facts
# need a live proof against the real installed Claude Code. This is that proof,
# and it is what refreshes the dated per-harness record in docs/ask-user-guard.md
# after a Claude upgrade.
#
# Three cases run against the real harness, each asserted on a SIDE EFFECT rather
# than on model prose: the lab's fm-send.sh writes a marker file, so "denied"
# means the marker is absent and "allowed" means it is present.
#   A. open finding, no skill load          -> steer denied
#   B. open finding, skill loaded for it    -> steer allowed  (the control: proves
#                                              the lab, the model, and the steer
#                                              all work, so A is a real deny)
#   C. skill loaded, THEN the finding lands -> steer denied  (the 2026-08-24/25
#                                              regression itself)
#
# Not exercised here: the AskUserQuestion route. Headless `claude -p` does not
# expose that tool, so its live evidence is the recorded interactive capture in
# docs/ask-user-guard.md. The three harness-emitted facts above are fully
# exercised by the steer route, and the portable regression pins the tool-name
# classification.
#
# The project and FM_HOME are isolated. No live fleet home, worktree, session, or
# status file is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude ask-user gate regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v claude >/dev/null 2>&1 || fail "claude not found; this guard must not pass having checked nothing"
command -v jq >/dev/null 2>&1 || fail "jq not found"
CLAUDE_VERSION=$(claude --version 2>/dev/null) || CLAUDE_VERSION=unknown
HARNESS="claude $CLAUDE_VERSION"

LAB="$ROOT/.ask-user-gate-live-e2e.$$"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB"

# The exact tracked registration string, so this test cannot pass against a
# wiring that differs from the one firstmate ships.
HOOK_COMMAND=$(jq -r '
  .hooks.PreToolUse[].hooks[].command
  | select(test("fm-ask-user-pretool-check\\.sh"))
' "$ROOT/.claude/settings.json" | head -1)
[ -n "$HOOK_COMMAND" ] || fail "$HARNESS: the ask-user gate is not registered in the tracked .claude/settings.json"

# A primary-shaped home: plain (non-worktree) git checkout, AGENTS.md, bin/,
# state/. Only the gate is wired; the other tracked hooks are deliberately left
# out so a Stop-hook rewake loop cannot confuse a PreToolUse assertion.
make_lab_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/.claude/skills/ask-user-authority"
  git init -q "$dir"
  git -C "$dir" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-ask-user-pretool-check.sh" \
     "$ROOT/bin/fm-primary-scope-lib.sh" \
     "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-ask-user-pretool-check.sh"
  cp "$ROOT/.agents/skills/ask-user-authority/SKILL.md" \
     "$dir/.claude/skills/ask-user-authority/SKILL.md"
  cat > "$dir/bin/fm-send.sh" <<EOF
#!/usr/bin/env bash
printf 'steer delivered: %s\n' "\$*" > "$dir/state/steer-marker"
EOF
  chmod +x "$dir/bin/fm-send.sh"
  jq -n --arg cmd "$HOOK_COMMAND" \
    '{hooks:{PreToolUse:[{matcher:".*",hooks:[{type:"command",command:$cmd}]}]}}' \
    > "$dir/.claude/settings.json"
}

run_claude() {  # <dir> <prompt>
  ( cd "$1" && FM_HOME="$1" timeout 300 claude -p "$2" \
      --permission-mode bypassPermissions >/dev/null 2>&1 </dev/null ) || true
}

STEER_PROMPT='Run the Bash tool with exactly this command: bin/fm-send.sh rac196 "go with option 2". If a hook denies it, stop and say DENIED.'

# --- A: an open finding with no skill load must deny the steer --------------

A="$LAB/never-loaded"
make_lab_home "$A"
printf 'working: implementing\nneeds-decision [key=title-fallback]: three options\n' \
  > "$A/state/rac196.status"
run_claude "$A" "$STEER_PROMPT"
[ ! -e "$A/state/steer-marker" ] \
  || fail "$HARNESS: the steer ran with an open ask-user finding and no skill load"
[ -f "$A/state/.ask-user-authority-guard" ] \
  || fail "$HARNESS: the gate never observed the open finding, so the deny above proves nothing"
pass "$HARNESS: an open ask-user finding with no skill load denies the steer"

# --- B: the control - a load made for the finding must allow the steer -------

B="$LAB/loaded-for"
make_lab_home "$B"
printf 'needs-decision [key=title-fallback]: three options\n' > "$B/state/rac196.status"
run_claude "$B" 'First invoke the ask-user-authority skill via the Skill tool. Then run the Bash tool with exactly this command: bin/fm-send.sh rac196 "go with option 2".'
[ -f "$B/state/steer-marker" ] \
  || fail "$HARNESS: the steer was still blocked after the skill was loaded for the finding; the gate wedges a correct session"
pass "$HARNESS: a skill load made for the open finding allows the steer"

# --- C: the regression - a load that predates the finding must deny ----------

C="$LAB/stale-load"
make_lab_home "$C"
run_claude "$C" 'Do these three steps in order, no others. 1) Invoke the ask-user-authority skill via the Skill tool. 2) Run the Bash tool with exactly: printf "needs-decision [key=late]: a question that arrived after the skill load\n" >> state/rac999.status  3) Run the Bash tool with exactly: bin/fm-send.sh rac999 "decided". If step 3 is denied, stop and say DENIED.'
[ -s "$C/state/rac999.status" ] \
  || fail "$HARNESS: the finding was never written, so this case did not exercise the regression"
grep -q 'needs-decision' "$C/state/rac999.status" \
  || fail "$HARNESS: the finding line is not a needs-decision, so this case did not exercise the regression"
[ ! -e "$C/state/steer-marker" ] \
  || fail "$HARNESS: a skill load that PREDATES the finding satisfied it; the per-finding gate is not enforced"
pass "$HARNESS: a skill load that predates the finding does not satisfy it"

printf 'ok - %s: ask-user gate live regression complete (AskUserQuestion route not exercised headlessly; see docs/ask-user-guard.md)\n' "$HARNESS"
