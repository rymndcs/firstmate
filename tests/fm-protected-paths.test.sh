#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-protected-paths)
trap 'rm -rf "${TMP:?}"' EXIT
fm_git_identity
GATE="$ROOT/bin/fm-protected-paths.sh"

make_case() {
  C="$TMP/$1"
  HOME_DIR="$C/home"
  PROJ="$C/project"
  WT="$C/task"
  mkdir -p "$HOME_DIR/data/task-x1" "$HOME_DIR/state" "$C/fakebin"
  fm_git_init_commit "$PROJ"
  git -C "$PROJ" branch -M main
  mkdir -p "$PROJ/.claude/docs" "$PROJ/docs/solutions" "$PROJ/nested"
  printf 'original\n' > "$PROJ/CLAUDE.md"
  printf 'original\n' > "$PROJ/CONCEPTS.md"
  printf 'original\n' > "$PROJ/.claude/docs/system.md"
  git -C "$PROJ" add .
  git -C "$PROJ" commit -qm baseline
  git clone -q --bare "$PROJ" "$C/origin.git"
  git -C "$PROJ" remote add origin "$C/origin.git"
  git -C "$PROJ" fetch -q origin
  git -C "$PROJ" remote set-head origin main
  git -C "$PROJ" worktree add -qb fm/task-x1 "$WT"
  cat > "$C/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH" ;;
  *'#{window_id}'*) printf '@1\n' ;;
  display-message*) printf 'firstmate\n' ;;
  *) : ;;
esac
SH
  fm_fake_exit0 "$C/fakebin" treehouse sleep gh gh-axi
  chmod +x "$C/fakebin/tmux"
  printf 'Delivery contract: mode=direct-PR\n' > "$HOME_DIR/data/task-x1/brief.md"
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data"
  export FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  export FM_FAKE_PANE_PATH="$WT" FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0
}

spawn_task() {
  PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-spawn.sh" task-x1 "$PROJ" codex \
    --mode direct-PR --yolo off --captain-pick codex > "$C/spawn.log" 2>&1 \
    || fail "spawn failed: $(cat "$C/spawn.log")"
}

commit_change() {
  git -C "$WT" add -A
  git -C "$WT" commit -qm "$1"
}

refused_push() {
  if git -C "$WT" push origin "$@" > "$C/push.log" 2>&1; then
    fail 'unapproved protected change was pushed'
  fi
  assert_grep 'needs-decision [key=agent-file-approval]' "$C/push.log" 'push refusal must tell the worker to stop for approval'
}

approve() {
  printf '> Captain approved these exact paths.\n%s\n' "$1" > "$HOME_DIR/data/task-x1/agent-file-approval.md"
}

test_layer_one() {
  make_case layer-one
  spawn_task
  printf 'changed\n' >> "$WT/CLAUDE.md"
  commit_change change
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CLAUDE.md' "$C/push.log" 'must name protected path'
  if git -C "$C/origin.git" show-ref --verify --quiet refs/heads/fm/task-x1; then
    fail 'refused push reached remote'
  fi
  approve CLAUDE.md
  git -C "$WT" push -q origin HEAD:refs/heads/fm/task-x1 || fail 'approved path refused'
  printf 'changed\n' >> "$WT/CONCEPTS.md"
  commit_change partial
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CONCEPTS.md' "$C/push.log" 'partial approval must name unlisted path'
  assert_no_grep '  CLAUDE.md' "$C/push.log" 'partial approval must not name listed path'
  printf 'CLAUDE.md\nCONCEPTS.md\n' > "$HOME_DIR/data/task-x1/agent-file-approval.md"
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CLAUDE.md' "$C/push.log" 'approval without captain quotation must refuse'
  approve '*'
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CLAUDE.md' "$C/push.log" 'glob must not authorize a path'
  pass 'Layer 1 refuses unapproved and partially approved pushes, and accepts exact approval'
}

test_net_changes() {
  make_case restored
  spawn_task
  printf 'changed\n' >> "$WT/CLAUDE.md"
  commit_change change
  git -C "$PROJ" show main:CLAUDE.md > "$WT/CLAUDE.md"
  commit_change restore
  git -C "$WT" push -q origin HEAD:refs/heads/restored || fail 'restored path refused'
  git -C "$WT" rm -q CLAUDE.md
  commit_change delete
  refused_push HEAD:refs/heads/deleted
  assert_grep '  CLAUDE.md' "$C/push.log" 'base-existing deletion must be protected'
  pass 'net restoration passes; deleting a base-existing protected path refuses'
}

test_rename_and_case() {
  make_case rename
  spawn_task
  mkdir -p "$WT/nested"
  git -C "$WT" mv CLAUDE.md nested/aGeNtS.Md
  commit_change rename
  approve CLAUDE.md
  refused_push HEAD:refs/heads/renamed
  assert_grep '  nested/aGeNtS.Md' "$C/push.log" 'rename target must be approved'
  approve nested/aGeNtS.Md
  refused_push HEAD:refs/heads/renamed
  assert_grep '  CLAUDE.md' "$C/push.log" 'rename source must be approved'
  approve $'CLAUDE.md\nnested/aGeNtS.Md'
  git -C "$WT" push -q origin HEAD:refs/heads/renamed || fail 'approved rename refused'
  pass 'both rename paths and nested case variants are protected'
}

test_all_protected_paths_and_refs() {
  make_case paths
  spawn_task
  local path
  for path in nested/CLAUDE.md nested/CLAUDE.local.md nested/CONCEPTS.md .CoDeX/tool .claude/new docs/SoLuTiOnS/new; do
    mkdir -p "$WT/$(dirname "$path")"
    printf 'instructions\n' > "$WT/$path"
  done
  commit_change paths
  refused_push main:refs/heads/clean HEAD:refs/heads/changed
  for path in nested/CLAUDE.md nested/CLAUDE.local.md nested/CONCEPTS.md .CoDeX/tool .claude/new docs/SoLuTiOnS/new; do
    assert_contains "$(cat "$C/push.log")" "  $path" 'case-insensitive protected path missing'
  done
  git -C "$WT" tag probe
  git -C "$WT" push -q origin refs/tags/probe || fail 'tag push should not be gated'
  git -C "$PROJ" push -q origin main:refs/heads/disposable
  git -C "$WT" push -q origin :refs/heads/disposable || fail 'branch deletion should not be gated'
  pass 'all protected path classes and every pushed branch are checked; tags and deletions pass'
}

test_existing_hooks_and_unmarked_pushes() {
  make_case hooks
  local hooks before
  hooks="$PROJ/.git/hooks"
  printf '#!/bin/sh\nprintf "project-commit\\n" >> "%s"\n' "$C/project-hook.log" > "$hooks/post-commit"
  printf '#!/bin/sh\nprintf "project-merge\\n" >> "%s"\n' "$C/project-hook.log" > "$hooks/post-merge"
  printf '#!/bin/sh\nprintf "project-push %%s\\n" "$*" >> "%s"\ncat >> "%s"\n' "$C/project-hook.log" "$C/project-hook-input" > "$hooks/pre-push"
  chmod +x "$hooks/post-commit" "$hooks/post-merge" "$hooks/pre-push"
  before=$(shasum "$hooks/post-commit" "$hooks/post-merge")
  spawn_task
  spawn_task
  [ "$before" = "$(shasum "$hooks/post-commit" "$hooks/post-merge")" ] || fail 'existing commit/merge hooks changed'
  printf 'changed\n' >> "$WT/CLAUDE.md"
  commit_change change
  assert_grep project-commit "$C/project-hook.log" 'post-commit did not fire'
  refused_push HEAD:refs/heads/protected
  git -C "$PROJ" push -q origin fm/task-x1:refs/heads/captain || fail 'captain checkout was gated'
  git -C "$PROJ" worktree add -q --detach "$C/unmarked" fm/task-x1
  git -C "$C/unmarked" push -q origin HEAD:refs/heads/unmarked || fail 'marker-less worktree was gated'
  assert_grep 'project-push origin ' "$C/project-hook.log" 'existing pre-push was not chained'
  assert_grep 'refs/heads/unmarked' "$C/project-hook-input" 'existing pre-push lost stdin'
  printf '#!/bin/sh\nexit 41\n' > "$hooks/pre-push.firstmate-original"
  if git -C "$PROJ" push origin fm/task-x1:refs/heads/project-refuses > "$C/push.log" 2>&1; then
    fail 'existing pre-push refusal was ignored'
  fi
  git -C "$PROJ" merge -q --ff-only fm/task-x1
  assert_grep project-merge "$C/project-hook.log" 'post-merge did not fire'
  [ -z "$(git -C "$PROJ" config --get core.hooksPath || true)" ] || fail 'installer changed core.hooksPath'
  [ -z "$(git -C "$PROJ" config --get extensions.worktreeConfig || true)" ] || fail 'installer enabled worktreeConfig'
  pass 'installation is idempotent, chains pre-push, preserves other hooks, and only gates marked working copies'
}

test_exempt_project() {
  make_case exempt
  mkdir -p "$HOME_DIR/projects"
  ln -s "$PROJ" "$HOME_DIR/projects/ai-workspace"
  printf '%s\n' '- ai-workspace [no-mistakes] - own home' > "$HOME_DIR/data/projects.md"
  spawn_task
  printf 'changed\n' >> "$WT/CLAUDE.md"
  commit_change exempt
  git -C "$WT" push -q origin HEAD:refs/heads/exempt || fail 'registered exempt project was gated'
  make_case named-ai-workspace
  mv "$PROJ" "$C/ai-workspace"
  PROJ="$C/ai-workspace"
  git -C "$PROJ" worktree repair "$WT" >/dev/null 2>&1
  spawn_task
  printf 'changed\n' >> "$WT/CLAUDE.md"
  commit_change nonexempt
  refused_push HEAD:refs/heads/not-exempt
  pass 'only the registered ai-workspace entry is exempt; its directory name alone grants nothing'
}

test_pipeline_gate() {
  make_case pipeline
  local bare pwt head
  bare="$C/.no-mistakes/repos/016d88035d58.git"
  mkdir -p "$(dirname "$bare")"
  git clone -q --bare "$C/origin.git" "$bare"
  git -C "$bare" config --local commit.gpgsign false
  git -C "$bare" config --local tag.gpgsign false
  git -C "$bare" config extensions.worktreeConfig true
  git -C "$bare" config --worktree core.hooksPath "$bare/hooks"
  git -C "$bare" config --worktree core.bare true
  git -C "$bare" config --local --unset core.bare
  git -C "$bare" remote set-url origin "$C/origin.git"
  git -C "$PROJ" remote add no-mistakes "$bare"
  spawn_task
  printf 'ordinary\n' > "$WT/ordinary.txt"
  commit_change submitted
  git -C "$WT" push -q no-mistakes HEAD:refs/heads/fm/task-x1 || fail 'ordinary submission to gate refused'
  pwt="$C/.no-mistakes/worktrees/016d88035d58/run"
  git -C "$bare" worktree add -q --detach "$pwt" fm/task-x1
  printf 'pipeline change\n' >> "$pwt/CLAUDE.md"
  git -C "$pwt" commit -qam 'pipeline added change'
  head=$(git -C "$pwt" rev-parse HEAD)
  if git -C "$pwt" push "$C/origin.git" "$head:refs/heads/fm/task-x1" > "$C/push.log" 2>&1; then
    fail 'pipeline-added protected change reached upstream'
  fi
  assert_grep '  CLAUDE.md' "$C/push.log" 'pipeline refusal did not name protected change'
  if git -C "$pwt" push "$C/origin.git" "$head:refs/heads/unregistered-task-branch" > "$C/push.log" 2>&1; then
    fail 'unregistered pipeline branch published a protected change'
  fi
  approve CLAUDE.md
  git -C "$pwt" push -q "$C/origin.git" "$head:refs/heads/fm/task-x1" || fail 'approved pipeline change refused'
  "$GATE" install "$WT" task-x2 fm/task-x2
  if git -C "$pwt" push "$C/origin.git" "$head:refs/heads/fm/task-x2" > "$C/push.log" 2>&1; then
    fail 'another task borrowed approval in the shared gate'
  fi
  assert_grep '  CLAUDE.md' "$C/push.log" 'other task should require its own approval'
  "$GATE" remove "$WT" task-x2
  "$GATE" install "$WT" task-x1 fm/task-x1
  pass 'bare gate hook checks the pipeline-added commit, including immutable-SHA pushes'
}

test_landing() {
  make_case landing
  printf 'unapproved\n' >> "$WT/CLAUDE.md"
  commit_change unapproved
  fm_write_meta "$HOME_DIR/state/task-x1.meta" "window=firstmate:fm-task-x1" "worktree=$WT" "project=$PROJ" "kind=ship" "mode=local-only"
  if "$ROOT/bin/fm-merge-local.sh" task-x1 > "$C/merge.log" 2>&1; then
    fail 'unapproved protected change landed locally'
  fi
  assert_grep '  CLAUDE.md' "$C/merge.log" 'local landing refusal did not name protected change'
  git -C "$PROJ" diff --exit-code main origin/main >/dev/null || fail 'refused merge changed main'
  git -C "$WT" push -q origin HEAD:refs/pull/9/head
  git -C "$PROJ" show main:CLAUDE.md > "$WT/CLAUDE.md"
  commit_change 'local branch restored while PR remains protected'
  cat > "$C/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/gh-axi.log"
SH
  chmod +x "$C/fakebin/gh-axi"
  fm_fake_exit0 "$C/fakebin" gh
  if PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-pr-merge.sh" task-x1 https://github.com/example/repo/pull/9 > "$C/merge.log" 2>&1; then
    fail 'unapproved protected change landed through PR'
  fi
  assert_grep '  CLAUDE.md' "$C/merge.log" 'PR landing refusal did not name protected change'
  assert_absent "$HOME_DIR/gh-axi.log" 'refused PR called merge'
  approve CLAUDE.md
  PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-pr-merge.sh" task-x1 https://github.com/example/repo/pull/9 > "$C/merge.log" 2>&1 \
    || fail "approved PR merge refused: $(cat "$C/merge.log")"
  assert_grep 'pr merge 9 --repo example/repo' "$HOME_DIR/gh-axi.log" 'approved PR never reached merge'
  printf "approved local change\n" >> "$WT/CLAUDE.md"
  commit_change "approved local change"
  "$ROOT/bin/fm-merge-local.sh" task-x1 > "$C/merge.log" 2>&1 || fail "approved local merge refused: $(cat "$C/merge.log")"
  pass 'both landing entrypoints refuse unapproved protected changes; exact local approval passes'
}

test_teardown() {
  make_case teardown
  spawn_task
  printf 'change\n' >> "$WT/CLAUDE.md"
  commit_change change
  refused_push HEAD:refs/heads/before-teardown
  approve CLAUDE.md
  git -C "$WT" push -q origin HEAD:refs/heads/main
  PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 > "$C/teardown.log" 2>&1 \
    || fail "teardown refused landed fixture: $(cat "$C/teardown.log")"
  git -C "$WT" checkout -qb reused
  printf 'next worker\n' >> "$WT/CONCEPTS.md"
  commit_change reused
  git -C "$WT" push -q origin HEAD:refs/heads/reused || fail 'returned pool copy retained a live gate'
  pass 'teardown removes the task marker; the retained shared hook is inert for pool reuse'
}

test_install_refusals() {
  make_case install-refusals
  git -C "$WT" config core.hooksPath .husky
  if "$GATE" install "$WT" task-x1 fm/task-x1 > "$C/install.log" 2>&1; then
    fail 'installer silently installed an inactive hook'
  fi
  assert_grep 'needs-decision [key=gate-install]' "$C/install.log" 'different active hooks directory must be reported'
  git -C "$WT" config --unset core.hooksPath
  printf '#!/bin/sh\nexit 0\n' > "$PROJ/.git/hooks/pre-push"
  printf 'unrelated existing backup\n' > "$PROJ/.git/hooks/pre-push.firstmate-original"
  if "$GATE" install "$WT" task-x1 fm/task-x1 > "$C/install.log" 2>&1; then
    fail 'installer overwrote an existing preserved hook'
  fi
  assert_grep 'unrelated existing backup' "$PROJ/.git/hooks/pre-push.firstmate-original" 'existing backup was overwritten'
  pass 'installer refuses inactive hook placement and preserves an existing hook backup'
}

for test in ${FM_PROTECTED_TESTS:-test_layer_one test_net_changes test_rename_and_case test_all_protected_paths_and_refs test_existing_hooks_and_unmarked_pushes test_exempt_project test_pipeline_gate test_landing test_teardown test_install_refusals}; do
  "$test"
done
