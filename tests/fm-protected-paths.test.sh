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
  printf '> \nCLAUDE.md\nCONCEPTS.md\n' > "$HOME_DIR/data/task-x1/agent-file-approval.md"
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CLAUDE.md' "$C/push.log" 'empty captain quotation must refuse CLAUDE.md'
  assert_grep '  CONCEPTS.md' "$C/push.log" 'empty captain quotation must refuse CONCEPTS.md'
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
  for path in nested/.claude/tool nested/.codex/tool nested/docs/solutions/note; do
    mkdir -p "$WT/$(dirname "$path")"
    printf 'ordinary\n' > "$WT/$path"
  done
  commit_change 'nested ordinary names'
  git -C "$WT" push -q origin HEAD:refs/heads/nested-ordinary || fail 'nested directories outside the root-anchored set were gated'
  git -C "$C/origin.git" show-ref --verify --quiet refs/heads/nested-ordinary || fail 'nested ordinary names did not publish'
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

# Real gates track origin under refs/remotes/origin/* only: no local main or
# master, and no origin/HEAD.
make_gate() {
  GATE_REPO="$C/.no-mistakes/repos/016d88035d58.git"
  mkdir -p "$(dirname "$GATE_REPO")"
  git init -q --bare "$GATE_REPO"
  git -C "$GATE_REPO" symbolic-ref HEAD refs/heads/main
  git -C "$GATE_REPO" config --local commit.gpgsign false
  git -C "$GATE_REPO" config --local tag.gpgsign false
  git -C "$GATE_REPO" remote add origin "$C/origin.git"
  git -C "$GATE_REPO" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$GATE_REPO" config extensions.worktreeConfig true
  git -C "$GATE_REPO" config --worktree core.hooksPath "$GATE_REPO/hooks"
  git -C "$GATE_REPO" config --worktree core.bare true
  git -C "$GATE_REPO" config --local --unset core.bare
  git -C "$PROJ" remote add no-mistakes "$GATE_REPO"
}

test_pipeline_gate() {
  make_case pipeline
  local bare pwt head
  make_gate
  bare=$GATE_REPO
  spawn_task
  printf 'ordinary\n' > "$WT/ordinary.txt"
  commit_change submitted
  git -C "$WT" push -q no-mistakes HEAD:refs/heads/fm/task-x1 || fail 'ordinary submission to gate refused'
  pwt="$C/.no-mistakes/worktrees/016d88035d58/run"
  git -C "$bare" worktree add -q --detach "$pwt" fm/task-x1
  head=$(git -C "$pwt" rev-parse HEAD)
  git -C "$pwt" push -q "$C/origin.git" "$head:refs/heads/fm/task-x1" > "$C/push.log" 2>&1 \
    || fail "ordinary pipeline push refused: $(cat "$C/push.log")"
  [ "$(git -C "$C/origin.git" rev-parse refs/heads/fm/task-x1)" = "$head" ] || fail 'ordinary pipeline push did not reach upstream'
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
  pass 'real-layout bare gate publishes ordinary pipeline pushes and checks pipeline-added commits, including immutable-SHA pushes'
}

refused_publication() {
  if git -C "$1" push "$C/origin.git" "${@:2}" > "$C/push.log" 2>&1; then
    fail "gate published ${*:2} without approval"
  fi
  assert_grep '  CLAUDE.md' "$C/push.log" "gate refusal of ${*:2} did not name the protected change"
}

test_gate_default_publication() {
  make_case gate-default
  local pwt captain pipeline worker
  make_gate
  spawn_task
  printf 'captain edit\n' >> "$PROJ/CLAUDE.md"
  git -C "$PROJ" commit -qam 'captain edit on primary main'
  captain=$(git -C "$PROJ" rev-parse main)
  git -C "$PROJ" push -q no-mistakes main:refs/heads/main || fail 'captain main did not reach the gate'
  pwt="$C/.no-mistakes/worktrees/016d88035d58/captain"
  git -C "$GATE_REPO" worktree add -q --detach "$pwt" refs/heads/main
  refused_publication "$pwt" "$captain:refs/heads/main" "$captain:refs/heads/other-branch"
  refused_publication "$pwt" "$captain:refs/heads/fm/task-x1"
  printf 'pipeline addition\n' > "$pwt/pipeline.txt"
  git -C "$pwt" add pipeline.txt
  git -C "$pwt" commit -qm 'pipeline-added commit on captain main'
  pipeline=$(git -C "$pwt" rev-parse HEAD)
  refused_publication "$pwt" "$pipeline:refs/heads/main"
  git -C "$WT" merge -q --ff-only main
  printf 'worker addition\n' > "$WT/worker.txt"
  commit_change 'worker commit on captain main'
  worker=$(git -C "$WT" rev-parse HEAD)
  git -C "$PROJ" push -q no-mistakes "$worker:refs/heads/main"
  refused_publication "$pwt" "$worker:refs/heads/main"
  refused_publication "$pwt" "$captain:refs/heads/main" "$worker:refs/heads/fm/task-x1"
  [ "$(git -C "$C/origin.git" rev-parse refs/heads/main)" != "$captain" ] || fail 'refused push published captain main'
  git -C "$pwt" push -q "$C/origin.git" "$captain:refs/heads/main" > "$C/push.log" 2>&1 \
    || fail "captain default publication refused: $(cat "$C/push.log")"
  [ "$(git -C "$C/origin.git" rev-parse refs/heads/main)" = "$captain" ] || fail 'captain main did not reach upstream'
  pass 'gate publishes captain primary main to the default branch; other refs and off-main commits stay gated'
}

# A protected edit already on unpublished local main rides along in every
# push, so the push still needs approval, but local landing compares with the
# local branch it fast-forwards.
test_inherited_main_change() {
  make_case inherited
  printf 'captain edit\n' >> "$PROJ/CLAUDE.md"
  git -C "$PROJ" commit -qam 'captain edit on unpublished local main'
  git -C "$WT" merge -q --ff-only main
  spawn_task
  printf 'ordinary\n' > "$WT/ordinary.txt"
  commit_change 'unrelated task change'
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CLAUDE.md' "$C/push.log" 'push must refuse the unpublished protected edit it would publish'
  fm_write_meta "$HOME_DIR/state/task-x1.meta" "window=firstmate:fm-task-x1" "worktree=$WT" "project=$PROJ" "kind=ship" "mode=local-only"
  "$ROOT/bin/fm-merge-local.sh" task-x1 > "$C/merge.log" 2>&1 || fail "unrelated task landing refused: $(cat "$C/merge.log")"
  [ "$(git -C "$PROJ" rev-parse main)" = "$(git -C "$WT" rev-parse HEAD)" ] || fail 'unrelated task did not land on local main'
  pass 'push refuses an inherited unpublished protected edit; local landing of an unrelated task passes'
}

assert_no_comparison_ref() {
  if git -C "$PROJ" show-ref --verify --quiet refs/fm-protected/pull/9; then
    fail "$1 left its comparison ref behind"
  fi
  git -C "$PROJ" show-ref --verify --quiet refs/fm-protected/pull/10 || fail "$1 removed another PR's ref"
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
  git -C "$PROJ" update-ref refs/fm-protected/pull/10 main
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
  assert_no_comparison_ref 'refused PR check'
  approve CLAUDE.md
  PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-pr-merge.sh" task-x1 https://github.com/example/repo/pull/9 > "$C/merge.log" 2>&1 \
    || fail "approved PR merge refused: $(cat "$C/merge.log")"
  assert_grep 'pr merge 9 --repo example/repo' "$HOME_DIR/gh-axi.log" 'approved PR never reached merge'
  assert_no_comparison_ref 'approved PR check'
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

landed_task_with_missing_gate() {
  make_case "$1"
  make_gate
  spawn_task
  printf 'ordinary\n' > "$WT/ordinary.txt"
  commit_change ordinary
  git -C "$WT" push -q origin HEAD:refs/heads/main
  mv "$GATE_REPO" "$C/gate-moved-away"
}

assert_marker_removed() {
  git -C "$WT" checkout -qb "after-$1"
  printf 'next worker\n' >> "$WT/CONCEPTS.md"
  commit_change "after $1"
  git -C "$WT" push -q origin "HEAD:refs/heads/after-$1" || fail "$1 left the task marker active"
}

test_missing_gate_cleanup() {
  landed_task_with_missing_gate missing-gate
  git -C "$PROJ" worktree add -qb fm/task-x2 "$C/task2"
  if "$GATE" install "$C/task2" task-x2 fm/task-x2 > "$C/install.log" 2>&1; then
    fail 'install accepted a missing no-mistakes gate'
  fi
  assert_absent "$(git -C "$C/task2" rev-parse --absolute-git-dir)/fm-agent-file-task.json" 'refused install wrote a task marker'
  PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 > "$C/teardown.log" 2>&1 \
    || fail "teardown of a landed task refused after its gate disappeared: $(cat "$C/teardown.log")"
  assert_marker_removed teardown
  landed_task_with_missing_gate missing-gate-force
  PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 --force > "$C/teardown.log" 2>&1 \
    || fail "forced teardown of a landed task refused after its gate disappeared: $(cat "$C/teardown.log")"
  assert_marker_removed forced-teardown
  make_case missing-gate-unlanded
  make_gate
  spawn_task
  printf 'unlanded\n' >> "$WT/CLAUDE.md"
  commit_change unlanded
  mv "$GATE_REPO" "$C/gate-moved-away"
  if PATH="$C/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 > "$C/teardown.log" 2>&1; then
    fail 'teardown discarded unlanded work after the gate disappeared'
  fi
  refused_push HEAD:refs/heads/unlanded
  pass 'a landed task cleans up without its gate; install still refuses it; unlanded work keeps its protection'
}

test_unreachable_origin() {
  make_case unreachable-origin
  make_gate
  spawn_task
  printf 'ordinary\n' > "$WT/ordinary.txt"
  commit_change ordinary
  git -C "$PROJ" remote set-url origin "$C/unreachable-origin.git"
  if git -C "$WT" push no-mistakes HEAD:refs/heads/fm/task-x1 > "$C/push.log" 2>&1; then
    fail 'submission passed without a current origin base'
  fi
  assert_grep 'origin must be reachable to submit' "$C/push.log" 'unreachable origin refusal must say origin is needed'
  assert_grep "merge-base with origin's current main" "$C/push.log" 'unreachable origin refusal must say why'
  assert_no_grep 'returned non-zero exit status' "$C/push.log" 'unreachable origin refusal leaked a raw command failure'
  if git -C "$GATE_REPO" show-ref --verify --quiet refs/heads/fm/task-x1; then
    fail 'refused submission reached the gate'
  fi
  pass 'submission with an unreachable origin refuses and says origin must be reachable, and why'
}

# A branch name long enough that its JSON record outgrows the file-size limit,
# while the shared hook files still fit, interrupts the record write itself.
long_branch() {
  local branch=fm part
  part=$(printf '%0200d' 0)
  for _ in $(seq 60); do
    branch="$branch/$part"
  done
  printf '%s\n' "$branch"
}

interrupted_install() {
  if (ulimit -f 8; "$GATE" install "$1" "$2" "$(long_branch)") > "$C/install.log" 2>&1; then
    fail 'oversized record publication was not interrupted'
  fi
  assert_grep 'File too large' "$C/install.log" 'publication was not interrupted inside the record write'
}

# A killed installer can also leave a partial temporary file behind; the
# fixtures plant one at the earlier fixed temporary name before each retry.
test_interrupted_publication() {
  make_case interrupted-marker
  local gitdir entries entry
  spawn_task
  approve CLAUDE.md
  printf 'changed\n' >> "$WT/CLAUDE.md"
  commit_change change
  interrupted_install "$WT" task-x1
  git -C "$WT" push -q origin HEAD:refs/heads/fm/task-x1 || fail 'interrupted publication damaged the published task marker'
  printf 'changed\n' >> "$WT/CONCEPTS.md"
  commit_change unapproved
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CONCEPTS.md' "$C/push.log" 'earlier marker stopped protecting after an interrupted publication'
  gitdir=$(git -C "$WT" rev-parse --absolute-git-dir)
  [ -z "$(find "$gitdir" -maxdepth 1 -name '*fm-agent-file-task*' ! -name fm-agent-file-task.json)" ] \
    || fail 'interrupted marker publication left a temporary file'
  printf '{"task": "task-x1", "ref' > "$gitdir/fm-agent-file-task.json.lock"
  "$GATE" install "$WT" task-x1 fm/task-x1 > "$C/install.log" 2>&1 \
    || fail "install after an interrupted marker publication refused: $(cat "$C/install.log")"
  refused_push HEAD:refs/heads/fm/task-x1
  assert_grep '  CONCEPTS.md' "$C/push.log" 'republished marker did not enforce its approval'
  make_case interrupted-gate
  make_gate
  spawn_task
  git -C "$PROJ" worktree add -qb fm/task-x2 "$C/task2"
  interrupted_install "$C/task2" task-x2
  entries="$GATE_REPO/hooks/fm-agent-file-tasks"
  [ -z "$(find "$entries" -mindepth 1 ! -name '*.json')" ] || fail 'interrupted gate publication left a temporary file'
  printf 'ordinary\n' > "$WT/ordinary.txt"
  commit_change ordinary
  git -C "$WT" push -q no-mistakes HEAD:refs/heads/fm/task-x1 || fail 'submission refused after an interrupted gate publication'
  git -C "$GATE_REPO" worktree add -q --detach "$C/run" fm/task-x1
  git -C "$C/run" push -q "$C/origin.git" HEAD:refs/heads/fm/task-x1 > "$C/push.log" 2>&1 \
    || fail "interrupted publication damaged the gate registrations: $(cat "$C/push.log")"
  entry=$(printf '%s' "refs/heads/$(long_branch)" | shasum -a 256 | cut -c1-64)
  printf '{"task": "task-x2", "ref' > "$entries/$entry.json.lock"
  "$GATE" install "$C/task2" task-x2 "$(long_branch)" > "$C/install.log" 2>&1 \
    || fail "install after an interrupted gate publication refused: $(cat "$C/install.log")"
  if "$GATE" install "$C/task2" task-x3 "$(long_branch)" > "$C/install.log" 2>&1; then
    fail 'republished gate registration lost its assignment'
  fi
  assert_grep 'already assigned to another task' "$C/install.log" 'republished gate registration must keep its assignment'
  pass 'interrupted marker and gate publications leave the published records valid and allow a retry'
}

second_writer_retries() {
  if "$GATE" install "$C/task2" task-x2 fm/task-x1 > "$C/install.log" 2>&1; then
    fail "a second writer registered the gate branch $1"
  fi
  assert_grep 'retry after it finishes' "$C/install.log" "a second writer $1 must be told to retry"
}

# The first writer runs with a git that stops on its last call, which resolves
# the task's Git directory after the gate registration and before the marker.
test_concurrent_registration() {
  make_case concurrent-registration
  make_gate
  cp -R "$ROOT/bin" "$C/bin"
  rm "${C:?}/bin/fm-protected-pre-push.py"
  mkfifo "$C/bin/fm-protected-pre-push.py" "$C/hold-records"
  mkdir "$C/holdbin"
  printf '#!/usr/bin/env bash\ncase "$*" in *" rev-parse --absolute-git-dir") read -r _ < %q ;; esac\nexec %q "$@"\n' \
    "$C/hold-records" "$(command -v git)" > "$C/holdbin/git"
  chmod +x "$C/holdbin/git"
  git -C "$PROJ" worktree add -qb fm/task-x2 "$C/task2"
  PATH="$C/holdbin:$PATH" start_held_install
  second_writer_retries 'while the first publishes its dispatcher'
  cat "$ROOT/bin/fm-protected-pre-push.py" >&8
  exec 8>&-
  # The gate's dispatcher is published from the same source.
  exec 8> "$C/bin/fm-protected-pre-push.py"
  cat "$ROOT/bin/fm-protected-pre-push.py" >&8
  exec 8>&-
  exec 9> "$C/hold-records"
  second_writer_retries 'after the first registered it'
  printf '\n' >&9
  exec 9>&-
  wait "$HELD_PID" || fail "held installer failed: $(cat "$C/held.log")"
  if "$GATE" install "$C/task2" task-x2 fm/task-x1 > "$C/install.log" 2>&1; then
    fail 'a conflicting writer took over a registered gate branch'
  fi
  assert_grep 'already assigned to another task' "$C/install.log" 'conflicting writer must be refused'
  assert_absent "$(git -C "$C/task2" rev-parse --absolute-git-dir)/fm-agent-file-task.json" 'refused writer published a task marker'
  approve CLAUDE.md
  printf 'approved\n' >> "$WT/CLAUDE.md"
  commit_change approved
  git -C "$WT" push -q no-mistakes HEAD:refs/heads/fm/task-x1 || fail 'first writer marker lost its approval'
  git -C "$GATE_REPO" worktree add -q --detach "$C/run" fm/task-x1
  git -C "$C/run" push -q "$C/origin.git" HEAD:refs/heads/fm/task-x1 > "$C/push.log" 2>&1 \
    || fail "first writer gate registration lost its approval: $(cat "$C/push.log")"
  pass "a second writer for one gate branch retries throughout the first writer's publication, then is refused; the first record stays complete"
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

# An installer copy whose hook source is a FIFO stops inside the install lock until the test writes it.
start_held_install() {
  set -m
  "$C/bin/fm-protected-paths.sh" install "$WT" task-x1 fm/task-x1 > "$C/held.log" 2>&1 &
  HELD_PID=$!
  set +m
  exec 8> "$C/bin/fm-protected-pre-push.py"
}

test_install_lock_recovery() {
  make_case install-lock
  cp -R "$ROOT/bin" "$C/bin"
  rm "${C:?}/bin/fm-protected-pre-push.py"
  mkfifo "$C/bin/fm-protected-pre-push.py"
  start_held_install
  kill -KILL -- "-$HELD_PID"
  exec 8>&-
  wait "$HELD_PID" 2>/dev/null || true
  "$GATE" install "$WT" task-x1 fm/task-x1 > "$C/install.log" 2>&1 \
    || fail "install after a killed installer refused: $(cat "$C/install.log")"
  "$GATE" install "$WT" task-x1 fm/task-x1 > "$C/install.log" 2>&1 \
    || fail "repeated install refused: $(cat "$C/install.log")"
  start_held_install
  if "$GATE" install "$WT" task-x1 fm/task-x1 > "$C/install.log" 2>&1; then
    fail 'install ran while a live installer held the lock'
  fi
  assert_grep 'retry after it finishes' "$C/install.log" 'live lock refusal must say how to recover'
  cat "$ROOT/bin/fm-protected-pre-push.py" >&8
  exec 8>&-
  wait "$HELD_PID" || fail "live installer lost its lock: $(cat "$C/held.log")"
  "$GATE" install "$WT" task-x1 fm/task-x1 > "$C/install.log" 2>&1 \
    || fail "install after the live installer finished refused: $(cat "$C/install.log")"
  [ -z "$(find "$PROJ/.git/hooks" -name '.fm-protected-install.lock*')" ] || fail 'install left its lock behind'
  printf 'changed\n' >> "$WT/CLAUDE.md"
  commit_change change
  refused_push HEAD:refs/heads/fm/task-x1
  pass 'a killed installer leaves no lasting block; a live installer keeps its lock; repeated installs pass'
}

for test in ${FM_PROTECTED_TESTS:-test_layer_one test_net_changes test_rename_and_case test_all_protected_paths_and_refs test_existing_hooks_and_unmarked_pushes test_exempt_project test_pipeline_gate test_gate_default_publication test_inherited_main_change test_landing test_teardown test_missing_gate_cleanup test_unreachable_origin test_install_refusals test_install_lock_recovery test_interrupted_publication test_concurrent_registration}; do
  "$test"
done
