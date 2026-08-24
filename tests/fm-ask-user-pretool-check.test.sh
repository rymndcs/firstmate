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

run_guard() {  # <home> <transcript> <tool-name> [command] [path-override]
  local home=$1 transcript=$2 tool=$3 cmd=${4:-} path=${5:-} payload out err
  payload=$(jq -cn --arg tool "$tool" --arg cmd "$cmd" --arg tp "$transcript" \
    '{hook_event_name:"PreToolUse",tool_name:$tool,tool_input:(if $cmd == "" then {} else {command:$cmd} end),transcript_path:$tp}')
  out=$(mktemp "$TMP_ROOT/out.XXXXXX")
  err=$(mktemp "$TMP_ROOT/err.XXXXXX")
  if [ -n "$path" ]; then
    printf '%s' "$payload" | env PATH="$path" FM_HOME="$home" \
      "$home/bin/fm-ask-user-pretool-check.sh" --claude >"$out" 2>"$err"
  else
    printf '%s' "$payload" | FM_HOME="$home" \
      "$home/bin/fm-ask-user-pretool-check.sh" --claude >"$out" 2>"$err"
  fi
  GUARD_RC=$?
  GUARD_OUT=$(cat "$out")
  GUARD_ERR=$(cat "$err")
  rm -f "$out" "$err"
}

# A PATH carrying everything the guard and its libraries invoke EXCEPT one tool,
# so a "missing <tool>" fail-safe is exercisable without touching the system.
path_without() {  # <tool> -> prints a PATH holding symlinks to the rest
  local drop=$1 dir tool src
  dir=$(mktemp -d "$TMP_ROOT/path-without.XXXXXX")
  # bash and env are needed for the shebang to resolve at all.
  for tool in bash sh env cat sed awk grep tail head wc cksum tr cut mv rm ls \
              git jq node basename dirname mktemp chmod; do
    [ "$tool" != "$drop" ] || continue
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$dir/$tool"
  done
  printf '%s' "$dir"
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

  # Asking the captain consumed that load, so the steer route needs its own.
  # Without this deny the reload below would prove nothing: the case would pass
  # identically whether or not the ask route consumes.
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'go with option 2'"
  assert_denied 'steering on the load the ask route already spent' 'rac196 [key=title-fallback]'

  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'go with option 2'"
  assert_allowed_silently 'steering the worker after loading the skill for this finding'

  pass "a skill load made after the finding appeared satisfies either route"
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
  else
    # chmod 000 does not stop root, so this case cannot be exercised here. Say so
    # out loud: a case that silently asserts nothing is worse than no case,
    # because the green is what the next reader trusts.
    printf 'skip - unreadable transcript: running as a user chmod 000 cannot block (uid %s)\n' "$(id -u)"
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

  # A status file that is not readable at all must not gate anything. Every
  # fresh-home case below runs its own baseline first, so an allow after the
  # mutation proves the fail-safe rather than proving the fixture never denied.
  local blind="$TMP_ROOT/blindstate"
  make_primary_home "$blind" >/dev/null
  printf 'needs-decision [key=k]: open question\n' > "$blind/state/rac196.status"
  run_guard "$blind" "$transcript" AskUserQuestion
  assert_denied 'the unreadable-status-file baseline' 'rac196 [key=k]'
  chmod 000 "$blind/state/rac196.status"
  if [ ! -r "$blind/state/rac196.status" ]; then
    run_guard "$blind" "$transcript" AskUserQuestion
    assert_allowed_silently 'an unreadable status file'
  else
    printf 'skip - unreadable status file: running as a user chmod 000 cannot block (uid %s)\n' "$(id -u)"
  fi
  chmod 644 "$blind/state/rac196.status"

  # An unwritable state directory cannot hold the ledger, so it cannot prove
  # anything and must step aside.
  local rostate="$TMP_ROOT/rostate"
  make_primary_home "$rostate" >/dev/null
  printf 'needs-decision [key=k]: open question\n' > "$rostate/state/rac196.status"
  run_guard "$rostate" "$transcript" AskUserQuestion
  assert_denied 'the unwritable-state-directory baseline' 'rac196 [key=k]'
  rm -f "$rostate/state/.ask-user-authority-guard"
  chmod 555 "$rostate/state"
  if [ ! -w "$rostate/state" ]; then
    run_guard "$rostate" "$transcript" AskUserQuestion
    assert_allowed_silently 'an unwritable state directory'
  else
    printf 'skip - unwritable state directory: running as a user chmod 555 cannot block (uid %s)\n' "$(id -u)"
  fi
  chmod 755 "$rostate/state"

  # A state directory that cannot even be read is the other half of the same
  # bullet: the guard cannot enumerate the status files it gates on.
  local nostate="$TMP_ROOT/nostate"
  make_primary_home "$nostate" >/dev/null
  printf 'needs-decision [key=k]: open question\n' > "$nostate/state/rac196.status"
  run_guard "$nostate" "$transcript" AskUserQuestion
  assert_denied 'the unreadable-state-directory baseline' 'rac196 [key=k]'
  chmod 000 "$nostate/state"
  if [ ! -r "$nostate/state" ]; then
    run_guard "$nostate" "$transcript" AskUserQuestion
    assert_allowed_silently 'an unreadable state directory'
  else
    printf 'skip - unreadable state directory: running as a user chmod 000 cannot block (uid %s)\n' "$(id -u)"
  fi
  chmod 755 "$nostate/state"

  # An unreadable ledger. The guard allows either way, but the fail-safe rule is
  # allow AND stay silent, and stderr is the channel Claude reads hook output on.
  local noledger noledger_ledger
  noledger=$(make_primary_home "$TMP_ROOT/noledger")
  noledger_ledger="$noledger/state/.ask-user-authority-guard"
  printf 'needs-decision [key=k]: open question\n' > "$noledger/state/rac196.status"
  run_guard "$noledger" "$transcript" AskUserQuestion
  assert_denied 'the unreadable-ledger baseline' 'rac196 [key=k]'
  run_guard "$noledger" "$transcript" Read
  [ -f "$noledger_ledger" ] || fail 'the unreadable-ledger case needs an observation pass to write a ledger first'
  chmod 000 "$noledger_ledger"
  if [ ! -r "$noledger_ledger" ]; then
    run_guard "$noledger" "$transcript" Read
    assert_allowed_silently 'an unreadable ledger'
  else
    printf 'skip - unreadable ledger: running as a user chmod 000 cannot block (uid %s)\n' "$(id -u)"
  fi
  chmod 644 "$noledger_ledger"

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
  run_guard "$nolib" "$transcript" AskUserQuestion
  assert_denied 'the missing-classify-library baseline' 'rac196 [key=k]'
  rm -f "$nolib/bin/fm-classify-lib.sh"
  run_guard "$nolib" "$transcript" AskUserQuestion
  assert_allowed_silently 'a missing classify library'

  # Missing primary-scope library: the shared scope predicate is gone, so the
  # guard cannot even tell whether this home is in scope.
  local noscope="$TMP_ROOT/noscope"
  make_primary_home "$noscope" >/dev/null
  printf 'needs-decision [key=k]: open question\n' > "$noscope/state/rac196.status"
  run_guard "$noscope" "$transcript" AskUserQuestion
  assert_denied 'the missing-scope-library baseline' 'rac196 [key=k]'
  rm -f "$noscope/bin/fm-primary-scope-lib.sh"
  run_guard "$noscope" "$transcript" AskUserQuestion
  assert_allowed_silently 'a missing primary-scope library'

  # Missing jq: the stdin transport cannot extract the tool name at all.
  local nojq nojq_path
  nojq=$(make_primary_home "$TMP_ROOT/nojq")
  printf 'needs-decision [key=k]: open question\n' > "$nojq/state/rac196.status"
  run_guard "$nojq" "$transcript" AskUserQuestion
  assert_denied 'the missing-jq baseline' 'rac196 [key=k]'
  nojq_path=$(path_without jq)
  run_guard "$nojq" "$transcript" AskUserQuestion '' "$nojq_path"
  assert_allowed_silently 'a missing jq'

  # Missing Node: the steer classifier cannot run, so the steer route stands
  # down. The ask route needs no classifier and stays gated, which is what makes
  # this a scoped disarm rather than a whole-guard one.
  local nonode nonode_path
  nonode=$(make_primary_home "$TMP_ROOT/nonode")
  printf 'needs-decision [key=k]: open question\n' > "$nonode/state/rac196.status"
  run_guard "$nonode" "$transcript" Bash "$nonode/bin/fm-send.sh rac196 ok"
  assert_denied 'the missing-node baseline' 'rac196 [key=k]'
  nonode_path=$(path_without node)
  run_guard "$nonode" "$transcript" Bash "$nonode/bin/fm-send.sh rac196 ok" "$nonode_path"
  assert_allowed_silently 'a steer with no Node runtime'
  run_guard "$nonode" "$transcript" AskUserQuestion '' "$nonode_path"
  assert_denied 'asking the captain with no Node runtime' 'rac196 [key=k]'

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

# Running out of re-lexing recursion is the same situation as syntax the lexer
# cannot tokenize: the bytes are readable and the walk has simply stopped. The
# bound must escalate like every other unplaceable case rather than becoming the
# one hole in the rule, and it must not drag ordinary inspection in with it -
# which it cannot, because a simple command is decided before any recursion.
test_deep_nesting_past_the_bound_denies() {
  local home transcript cmd depth
  home=$(make_primary_home "$TMP_ROOT/deep-nesting")
  transcript="$TMP_ROOT/deep-nesting.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  for depth in 1 8 9 16; do
    cmd='bin/fm-send.sh rac196 ok'
    local i=0
    while [ "$i" -lt "$depth" ]; do
      cmd="( $cmd )"
      i=$((i + 1))
    done
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_denied "steer nested $depth deep" 'rac196 [key=k]'
  done

  # The bound is not selective, so inspection survives only BELOW it. These are
  # the depths docs/ask-user-guard.md claims are unaffected; past the bound the
  # same command denies, which the doc states rather than hiding.
  local wrapped
  for depth in 1 3 8; do
    cmd='cat bin/fm-send.sh'
    local j=0
    while [ "$j" -lt "$depth" ]; do
      cmd="( $cmd )"
      j=$((j + 1))
    done
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_allowed_silently "read-only inspection nested $depth deep"
  done

  wrapped='cat bin/fm-send.sh'
  local k=0
  while [ "$k" -lt 9 ]; do
    wrapped="( $wrapped )"
    k=$((k + 1))
  done
  run_guard "$home" "$transcript" Bash "$wrapped"
  assert_denied 'read-only inspection nested past the bound' 'rac196 [key=k]'

  pass "nesting past the recursion bound denies instead of allowing, and inspection below the bound is unaffected"
}

# Two sessions can be open on the same home, and each has its own first sight of
# the same finding. Keying a ledger row on the finding alone let the last writer
# revoke the other session's established position, so a load made genuinely in
# response to the finding stopped counting and the finding denied indefinitely.
# This walks the reported interleaving.
test_two_sessions_keep_their_own_first_sight() {
  local home s1 s2
  home=$(make_primary_home "$TMP_ROOT/two-sessions")
  s1="$TMP_ROOT/two-sessions-s1.jsonl"
  s2="$TMP_ROOT/two-sessions-s2.jsonl"
  transcript_noise "$s1" 'session one opens'
  transcript_noise "$s2" 'session two opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  # Both sessions observe the finding, s2 last.
  run_guard "$home" "$s1" Read
  assert_allowed_silently 'session one observing the finding'
  run_guard "$home" "$s2" Read
  assert_allowed_silently 'session two observing the finding'

  # Session one loads the skill in response to the finding it saw.
  transcript_tool_use "$s1" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$s1" AskUserQuestion
  assert_allowed_silently 'session one asking after loading for the finding'

  # Repeating denied indefinitely before the fix. A fresh load per decision is
  # the ordinary cost now, so what this asserts is that a load session one makes
  # still works - both on a bare retry and with the other session observing in
  # between, which is the interleaving that used to revoke session one's row.
  transcript_tool_use "$s1" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$s1" AskUserQuestion
  assert_allowed_silently 'session one asking again after its own fresh load'
  run_guard "$home" "$s2" Read
  assert_allowed_silently 'session two observing between session one retries'
  transcript_tool_use "$s1" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$s1" AskUserQuestion
  assert_allowed_silently 'session one asking after session two observed'

  # The per-finding gate still holds per session: session two never loaded it.
  run_guard "$home" "$s2" AskUserQuestion
  assert_denied 'session two asking without its own load' 'rac196 [key=k]'
  transcript_tool_use "$s2" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$s2" AskUserQuestion
  assert_allowed_silently 'session two asking after loading in its own transcript'

  # A row whose transcript is gone is pruned, so a per-session ledger stays
  # bounded. The ledger is this guard's own documented on-disk format
  # (docs/ask-user-guard.md), which is why reading it here is the contract rather
  # than a proxy.
  rm -f "$s2"
  printf 'needs-decision [key=k2]: second question\n' >> "$home/state/rac196.status"
  run_guard "$home" "$s1" Read
  assert_allowed_silently 'session one observing after session two vanished'
  if grep -q "$s2" "$home/state/.ask-user-authority-guard"; then
    fail 'a row whose transcript no longer exists must be pruned'
  fi

  pass "two sessions in one home each keep their own first sight, and dead rows are pruned"
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

# This case is about a finding that lands AFTER a load, on a different task: it
# pins the cross-task reach of the gate, not the batch shape. The batch shape -
# several findings already open when the load happens - is
# test_one_load_does_not_cover_a_whole_batch below.
test_a_later_finding_on_another_task_regates_both_routes() {
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

  pass "a finding landing later on any task in the home re-gates both routes"
}

# The batch shape is the normal morning: several crewmates raise findings while
# firstmate is away, so it wakes to three or four open at once. Proof of load is
# consumed by the call it permits, so one load buys exactly one decision and the
# next finding in the same batch needs its own - otherwise findings 2..N get no
# reconstruction at all, which is the reported failure compressed into one wake.
test_one_load_does_not_cover_a_whole_batch() {
  local home transcript
  home=$(make_primary_home "$TMP_ROOT/batch")
  transcript="$TMP_ROOT/batch.jsonl"
  transcript_noise "$transcript" 'session opens'

  # Both findings are already open at the same moment.
  printf 'needs-decision [key=a]: first question\n' > "$home/state/rac196.status"
  printf 'needs-decision [key=b]: second question\n' > "$home/state/rac197.status"
  run_guard "$home" "$transcript" Read
  assert_allowed_silently 'ungated call stamping both findings'
  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'asking before any load' 'rac196 [key=a]'

  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'deciding the first finding of the batch'

  # The load is spent. Reusing it for the rest of the batch is the whole bug.
  run_guard "$home" "$transcript" AskUserQuestion
  assert_denied 'reusing one load for the rest of the batch' 'rac196 [key=a]'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac197 ok"
  assert_denied 'steering on a spent load' 'rac197 [key=b]'

  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$transcript" AskUserQuestion
  assert_allowed_silently 'deciding the second finding after its own load'

  pass "one load buys one decision; the rest of the batch needs its own loads"
}

# The steer route deliberately does not consume, so one load covers the whole
# stretch a finding stays open. bin/fm-send.sh is also firstmate's ordinary fleet
# transport, and every attempt to tell a decision delivery from a nudge cost more
# in wrong denies than the batch property was worth here: a repeated nudge, a
# stuck-crewmate interrupt-then-correct pair, and read-only diagnosis in between
# all have to keep working on that one load. The steer is still GATED, which is
# what the first assertion pins.
test_an_allowed_steer_does_not_spend_the_load() {
  local home transcript cmd
  home=$(make_primary_home "$TMP_ROOT/steer-no-consume")
  transcript="$TMP_ROOT/steer-no-consume.jsonl"
  transcript_noise "$transcript" 'session opens'
  printf 'needs-decision [key=k]: open question\n' > "$home/state/rac196.status"

  run_guard "$home" "$transcript" Read
  assert_allowed_silently 'ungated call stamping the finding'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'go with option 2'"
  assert_denied 'steering before any load' 'rac196 [key=k]'

  transcript_tool_use "$transcript" Skill '{"skill":"ask-user-authority"}'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'go with option 2'"
  assert_allowed_silently 'steering after loading for the finding'

  # Repeats, other targets, and the recovery sequence all ride the same load.
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'and one more thing'"
  assert_allowed_silently 'steering the same task again'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac197 're-read AGENTS.md'"
  assert_allowed_silently 'nudging an unrelated task'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac197 --key Escape"
  assert_allowed_silently 'interrupting an unrelated worker'
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac197 'use the brief answer'"
  assert_allowed_silently 'following the interrupt with a corrective line'

  # Read-only diagnosis in the escalation class does not spend it either, which
  # is the sequence that exposed the round-6 behavior.
  # shellcheck disable=SC2016 # the classifier, not this test shell, reads these commands
  for cmd in \
    'if [ -f bin/fm-send.sh ]; then echo yes; fi' \
    'if [ -f bin/fm-send.sh ]; then echo yes; fi' \
    'nice cat bin/fm-send.sh' \
    'for f in bin/fm-send.sh; do cat $f; done'
  do
    run_guard "$home" "$transcript" Bash "$cmd"
    assert_allowed_silently "read-only diagnosis <$cmd>"
  done

  # Still gated, still on one load: the finding is untouched by any of that.
  run_guard "$home" "$transcript" Bash "$home/bin/fm-send.sh rac196 'final word'"
  assert_allowed_silently 'steering again after the diagnosis run'

  pass "an allowed steer spends no proof, so one load covers repeats, nudges, and diagnosis"
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
test_deep_nesting_past_the_bound_denies
test_two_sessions_keep_their_own_first_sight
test_missing_steer_classifier_allows_silently
test_escape_hatch_allows
test_a_later_finding_on_another_task_regates_both_routes
test_one_load_does_not_cover_a_whole_batch
test_an_allowed_steer_does_not_spend_the_load
test_claude_hook_is_wired
