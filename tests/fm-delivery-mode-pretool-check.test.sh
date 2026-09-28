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
  check_cmd 0 'git push origin "main"'
  check_cmd 0 'git -C "/missing/my repo" push origin main'
  check_cmd 0 'git push origin 2>/dev/null main'
  check_cmd 0 'git push --porcelain --atomic origin main'
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

test_deletes_refused() {
  local branch flag
  for branch in main master; do
    check_cmd 2 "git push origin :$branch"
    for flag in --delete -d; do
      check_cmd 2 "git push $flag origin $branch"
      check_cmd 2 "git push origin $flag $branch"
    done
  done
  pass "trunk deletion is refused in refspec and option forms"
}

test_extra_refs_refused() {
  local flag
  for flag in --tags --all --mirror --follow-tags; do
    check_cmd 2 "git push $flag origin main"
    check_cmd 2 "git push origin main $flag"
  done
  check_cmd 2 "git push origin refs/tags/v1:main"
  check_cmd 2 "git push origin tag main"
  check_cmd 2 "git push --prune origin main"
  check_cmd 2 "git push --tag origin main"
  check_cmd 2 "git push -uf origin main"
  check_cmd 2 "git push -ud origin main"
  pass "options and tag refspecs cannot add refs to a trunk push"
}

test_every_push_checked() {
  local separator
  for separator in ';' '&&' '||' '|' $'\n'; do
    check_cmd 2 "git push origin feature $separator git push origin main"
    check_cmd 2 "git push origin main $separator git push origin feature"
    check_cmd 0 "git push origin main $separator git push origin master"
  done
  pass "every push in a compound command is checked"
}

test_shell_wrappers() {
  local shell quote
  for shell in bash sh zsh; do
    for quote in "'" '"'; do
      check_cmd 2 "$shell -c ${quote}git push origin feature${quote}"
      check_cmd 0 "$shell -c ${quote}git push origin main${quote}"
    done
  done
  check_cmd 2 'bash -lc "git -C /missing/repo push origin feature; git push origin main"'
  check_cmd 0 'bash -c "git push origin HEAD:main 2>&1 | tail"'
  check_cmd 2 "bash -c \"sh -c 'git push origin feature'\""
  check_cmd 2 'git push origin main 2>/dev/null feature'
  check_cmd 2 'git push origin main 2>&1; git push origin feature'
  pass "shell command strings receive the same push checks"
}

test_prose_allowed() {
  check_cmd 0 'git commit -m "git push origin feature"'
  check_cmd 0 "grep 'git push origin feature' README.md"
  check_cmd 0 'printf "%s\\n" "git push origin feature"'
  check_cmd 0 'echo "explain git push origin feature"'
  pass "quoted prose is not executed as a git invocation"
}

test_payload_entrypoints() {
  local key out code
  for key in tool_input toolInput; do
    out=$(jq -n --arg key "$key" '{($key):{command:"git push origin master"},cwd:"/missing/repo"}' |
      "$GUARD" --claude 2>&1); code=$?
    expect_code 0 "$code" "$key payload accepts master regardless of cwd"
    [ -z "$out" ] || fail "allowed payload has no output"
    out=$(jq -n --arg key "$key" '{($key):{command:"sh -c \"git push --tags origin main\""}}' |
      "$GUARD" --claude 2>&1); code=$?
    expect_code 2 "$code" "$key payload refuses a wrapped extra-ref push"
  done
  out=$("$GUARD" --command 'git push origin :main' 2>/dev/null); code=$?
  expect_code 2 "$code" "default hook mode denies deletes"
  [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] ||
    fail "default hook mode returns a structured deny"
  pass "both hook payload formats and denial output stay supported"
}

if [ "$#" -gt 0 ]; then
  "$@"
else
  test_allowed_branches
  test_other_refs_refused
  test_forced_and_bare_pushes_refused
  test_subshell_pushes_allowed
  test_payload_entrypoints
  test_deletes_refused
  test_extra_refs_refused
  test_every_push_checked
  test_shell_wrappers
  test_prose_allowed
fi
