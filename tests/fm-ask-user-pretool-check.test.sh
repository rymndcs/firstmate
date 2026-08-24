#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the ask-user-authority PreToolUse gate (docs/ask-user-guard.md).
#
# The guard exists to stop one concrete regression: a firstmate primary loads
# `ask-user-authority` once early in a session and then decides later findings
# without it. So the load-bearing assertion in this suite is not "denies when the
# skill was never loaded" but "denies when the skill was loaded BEFORE the finding
# appeared" - test_stale_load_before_finding_is_denied. Without that case the
# guard would look correct and still permit the reported failure.
#
# The second load-bearing group is the fail-safe family. A guard that wrongly
# denies blocks the whole fleet including the steering needed to unblock it, so
# every undeterminable state is asserted to allow AND to stay silent.
#
# No harness is spawned. Transcripts are synthesized in the exact shape recorded
# in docs/ask-user-guard.md from the live Claude Code payload probe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-ask-user-pretool-check)

# A primary-shaped home: plain (non-worktree) git repo, AGENTS.md, bin/ with the
# guard and both libraries it sources, and a state directory.
install_guard() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-ask-user-pretool-check.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-ask-user-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  chmod +x "$dir/bin/fm-ask-user-pretool-check.sh"
}

make_primary_home() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/state"
  install_guard "$dir"
  printf '%s\n' "$dir"
}

# One assistant turn carrying one tool_use block, in the transcript shape the
# live probe recorded (docs/ask-user-guard.md).
transcript_tool_use() {  # <transcript> <tool-name> <input-json>
  jq -cn --arg name "$2" --argjson input "$3" \
    '{type:"assistant",timestamp:"2026-08-25T00:00:00.000Z",message:{role:"assistant",content:[{type:"tool_use",name:$name,input:$input}]}}' \
    >> "$1"
}

# Filler that is NOT a skill load, used to grow the transcript between events.
transcript_noise() {  # <transcript> <text>
  jq -cn --arg text "$2" \
    '{type:"user",timestamp:"2026-08-25T00:00:00.000Z",message:{role:"user",content:$text}}' \
    >> "$1"
}

# Drive the guard the way the wired Claude hook does: a PreToolUse payload on
# stdin. Results land in GUARD_RC / GUARD_OUT / GUARD_ERR rather than a packed
# string, so a deny message containing any separator byte cannot corrupt them.
GUARD_RC=0
GUARD_OUT=""
GUARD_ERR=""

run_guard() {  # <home> <transcript> <tool-name> [command]
  local home=$1 transcript=$2 tool=$3 cmd=${4:-} payload out err
  payload=$(jq -cn --arg tool "$tool" --arg cmd "$cmd" --arg tp "$transcript" \
    '{hook_event_name:"PreToolUse",tool_name:$tool,tool_input:(if $cmd == "" then {} else {command:$cmd} end),transcript_path:$tp}')
  out=$(mktemp "$TMP_ROOT/out.XXXXXX")
  err=$(mktemp "$TMP_ROOT/err.XXXXXX")
  printf '%s' "$payload" | FM_HOME="$home" "$home/bin/fm-ask-user-pretool-check.sh" --claude >"$out" 2>"$err"
  GUARD_RC=$?
  GUARD_OUT=$(cat "$out")
  GUARD_ERR=$(cat "$err")
  rm -f "$out" "$err"
}

assert_allowed_silently() {  # <label>
  local label=$1
  expect_code 0 "$GUARD_RC" "$label must allow"
  [ -z "$GUARD_OUT" ] || fail "$label allow must leave stdout empty: $GUARD_OUT"
  [ -z "$GUARD_ERR" ] || fail "$label allow must stay silent: $GUARD_ERR"
}

assert_denied() {  # <label> <expected-finding-label>
  local label=$1 key=$2
  expect_code 2 "$GUARD_RC" "$label must deny"
  [ -z "$GUARD_OUT" ] || fail "$label deny under --claude must leave stdout empty: $GUARD_OUT"
  printf '%s' "$GUARD_ERR" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "$label deny must carry a Claude deny object on stderr: $GUARD_ERR"
  assert_contains "$GUARD_ERR" '[ask-user-authority]' "$label deny must carry the reason code"
  assert_contains "$GUARD_ERR" "$key" "$label deny must name the open finding"
  assert_contains "$GUARD_ERR" 'Invoke the ask-user-authority skill' "$label deny must say exactly what to do"
}

# --- 1 + 2: both routes are denied when the skill was never loaded ----------

test_both_routes_denied_without_a_load() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/never-loaded")
  transcript="$TMP_ROOT/never-loaded.jsonl"
  transcript_noise "$transcript" 'session opens'

  printf 'working: implementing\n' > "$home/state/rac196.status"
  printf 'needs-decision [key=title-fallback]: COALESCE fallback could yield an empty title; three options\n' \
    >> "$home/state/rac196.status"

  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'asking the captain with an open finding' 'rac196 [key=title-fallback]'

  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'go with option 2'"
  assert_denied 'steering the worker with an open finding' 'rac196 [key=title-fallback]'

  pass "both routes out of an open ask-user finding are denied when the skill was never loaded"
}

# --- 3: a load made FOR the finding satisfies both routes -------------------

test_load_for_the_finding_allows_both_routes() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/loaded-for")
  transcript="$TMP_ROOT/loaded-for.jsonl"
  transcript_noise "$transcript" 'session opens'

  printf 'needs-decision [key=title-fallback]: three options\n' > "$home/state/rac196.status"

  # The first tool call after the finding appears is what stamps its position.
  run_guard "$home" "$transcript" Read
  assert_allowed_silently 'an ungated call while a finding is open'

  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'

  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking the captain after loading the skill for this finding'

  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'go with option 2'"
  assert_allowed_silently 'steering the worker after loading the skill for this finding'

  pass "a skill load made after the finding appeared satisfies both routes"
}

# --- 4: THE REGRESSION - a load made before the finding does not count -------

test_stale_load_before_finding_is_denied() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/stale-load")
  transcript="$TMP_ROOT/stale-load.jsonl"

  # An early, genuine load - the exact pattern that failed on 2026-08-24/25.
  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  transcript_noise "$transcript" 'an hour of unrelated work across five tickets'

  # Only now does the finding appear.
  printf 'needs-decision [key=title-fallback]: three options\n' > "$home/state/rac196.status"

  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'asking the captain on a stale early load' 'rac196 [key=title-fallback]'

  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'go with option 2'"
  assert_denied 'steering the worker on a stale early load' 'rac196 [key=title-fallback]'

  # And the remedy still works: loading it now, for this finding, clears it.
  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking the captain after reloading for this finding'

  pass "a skill load that predates the finding is denied; reloading for it clears the gate"
}

test_reopened_key_needs_a_fresh_load() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/reopened")
  transcript="$TMP_ROOT/reopened.jsonl"
  transcript_noise "$transcript" 'session opens'

  printf 'needs-decision [key=api-shape]: first question\n' > "$home/state/rac197.status"
  run_guard "$home" "$transcript" Read
  assert_allowed_silently 'ungated call stamping the first finding'
  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking about the first finding'

  printf 'resolved [key=api-shape]: captain chose the narrow shape\n' >> "$home/state/rac197.status"
  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking with nothing open'

  # Same key opens again. The earlier load must not carry over.
  printf 'needs-decision [key=api-shape]: second, different question\n' >> "$home/state/rac197.status"
  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'asking about a reopened key' 'rac197 [key=api-shape]'

  pass "reopening the same decision key is a new finding and needs its own load"
}

# --- 5: nothing open means nothing is denied --------------------------------

test_no_open_finding_allows_everything() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/nothing-open")
  transcript="$TMP_ROOT/nothing-open.jsonl"
  transcript_noise "$transcript" 'session opens'

  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking the captain with an empty state dir'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'rebase onto main'"
  assert_allowed_silently 'ordinary steering with an empty state dir'

  printf 'working: implementing\ndone: PR ready\n' > "$home/state/rac190.status"
  printf 'needs-decision [key=old]: superseded\nresolved [key=old]: decided\n' > "$home/state/rac191.status"
  printf 'blocked: needs a credential\n' > "$home/state/rac192.status"

  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking the captain with only resolved and blocked lines'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac190 'ship it'"
  assert_allowed_silently 'ordinary steering with only resolved and blocked lines'
  run_guard "$home" "$transcript" Bash 'git status'
  assert_allowed_silently 'an unrelated shell command'

  pass "no open ask-user finding means no route is denied, and a blocked line never gates"
}

# --- 6: every undeterminable state allows, silently -------------------------

test_fail_safe_states_allow_silently() {
  local home transcript result rc
  home=$(make_primary_home "$TMP_ROOT/failsafe")
  transcript="$TMP_ROOT/failsafe.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  # Sanity: this fixture DOES deny, so each case below proves the fail-safe and
  # not merely a guard that never fires.
  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'the fail-safe fixture baseline' 'rac196 [key=k]'

  run_guard "$home" "$TMP_ROOT/no-such-transcript.jsonl" AskUserQuestion
  assert_allowed_silently 'an absent transcript'

  local unreadable="$TMP_ROOT/unreadable.jsonl"
  cp "$transcript" "$unreadable"
  chmod 000 "$unreadable"
  if [ ! -r "$unreadable" ]; then
    run_guard "$home" "$unreadable" AskUserQuestion
  assert_allowed_silently 'an unreadable transcript'
  fi
  chmod 644 "$unreadable"

  # A transcript whose entries this guard can no longer parse. This is the
  # format-change case: a future harness release must disarm the guard, never
  # turn every scan into a silent no-match that denies the whole fleet.
  local garbled="$TMP_ROOT/garbled.jsonl"
  printf 'not json at all\nalso not json\n' > "$garbled"
  run_guard "$home" "$garbled" AskUserQuestion
  assert_allowed_silently 'a transcript in an unrecognized format'

  local shapeless="$TMP_ROOT/shapeless.jsonl"
  printf '{"unexpected":"shape"}\n[1,2,3]\n' > "$shapeless"
  run_guard "$home" "$shapeless" AskUserQuestion
  assert_allowed_silently 'a transcript carrying no recognizable entries'

  # A status file that is not readable at all must not gate anything.
  local blind="$TMP_ROOT/blindstate"
  make_primary_home "$blind" >/dev/null
  printf 'needs-decision [key=k]: open question\n' > "$blind/state/rac196.status"
  chmod 000 "$blind/state/rac196.status"
  if [ ! -r "$blind/state/rac196.status" ]; then
    run_guard "$blind" "$transcript" AskUserQuestion
  assert_allowed_silently 'an unreadable status file'
  fi
  chmod 644 "$blind/state/rac196.status"

  # An unwritable state directory cannot hold the ledger, so it cannot prove
  # anything and must step aside.
  local rostate="$TMP_ROOT/rostate"
  make_primary_home "$rostate" >/dev/null
  printf 'needs-decision [key=k]: open question\n' > "$rostate/state/rac196.status"
  chmod 555 "$rostate/state"
  if [ ! -w "$rostate/state" ]; then
    run_guard "$rostate" "$transcript" AskUserQuestion
  assert_allowed_silently 'an unwritable state directory'
  fi
  chmod 755 "$rostate/state"

  # Malformed and empty transport.
  for payload in '' 'not json' '{}' '{"tool_name":"AskUserQuestion"}'; do
    result=$(printf '%s' "$payload" | FM_HOME="$home" "$home/bin/fm-ask-user-pretool-check.sh" --claude 2>&1)
    rc=$?
    expect_code 0 "$rc" "malformed payload '$payload' must allow"
    [ -z "$result" ] || fail "malformed payload '$payload' must stay silent: $result"
  done

  # Missing classify library: the owner of keyed open/resolved semantics is gone,
  # so the guard cannot read the state it gates on.
  local nolib="$TMP_ROOT/nolib"
  make_primary_home "$nolib" >/dev/null
  printf 'needs-decision [key=k]: open question\n' > "$nolib/state/rac196.status"
  rm -f "$nolib/bin/fm-classify-lib.sh"
  run_guard "$nolib" "$transcript" AskUserQuestion
  assert_allowed_silently 'a missing classify library'

  pass "every undeterminable state allows and stays silent"
}

# --- scope: only a genuine primary home ------------------------------------

test_inert_outside_a_primary_home() {
  local base child transcript nonfm
  transcript="$TMP_ROOT/scope.jsonl"
  transcript_noise "$transcript" 'session opens'

  base="$TMP_ROOT/scope-base"
  child="$TMP_ROOT/scope-child"
  fm_git_worktree "$base" "$child" fm/ask-user-guard-test
  : > "$child/AGENTS.md"
  mkdir -p "$child/state"
  install_guard "$child"
  printf 'needs-decision [key=k]: open question\n' > "$child/state/rac196.status"
  run_guard "$child" "$transcript" AskUserQuestion
  assert_allowed_silently 'a crewmate/scout linked task worktree'

  nonfm="$TMP_ROOT/scope-nonfm"
  git init -q "$nonfm"
  git -C "$nonfm" commit -q --allow-empty -m init
  mkdir -p "$nonfm/state"
  install_guard "$nonfm"   # bin/ and state/ present, but no AGENTS.md
  printf 'needs-decision [key=k]: open question\n' > "$nonfm/state/rac196.status"
  run_guard "$nonfm" "$transcript" AskUserQuestion
  assert_allowed_silently 'a non-firstmate repo'

  pass "the gate is inert in a task worktree and outside a firstmate home"
}

test_secondmate_home_is_gated() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/secondmate")
  printf 'sm-ask-1\n' > "$home/.fm-secondmate-home"
  transcript="$TMP_ROOT/secondmate.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'a secondmate home' 'rac196 [key=k]'

  pass "a secondmate home runs its own fleet and is gated like any primary"
}

# --- proof must be structural, never a substring ----------------------------

test_deny_text_cannot_satisfy_itself() {
  local home transcript deny_text
  home=$(make_primary_home "$TMP_ROOT/self-satisfy")
  transcript="$TMP_ROOT/self-satisfy.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'the first denied attempt' 'rac196 [key=k]'
  deny_text=$GUARD_ERR

  # Replay the deny text back into the transcript exactly as a tool_result and an
  # assistant sentence would carry it. The skill name is all over it.
  jq -cn --arg text "$deny_text" \
    '{type:"user",timestamp:"2026-08-25T00:00:00.000Z",message:{role:"user",content:[{type:"tool_result",content:$text}]}}' \
    >> "$transcript"
  transcript_noise "$transcript" 'I should load ask-user-authority before deciding this finding.'
  transcript_tool_use "$transcript" Bash '{"command":"grep -rn ask-user-authority .agents/skills"}'

  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'the deny text replayed into the transcript' 'rac196 [key=k]'

  pass "the skill name as text never satisfies the gate, including this guard's own deny message"
}

test_reading_the_skill_file_counts_as_a_load() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/read-file")
  transcript="$TMP_ROOT/read-file.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"
  run_guard "$home" "$transcript" Read
  assert_allowed_silently 'ungated call stamping the finding'

  transcript_tool_use "$transcript" Read \
    '{"file_path":"/home/x/ai-workspace/.agents/skills/ask-user-authority/SKILL.md"}'
  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking after reading the skill file directly'

  # And the shell equivalent, which is how a bypass-permissions session reads it.
  local other otranscript
  other=$(make_primary_home "$TMP_ROOT/read-file-sh")
  otranscript="$TMP_ROOT/read-file-sh.jsonl"
  transcript_noise "$otranscript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$other/state/rac196.status"
  run_guard "$other" "$otranscript" Read
  assert_allowed_silently 'ungated call stamping the finding'
  transcript_tool_use "$otranscript" Bash \
    '{"command":"cat .agents/skills/ask-user-authority/SKILL.md"}'
  run_guard "$other" "$otranscript" AskUserQuestion
  assert_allowed_silently 'asking after reading the skill file through the shell'

  pass "reading the skill's own SKILL.md counts as loading it, by tool or by shell"
}

# --- transport shapes and the escape hatch ----------------------------------

test_harness_entry_forms() {
  local home transcript payload out err rc
  home=$(make_primary_home "$TMP_ROOT/entry-forms")
  transcript="$TMP_ROOT/entry-forms.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  # Default (non-Claude) deny also writes the Grok decision object on stdout.
  payload=$(jq -cn --arg tp "$transcript" \
    '{tool_name:"AskUserQuestion",tool_input:{},transcript_path:$tp}')
  out=$(mktemp "$TMP_ROOT/ef.out.XXXXXX"); err=$(mktemp "$TMP_ROOT/ef.err.XXXXXX")
  printf '%s' "$payload" | FM_HOME="$home" "$home/bin/fm-ask-user-pretool-check.sh" >"$out" 2>"$err"
  rc=$?
  expect_code 2 "$rc" 'default-mode deny'
  jq -e '.decision == "deny"' "$out" >/dev/null 2>&1 \
    || fail "default-mode deny must carry decision=deny on stdout: $(cat "$out")"

  # Grok payload key spelling.
  payload=$(jq -cn --arg tp "$transcript" \
    '{toolName:"AskUserQuestion",toolInput:{},transcript_path:$tp}')
  printf '%s' "$payload" | FM_HOME="$home" "$home/bin/fm-ask-user-pretool-check.sh" --claude >"$out" 2>"$err"
  rc=$?
  expect_code 2 "$rc" 'grok-shaped payload deny'

  # CLI mode, used by adapters that already hold the values.
  FM_HOME="$home" "$home/bin/fm-ask-user-pretool-check.sh" --claude \
    --tool AskUserQuestion --transcript "$transcript" >"$out" 2>"$err"
  rc=$?
  expect_code 2 "$rc" 'CLI-mode deny'
  FM_HOME="$home" "$home/bin/fm-ask-user-pretool-check.sh" --claude \
    --tool Bash --command "$home/bin/fm-send.sh rac196 hi" --transcript "$transcript" >"$out" 2>"$err"
  rc=$?
  expect_code 2 "$rc" 'CLI-mode steer deny'

  pass "stdin Claude/Codex, stdin Grok, and CLI entry forms all reach the same decision"
}

test_quoted_steer_still_matches() {
  local home transcript cmd
  home=$(make_primary_home "$TMP_ROOT/quoted")
  transcript="$TMP_ROOT/quoted.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  for cmd in \
    'bin/fm-send.sh rac196 ok' \
    '"bin/fm-send.sh" rac196 ok' \
    "bin/fm-'send'.sh rac196 ok" \
    'bin/fm-\send.sh rac196 ok' \
    'FM_HOME=/h bin/fm-send.sh rac196 ok'
  do
    run_guard "$home" "$transcript" Bash "$cmd"
  assert_denied "steer form <$cmd>" 'rac196 [key=k]'
  done

  pass "ordinary quoting and escaping around the steer entry point still reach the gate"
}

# A guard that denies `cat bin/fm-send.sh` wedges the diagnosis of the very thing
# it gated, so the steer route is a command-WORD decision, not a mention of the
# script anywhere in the command line.
test_mentioning_the_steer_script_is_not_steering() {
  local home transcript cmd
  home=$(make_primary_home "$TMP_ROOT/mentions")
  transcript="$TMP_ROOT/mentions.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  for cmd in \
    'cat bin/fm-send.sh' \
    'grep -rn fm-send bin/' \
    'ls -la bin/fm-send.sh' \
    'git log --oneline bin/fm-send.sh' \
    'echo fm-send'
  do
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_allowed_silently "read-only command <$cmd>"
  done

  for cmd in \
    'bin/fm-send.sh rac196 ok' \
    '"bin/fm-send.sh" rac196 ok' \
    "bin/fm-'send'.sh rac196 ok" \
    'FM_HOME=/h bin/fm-send.sh rac196 ok' \
    'command bin/fm-send.sh rac196 ok' \
    'bin/fm-send.sh rac196 --key Escape'
  do
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_denied "steer invocation <$cmd>" 'rac196 [key=k]'
  done

  pass "inspecting bin/fm-send.sh is allowed while invoking it is denied"
}

# The steer still lands from a subshell, a brace group, a pipeline stage, and a
# backgrounded job, so none of those positions is skipped.
test_steer_in_a_compound_command_is_denied() {
  local home transcript cmd
  home=$(make_primary_home "$TMP_ROOT/compound")
  transcript="$TMP_ROOT/compound.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  # shellcheck disable=SC2016 # the classifier, not this test shell, reads these commands
  for cmd in \
    '(bin/fm-send.sh rac196 ok)' \
    '{ bin/fm-send.sh rac196 ok; }' \
    'echo ok | bin/fm-send.sh rac196 ok' \
    'bin/fm-send.sh rac196 ok &' \
    'true && bin/fm-send.sh rac196 ok' \
    'x=$(bin/fm-send.sh rac196 ok)' \
    'env FM_HOME=/h bin/fm-send.sh rac196 ok' \
    'timeout 5 bin/fm-send.sh rac196 ok'
  do
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_denied "steer position <$cmd>" 'rac196 [key=k]'
  done

  pass "a steer in a subshell, brace group, pipeline, background job, or list still gates"
}

# A guard a `for` loop walks straight through is not a guard. Answering two
# workers in one Bash call is the realistic agent-mistake shape, and command
# position alone never sees it: splitProgram cuts on operators, so the loop body
# arrives headed by `do` and the steer is never in a command position. The rule
# that closes it is "cannot prove it is NOT a steer -> deny", which is why the
# read-only cases above have to keep allowing in the same fixture.
test_steer_the_walk_cannot_place_is_denied() {
  local home transcript cmd
  home=$(make_primary_home "$TMP_ROOT/unplaceable")
  transcript="$TMP_ROOT/unplaceable.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  # shellcheck disable=SC2016 # the classifier, not this test shell, reads these commands
  for cmd in \
    'for w in rac196 rac197; do bin/fm-send.sh $w ok; done' \
    'while read -r w; do bin/fm-send.sh $w ok; done' \
    'if true; then bin/fm-send.sh rac196 ok; fi' \
    'case x in a) bin/fm-send.sh rac196 ok;; esac' \
    'eval bin/fm-send.sh rac196 ok' \
    'eval "bin/fm-send.sh rac196 ok"' \
    'xargs -I{} bin/fm-send.sh {} ok' \
    "bash -c 'bin/fm-send.sh rac196 ok'" \
    "sh -c 'bin/fm-send.sh rac196 ok'" \
    'find . -name x -exec bin/fm-send.sh {} ;'
  do
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_denied "unplaceable steer <$cmd>" 'rac196 [key=k]'
  done

  # The escalation must not swallow the read-only cases back up, which is the
  # whole reason it keys on command position rather than on a mention.
  for cmd in \
    'cat bin/fm-send.sh' \
    'ls -la bin/fm-send.sh' \
    'git log --oneline bin/fm-send.sh' \
    'grep -rn fm-send.sh bin/' \
    'find . -name fm-send.sh'
  do
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_allowed_silently "read-only command <$cmd>"
  done

  pass "a steer in a loop, conditional, case list, eval, xargs, or shell -c is denied without re-denying inspection"
}

# The classifier is a downstream owner, so its absence is an undeterminable state
# like every other one in this guard: allow, silently.
test_missing_steer_classifier_allows_silently() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/no-classifier")
  transcript="$TMP_ROOT/no-classifier.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  # Baseline: this fixture denies, so the allow below cannot pass vacuously.
  run_guard "$home" "$transcript" Bash 'bin/fm-send.sh rac196 ok'
  assert_denied 'classifier-present baseline' 'rac196 [key=k]'

  rm -f "$home/bin/fm-ask-user-command-policy.mjs"
  run_guard "$home" "$transcript" Bash 'bin/fm-send.sh rac196 ok'
  assert_allowed_silently 'steer with no command policy installed'

  # The other route is unaffected: it needs no shell classification at all.
  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'asking the captain with no command policy installed' 'rac196 [key=k]'

  pass "a missing steer command policy allows the steer silently and leaves the ask route gated"
}

test_escape_hatch_allows() {
  local home transcript out rc payload
  home=$(make_primary_home "$TMP_ROOT/escape")
  transcript="$TMP_ROOT/escape.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"
  payload=$(jq -cn --arg tp "$transcript" \
    '{tool_name:"AskUserQuestion",tool_input:{},transcript_path:$tp}')

  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ALLOW_ASK_USER=1 \
    "$home/bin/fm-ask-user-pretool-check.sh" --claude 2>&1)
  rc=$?
  expect_code 0 "$rc" 'FM_ALLOW_ASK_USER=1 must allow'
  [ -z "$out" ] || fail "escape hatch must stay silent: $out"

  # Every other value stays closed, including the near-misses.
  local value
  for value in '' 0 yes true 11; do
    printf '%s' "$payload" | FM_HOME="$home" FM_ALLOW_ASK_USER="$value" \
      "$home/bin/fm-ask-user-pretool-check.sh" --claude >/dev/null 2>&1
    rc=$?
    expect_code 2 "$rc" "FM_ALLOW_ASK_USER='$value' must NOT open the gate"
  done

  pass "FM_ALLOW_ASK_USER=1 is the only value that allows deliberately"
}

test_multiple_findings_need_each_one_loaded() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/multi")
  transcript="$TMP_ROOT/multi.jsonl"
  transcript_noise "$transcript" 'session opens'

  printf 'needs-decision [key=a]: first question\n' > "$home/state/rac196.status"
  run_guard "$home" "$transcript" Read
  assert_allowed_silently 'ungated call stamping finding a'
  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'asking with only finding a open'

  # A second, unrelated finding lands on another task.
  printf 'needs-decision [key=b]: second question\n' > "$home/state/rac197.status"
  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'asking with a second, unproven finding open' 'rac197 [key=b]'

  pass "an unproven finding anywhere in the home gates both routes, per finding"
}

# --- Claude wiring ----------------------------------------------------------

test_claude_hook_is_wired() {
  local settings
  settings="$ROOT/.claude/settings.json"
  jq -e '
    [.hooks.PreToolUse[]
     | select(.matcher == ".*")
     | .hooks[].command
     | select(test("fm-ask-user-pretool-check\\.sh"))]
    | length == 1
  ' "$settings" >/dev/null \
    || fail "the ask-user gate must be wired exactly once under the .* PreToolUse matcher"
  jq -e '
    [.hooks.PreToolUse[].hooks[].command
     | select(test("fm-ask-user-pretool-check\\.sh"))
     | select(test("--claude"))]
    | length == 1
  ' "$settings" >/dev/null \
    || fail "the wired ask-user gate must pass --claude so stdout stays empty on deny"
  pass "the ask-user gate is wired for Claude on every tool, with --claude"
}

test_both_routes_denied_without_a_load
test_load_for_the_finding_allows_both_routes
test_stale_load_before_finding_is_denied
test_reopened_key_needs_a_fresh_load
test_no_open_finding_allows_everything
test_fail_safe_states_allow_silently
test_inert_outside_a_primary_home
test_secondmate_home_is_gated
test_deny_text_cannot_satisfy_itself
test_reading_the_skill_file_counts_as_a_load
test_harness_entry_forms
test_quoted_steer_still_matches
test_mentioning_the_steer_script_is_not_steering
test_steer_in_a_compound_command_is_denied
test_steer_the_walk_cannot_place_is_denied
test_missing_steer_classifier_allows_silently
test_escape_hatch_allows
test_multiple_findings_need_each_one_loaded
test_claude_hook_is_wired
