#!/usr/bin/env bash
# shellcheck disable=SC1091
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-delivery-mode-pretool-check.sh"

check_cmd() {
  local expected=$1 cmd=$2 out code
  out=$("$GUARD" --claude --command "$cmd" 2>&1); code=$?
  expect_code "$expected" "$code" "$cmd"
  if [ "$expected" -eq 0 ]; then
    [ -z "$out" ] || fail "an allowed command has no output"
  else
    assert_contains "$out" "[no-github] refusing:" "a refused command explains why"
  fi
}

test_allowed_branches() {
  local branch
  for branch in main master; do
    check_cmd 0 "git push origin $branch"
    check_cmd 0 "git push origin HEAD:$branch"
    check_cmd 0 "git -C /missing/repo push origin $branch"
    check_cmd 0 "git push -u origin $branch 2>&1 | tail -3"
  done
  check_cmd 0 "git push origin main master"
  pass "main and master are allowed without repository detection"
}

test_other_refs_refused() {
  check_cmd 2 "git push origin fm/feature"
  check_cmd 2 "git push origin main fm/feature"
  check_cmd 2 "git push origin master HEAD:develop"
  check_cmd 2 "git push origin refs/tags/v1"
  pass "every named destination must be main or master"
}

test_forced_and_bare_pushes_refused() {
  local branch flag
  for branch in main master; do
    for flag in -f --force --force-with-lease --force-with-lease=main --force-if-includes; do
      check_cmd 2 "git push $flag origin $branch"
    done
    check_cmd 2 "git push origin +HEAD:$branch"
  done
  check_cmd 2 "git push"
  check_cmd 2 "git push origin"
  pass "forced and bare pushes stay refused"
}

test_subshell_pushes_allowed() {
  local branch
  for branch in main master; do
    check_cmd 0 "(cd /missing/repo && git push origin $branch)"
  done
  pass "a closing subshell parenthesis is not part of the refspec"
}

test_payload_entrypoints() {
  local key out code
  for key in tool_input toolInput; do
    out=$(jq -n --arg key "$key" '{($key):{command:"git push origin master"},cwd:"/missing/repo"}' |
      "$GUARD" --claude 2>&1); code=$?
    expect_code 0 "$code" "$key payload accepts master regardless of cwd"
    [ -z "$out" ] || fail "allowed payload has no output"
  done
  pass "both hook payload formats accept master"
}

test_allowed_branches
test_other_refs_refused
test_forced_and_bare_pushes_refused
test_subshell_pushes_allowed
test_payload_entrypoints
