#!/usr/bin/env bash
# shellcheck disable=SC1091
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-push-pretool-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-push-guard.XXXXXX") || fail "could not create a temp dir"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
STDERR_FILE="$TMP_ROOT/stderr"

# Claude Code honours a deny only while stdout stays empty, so --claude never writes stdout.
check_cmd() {
  local expected=$1 cmd=$2 out err code
  out=$("$GUARD" --claude --command "$cmd" 2>"$STDERR_FILE"); code=$?
  err=$(cat "$STDERR_FILE")
  expect_code "$expected" "$code" "$cmd"
  [ -z "$out" ] || fail "$cmd: --claude writes nothing to stdout"
  if [ "$expected" -eq 0 ]; then
    [ -z "$err" ] || fail "an allowed command has no output"
  else
    assert_contains "$err" "[push-guard] refusing:" "a refused command explains why"
  fi
}

# Use installed spellings, treating case and UTF-8/utf8 aliases as the same locale.
caller_lang=${LANG:-}
caller_lc_all=${LC_ALL:-}
test_locales=$(LC_ALL=C locale -a | LC_ALL=C awk \
  -v wanted_lang="$caller_lang" -v wanted_all="$caller_lc_all" '
  function key(s) { s = tolower(s); gsub(/utf-8/, "utf8", s); return s }
  { installed[key($0)] = $0 }
  END {
    candidates[1] = "C"; candidates[2] = "en_US.UTF-8"
    candidates[3] = wanted_lang; candidates[4] = wanted_all
    for (i = 1; i <= 4; i++) {
      k = key(candidates[i])
      name = k == "c" ? "C" : installed[k]
      if (name != "" && !seen[k]++) { printf "%s%s", sep, name; sep = " " }
    }
    print ""
  }') || fail "could not select test locales"
printf 'test locales: %s\n' "$test_locales"

# Commands are data, never executed. @NL@ represents a literal newline in a table row.
for test_locale in $test_locales; do
  while IFS='|' read -r expected cmd; do
    cmd=${cmd//@NL@/$'\n'}
    LC_ALL="$test_locale" check_cmd "$expected" "$cmd"
  done <<'CASES'
0|fm-spawn.sh task repo --mode no-mistakes --yolo off
0|fm-spawn.sh task repo --mode direct-PR --yolo off
0|fm-brief.sh task repo --mode no-mistakes --checks full
0|no-mistakes axi run --intent 'ship it'
0|no-mistakes axi run --skip review
0|gh-axi pr create --title x
0|gh-axi pr merge 12
0|gh-axi pr revert 12
0|bin/fm-pr-merge.sh task https://github.com/o/r/pull/12
0|gh-axi workflow run test
0|gh-axi run rerun 1
0|git push origin fm/task-branch
0|git push -u origin fm/task-branch
0|git push --set-upstream origin HEAD:fm/task-branch
0|git push origin HEAD:refs/heads/fm/task-branch
0|git push origin fm/one fm/two
0|git push -o ci.skip origin fm/task-branch
0|git push --no-verify origin fm/task-branch
0|git push no-mistakes fm/task-branch
0|git push origin main
0|echo 'a — b →' ; git push origin main
0|git push origin master
0|git push origin HEAD:main
0|git push origin main fm/task-branch
0|git -C dir push origin main
0|git -Cdir push origin fm/task-branch
0|(cd repo && git push origin main)
0|git push origin main 2>&1 | tail -3
0|git push origin main >file
0|git push origin >file main
0|git push --set-upstream -q --quiet -v --verbose --dry-run -n origin main
0|git push
0|git push origin
0|git push origin HEAD
0|git push -u origin HEAD
0|git --no-pager push origin fm/task-branch
0|git push -ofoo origin fm/task-branch
0|git push --push-option=ci.skip origin fm/task-branch
0|git push -- origin fm/task-branch
0|git push --se origin fm/task-branch
0|legit push -f origin fm/task-branch
0|git -c core.x=1 status
0|git status; echo push
0|'git' "push" origin feature
2|git push -f origin fm/task-branch
2|git push --force origin fm/task-branch
2|git push --force-with-lease origin fm/task-branch
2|git push --force-with-lease=fm/x origin fm/x
2|git push --force-if-includes origin fm/task-branch
2|git push -uf origin fm/task-branch
2|git push -fu origin fm/task-branch
2|git push origin +fm/task-branch
2|git push origin +HEAD:fm/task-branch
2|git push -f origin main
2|git push --force origin main
2|git push origin +HEAD:main
2|git push origin :fm/task-branch
2|git push origin :main
2|git push --delete origin fm/task-branch
2|git push -d origin fm/task-branch
2|git push origin fm/task-branch --delete
2|git push --prune origin fm/task-branch
2|git push --mirror origin
2|git push --mir origin
2|git push --del origin fm/task-branch
2|git push --dele origin fm/task-branch
2|git push --force-w origin fm/task-branch
2|git push --force-wi=fm/x origin fm/x
2|git push --force-if origin fm/task-branch
2|git push --forc origin fm/task-branch
2|git push --pru origin fm/task-branch
2|/usr/bin/git push -f origin fm/task-branch
2|./git push --delete origin fm/task-branch
2|git push --no-verify origin HEAD:heads/main
2|git push --no-verify origin heads/master
2|git push --no-verify -o x origin
2|git push --no-verify -uo x origin
2|git push --no-verify --push-option x origin
2|git push --no-verify --push-opt x origin
2|git push --no-verify --repo x origin
2|git push --no-verify --receive-pack x origin
2|git push --no-verify --exec x origin
2|git push --no-verify --recurse-submodules check origin
2|git -c core.x=1 push origin fm/task-branch
2|git -ccore.x=1 push origin fm/task-branch
2|git --config-env=core.x=X push origin fm/task-branch
2|git push --no-verify origin main
2|git push --unknown origin main
2|git push --tags origin main
2|git push origin main --tags
2|git push --all origin
2|git push --branches origin
2|git push --no-verify origin @
2|git push --follow-tags origin main
2|git push origin refs/tags/v1:main
2|git push --no-verify origin 'refs/heads/*:refs/heads/*'
2|git push --no-verify
2|git push --no-verify origin
2|git push --no-verify origin HEAD
2|git push --no-verify origin fm/x HEAD:refs/heads/master
2|git push origin fm/x; git push -f origin fm/y
2|git push origin fm/x && git push --delete origin fm/y
2|git push origin fm/x@NL@git push -f origin fm/y
2|bash -c "git push -f origin fm/x"
2|sh <<'EOF'@NL@git push --force origin fm/x@NL@EOF
2|echo $(git push --delete origin fm/x)
2|'git' "push" -f origin fm/x
2|g\it pu\sh -f origin fm/x
2|git commit -m 'git push --force origin feature'
2|grep 'git push -f origin feature' file
CASES
done
pass "command verdict table"

for key in tool_input toolInput; do
  out=$(jq -n --arg key "$key" '{($key):{command:"git push origin fm/task-branch"},cwd:"/missing/repo"}' |
    "$GUARD" --claude 2>&1); code=$?
  expect_code 0 "$code" "$key payload accepts a task-branch push regardless of cwd"
  [ -z "$out" ] || fail "allowed payload has no output"
  out=$(jq -n --arg key "$key" '{($key):{command:"git push --force origin fm/task-branch"}}' |
    "$GUARD" 2>/dev/null); code=$?
  expect_code 2 "$code" "$key payload refuses a force push"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null ||
    fail "$key payload deny emits the stdout deny object without --claude"
done
pass "both hook payload formats are read and the deny object is emitted"
