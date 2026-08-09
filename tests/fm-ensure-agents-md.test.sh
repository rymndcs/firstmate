#!/usr/bin/env bash
# Behavior tests for bin/fm-ensure-agents-md.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md)

assert_correct_pair() {
  local repo=$1
  [ -f "$repo/CLAUDE.md" ] || fail "CLAUDE.md is not a regular file"
  [ ! -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md must not be a symlink"
  [ -L "$repo/AGENTS.md" ] || fail "AGENTS.md is not a symlink"
  [ "$(readlink "$repo/AGENTS.md")" = "CLAUDE.md" ] || fail "AGENTS.md does not point literally to CLAUDE.md"
}

test_empty_project_creates_claude_md_with_self_governance() {
  local repo claude
  repo="$TMP_ROOT/new-project"
  mkdir -p "$repo"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for empty project"
  claude="$repo/CLAUDE.md"
  assert_correct_pair "$repo"
  assert_grep "## Maintaining this file" "$claude" "self-governance section heading missing"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$claude" \
    "self-governance section lost the future-session bar"
  assert_grep "Do not repeat what the codebase already shows; point to the authoritative file or command instead." "$claude" \
    "self-governance section lost pointer-over-copy guidance"
  assert_grep "Prefer rewriting or pruning existing entries over appending new ones." "$claude" \
    "self-governance section lost rewrite-or-prune guidance"
  assert_grep "When updating this file, preserve this bar for all agents and keep entries concise." "$claude" \
    "self-governance section lost all-agents maintenance guidance"
  pass "fm-ensure-agents-md.sh: empty project creates real CLAUDE.md and AGENTS.md symlink"
}

test_only_claude_md_gains_symlink_and_self_governance() {
  local repo claude count
  repo="$TMP_ROOT/claude-project"
  mkdir -p "$repo"
  cat > "$repo/CLAUDE.md" <<'EOF'
# Existing agent memory

Run tests with `make test`.
EOF
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for lone CLAUDE.md"
  claude="$repo/CLAUDE.md"
  assert_correct_pair "$repo"
  assert_grep "Run tests with \`make test\`." "$claude" "existing CLAUDE.md content was lost"
  count=$(grep -Fc "## Maintaining this file" "$claude")
  [ "$count" -eq 1 ] || fail "CLAUDE.md has $count self-governance sections"
  pass "fm-ensure-agents-md.sh: lone CLAUDE.md gains the symlink and section"
}

test_only_agents_md_is_promoted() {
  local repo claude out count
  repo="$TMP_ROOT/agents-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nDeploy with kubectl.\n' > "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed promoting lone AGENTS.md"
  claude="$repo/CLAUDE.md"
  assert_contains "$out" "promoted:" "lone AGENTS.md did not report promotion"
  assert_correct_pair "$repo"
  assert_grep "Deploy with kubectl." "$claude" "promotion lost existing AGENTS.md content"
  count=$(grep -Fc "## Maintaining this file" "$claude")
  [ "$count" -eq 1 ] || fail "promotion wrote $count self-governance sections"
  pass "fm-ensure-agents-md.sh: lone AGENTS.md is promoted to real CLAUDE.md"
}

test_legacy_pair_is_reversed() {
  local repo out
  repo="$TMP_ROOT/legacy-pair-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nBuild with make.\n' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed reversing the legacy pair"
  assert_contains "$out" "promoted:" "legacy pair did not report promotion"
  assert_correct_pair "$repo"
  assert_grep "Build with make." "$repo/CLAUDE.md" "legacy-pair reversal lost content"
  pass "fm-ensure-agents-md.sh: legacy symlink direction is reversed"
}

test_already_correct_pair_is_idempotent() {
  local repo out
  repo="$TMP_ROOT/correct-pair-project"
  mkdir -p "$repo"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed building the correct fixture"
  cp "$repo/CLAUDE.md" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on an already-correct pair"
  assert_contains "$out" "unchanged:" "already-correct pair was not reported unchanged"
  cmp -s "$repo/.before" "$repo/CLAUDE.md" || fail "idempotent re-run modified CLAUDE.md"
  assert_correct_pair "$repo"
  pass "fm-ensure-agents-md.sh: already-correct pair stays unchanged"
}

test_claude_md_without_trailing_newline_keeps_blank_separator() {
  local repo before
  repo="$TMP_ROOT/no-trailing-newline-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nRun tests with make test.' > "$repo/CLAUDE.md"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for newline-less CLAUDE.md"
  assert_grep "Run tests with make test." "$repo/CLAUDE.md" "newline-less CLAUDE.md content was mangled"
  before=$(grep -B1 -Fx '## Maintaining this file' "$repo/CLAUDE.md" | head -n 1)
  [ -z "$before" ] || fail "self-governance heading not preceded by a blank line (got: $before)"
  pass "fm-ensure-agents-md.sh: newline-less CLAUDE.md keeps a blank separator line"
}

test_existing_crlf_claude_md_with_section_stays_unchanged() {
  local repo out count
  repo="$TMP_ROOT/crlf-formed-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/CLAUDE.md"
  ln -s CLAUDE.md "$repo/AGENTS.md"
  cp "$repo/CLAUDE.md" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on complete CRLF CLAUDE.md"
  assert_contains "$out" "unchanged:" "complete CRLF CLAUDE.md was not reported unchanged"
  cmp -s "$repo/.before" "$repo/CLAUDE.md" || fail "complete CRLF CLAUDE.md was modified"
  count=$(LC_ALL=C grep -a -c '## Maintaining this file' "$repo/CLAUDE.md")
  [ "$count" -eq 1 ] || fail "complete CRLF CLAUDE.md has $count self-governance sections"
  pass "fm-ensure-agents-md.sh: complete CRLF CLAUDE.md stays unchanged"
}

test_existing_crlf_claude_md_without_section_preserves_crlf() {
  local repo out
  repo="$TMP_ROOT/crlf-injected-project"
  mkdir -p "$repo"
  printf '%s\r\n' '# Existing agent memory' '' 'Run tests with make test.' > "$repo/CLAUDE.md"
  ln -s CLAUDE.md "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed injecting into CRLF CLAUDE.md"
  assert_contains "$out" "updated:" "CRLF CLAUDE.md injection did not report an update"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/.expected"
  cmp -s "$repo/.expected" "$repo/CLAUDE.md" || fail "CRLF injection did not preserve line endings"
  cp "$repo/CLAUDE.md" "$repo/.after-first"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed on idempotent CRLF re-run"
  cmp -s "$repo/.after-first" "$repo/CLAUDE.md" || fail "idempotent CRLF re-run modified CLAUDE.md"
  pass "fm-ensure-agents-md.sh: CRLF injection preserves line endings idempotently"
}

test_both_real_files_conflict() {
  local repo out rc
  repo="$TMP_ROOT/both-real-project"
  mkdir -p "$repo"
  printf '# Claude memory\n' > "$repo/CLAUDE.md"
  printf '# Agents memory\n' > "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when both files are real"
  assert_contains "$out" "both AGENTS.md and CLAUDE.md are real files" "both-real conflict was not explained"
  pass "fm-ensure-agents-md.sh: distinct real files conflict"
}

test_lowercase_agents_md_refuses_case_fragile_name() {
  local repo out rc
  repo="$TMP_ROOT/lowercase-agents-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/agents.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for lowercase agents.md"
  assert_contains "$out" "conflict:" "lowercase agents.md did not report a conflict"
  assert_contains "$out" "agents.md" "conflict did not name lowercase agents.md"
  assert_absent "$repo/CLAUDE.md" "CLAUDE.md was created beside lowercase agents.md"
  pass "fm-ensure-agents-md.sh: refuses lowercase agents.md"
}

test_lowercase_claude_md_refuses_case_fragile_name() {
  local repo out rc
  repo="$TMP_ROOT/lowercase-claude-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/claude.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for lowercase claude.md"
  assert_contains "$out" "conflict:" "lowercase claude.md did not report a conflict"
  assert_contains "$out" "claude.md" "conflict did not name lowercase claude.md"
  assert_absent "$repo/AGENTS.md" "AGENTS.md was created pointing at lowercase claude.md"
  pass "fm-ensure-agents-md.sh: refuses lowercase claude.md"
}

test_empty_project_creates_claude_md_with_self_governance
test_only_claude_md_gains_symlink_and_self_governance
test_only_agents_md_is_promoted
test_legacy_pair_is_reversed
test_already_correct_pair_is_idempotent
test_claude_md_without_trailing_newline_keeps_blank_separator
test_existing_crlf_claude_md_with_section_stays_unchanged
test_existing_crlf_claude_md_without_section_preserves_crlf
test_both_real_files_conflict
test_lowercase_agents_md_refuses_case_fragile_name
test_lowercase_claude_md_refuses_case_fragile_name
