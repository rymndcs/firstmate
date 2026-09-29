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
0|git push origin main
0|echo 'a — b →' ; git push origin main
0|git push origin master
0|git push origin HEAD:main
0|git push origin HEAD:master
0|git push origin main master
0|git -C dir push origin main
0|git -Cdir push origin main
0|(cd repo && git push origin main)
0|git push origin main 2>&1 | tail -3
0|git push origin main >file
0|git push origin main 2>/dev/null
0|git push origin >file main
0|git push -u origin main
0|git push --set-upstream -q --quiet -v --verbose --dry-run -n origin main
0|git -c core.x=1 status
0|git status; echo push
0|git status && echo push
0|git status || echo push
0|git status | echo push
0|git status & echo push
0|git status@NL@echo push
0|git status) echo push
0|'git' "push" origin 'main'
0|git push origin main; git push origin master
2|git push origin feature
2|echo 'a — b →' ; git push origin feature
2|git push origin main feature
2|git push origin HEAD:develop
2|git push origin main2>&1
2|git push origin HEAD:main2>/dev/null
2|git push origin :main
2|git push origin :master
2|git push --delete origin main
2|git push -d origin master
2|git push origin main --delete
2|git push --tags origin main
2|git push --all origin main
2|git push --mirror origin main
2|git push --follow-tags origin main
2|git push --prune origin main
2|git push origin main --tags
2|git push origin refs/tags/v1
2|git push origin refs/tags/v1:main
2|git push origin tag main
2|git push origin feature; git push origin main
2|git push origin feature && git push origin main
2|git push origin feature || git push origin main
2|git push origin feature | git push origin main
2|git push origin feature & git push origin main
2|git push origin feature@NL@git push origin main
2|git push origin main; git push origin feature
2|bash -c "git push origin feature"
2|sh -c 'git push origin feature'
2|zsh -c 'git push origin feature'
2|sh <<'EOF'@NL@git push origin feature@NL@EOF
2|eval 'git push origin feature'
2|echo $(git push origin feature)
2|echo `git push origin feature`
2|'git' "push" origin feature
2|g\it pu\sh origin feature
2|git push -f origin main
2|git push --force origin main
2|git push --force-with-lease origin main
2|git push --force-with-lease=main origin main
2|git push --force-if-includes origin main
2|git push origin +HEAD:main
2|git push
2|git push origin
2|git -c core.x=1 push origin main
2|git -ccore.x=1 push origin main
2|git --config-env=core.x=X push origin main
2|git push --no-verify origin main
2|git push --unknown origin main
2|git push -uf origin main
2|git commit -m 'git push origin feature'
2|grep 'git push origin feature' file
0|fm-spawn.sh task --mode local-only
2|fm-spawn.sh task --mode no-mistakes
0|no-mistakes axi run --skip review,push,pr,ci,test
2|no-mistakes axi run --skip pr,ci
2|gh-axi pr create
2|gh-axi pr merge
2|gh-axi pr revert
2|gh-axi workflow run test
2|gh-axi run rerun 1
CASES
done
pass "command verdict table"

for key in tool_input toolInput; do
  out=$(jq -n --arg key "$key" '{($key):{command:"git push origin master"},cwd:"/missing/repo"}' |
    "$GUARD" --claude 2>&1); code=$?
  expect_code 0 "$code" "$key payload accepts master regardless of cwd"
  [ -z "$out" ] || fail "allowed payload has no output"
done
pass "both hook payload formats accept master"
