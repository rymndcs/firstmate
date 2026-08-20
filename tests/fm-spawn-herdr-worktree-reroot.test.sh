#!/usr/bin/env bash
# tests/fm-spawn-herdr-worktree-reroot.test.sh - drives bin/fm-spawn.sh's
# projected-restart path against a fake `herdr` to cover the carried-forward
# worktree tab's re-root block (bin/fm-spawn.sh, the block between
# `validate_spawn_worktree` and the best-effort worktree-tab create).
#
# `treehouse get` draws an interchangeable copy from a shared pool, so a
# restart can hand a task a different worktree while its recorded worktree tab
# still points at the previous one. The block probes that tab's live cwd and
# re-roots it when it no longer sits inside this run's worktree.
#
# Every assertion here reads the fake herdr's own call log - the sequence of
# CLI invocations the adapter actually made, which is this fixture's owned
# record of the side effects under test - never the source of the block.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-worktree-reroot)

TOKEN=AbCdEfGhIjKlMnOpQrStUv
SESSION=fmtest

# The projected workspace's label is minted by the adapter itself; deriving it
# here the same way keeps the fixture honest if that format ever changes.
WORKSPACE_LABEL=$(
  . "$ROOT/bin/backends/herdr.sh"
  fm_backend_herdr_projection_workspace_label reroot-z1 "$TOKEN"
)

# make_reroot_fakebin <dir> <parent-home> builds a fake `herdr` standing in for
# one restored projection: parent workspace `wp` (label `firstmate`) followed by
# the projected child `w1` (labelled with this task's token), holding the
# agent-free husk tab w1:t1/w1:p1 plus the recorded worktree tab w1:t9/w1:p9.
#
# FM_FAKE_WT_CWD is what `pane get w1:p9` reports as its live foreground cwd -
# the single input the re-root decision turns on.
# FM_FAKE_REFUSE_CLOSE=<pane> makes `pane close` on that pane a no-op that
# still reports success, so the pane stays present afterwards and the close
# cannot be confirmed.
make_reroot_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
LOG="\${FM_FAKE_HERDR_LOG:?}"
CLOSED="\${FM_FAKE_HERDR_CLOSED:?}"
CREATED="\${FM_FAKE_HERDR_CREATED:?}"
printf '%s\n' "\$*" >> "\$LOG"

closed() { grep -qxF "\$1" "\$CLOSED" 2>/dev/null; }
created_count() { local n; n=\$(grep -c . "\$CREATED" 2>/dev/null) || n=0; printf '%s' "\$n"; }

# The projected workspace's live tab/pane set: the husk pair, the recorded
# worktree pair, and anything this run created (replacement task tab first,
# then a re-rooted worktree tab), minus everything closed.
live_tabs() {
  local n
  n=\$(created_count)
  closed w1:p1 || printf 'w1:t1\tfm-reroot-z1\n'
  closed w1:p9 || printf 'w1:t9\tfm-reroot-z1 (worktree)\n'
  [ "\$n" -lt 1 ] || closed w1:p2 || printf 'w1:t2\tfm-reroot-z1\n'
  [ "\$n" -lt 2 ] || closed w1:p8 || printf 'w1:t8\tfm-reroot-z1 (worktree)\n'
}
pane_tab() {
  case "\$1" in
    w1:p1) printf 'w1:t1' ;;
    w1:p9) printf 'w1:t9' ;;
    w1:p2) printf 'w1:t2' ;;
    w1:p8) printf 'w1:t8' ;;
  esac
}
pane_cwd() {
  case "\$1" in
    w1:p9) printf '%s' "\${FM_FAKE_WT_CWD:-}" ;;
    w1:p2) printf '%s' "\${FM_FAKE_TASK_CWD:-}" ;;
    w1:p8) printf '%s' "\${FM_FAKE_NEW_WT_CWD:-}" ;;
    *) printf '%s' "\${FM_FAKE_TASK_CWD:-}" ;;
  esac
}

case "\${1:-} \${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"$SESSION","running":true,"socket_path":"$dir/herdr.sock"}]}'
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wp","active_tab_id":"wp:t0","label":"firstmate","focused":true},{"workspace_id":"w1","active_tab_id":"w1:t1","label":"%s","focused":false}]}}\n' \
      '$WORKSPACE_LABEL'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wp"*)
        printf '%s\n' '{"result":{"tabs":[{"tab_id":"wp:t0","label":"captain","focused":true}]}}'
        ;;
      *"--workspace w1"*)
        printf '{"result":{"tabs":['
        live_tabs | awk -F'\t' '{ printf "%s{\"tab_id\":\"%s\",\"label\":\"%s\",\"workspace_id\":\"w1\"}", (NR>1?",":""), \$1, \$2 }'
        printf ']}}\n'
        ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '{"result":{"panes":['
    { closed w1:p1 || printf 'w1:p1\n'; closed w1:p9 || printf 'w1:p9\n'
      [ "\$(created_count)" -lt 1 ] || closed w1:p2 || printf 'w1:p2\n'
      [ "\$(created_count)" -lt 2 ] || closed w1:p8 || printf 'w1:p8\n'; } \
      | awk -v q='"' '{ printf "%s{%spane_id%s:%s%s%s,%stab_id%s:%s", (NR>1?",":""), q,q,q,\$1,q, q,q,q }
        { t=\$1; sub(/p/,"t",t); printf "%s%s}", t, q }'
    printf ']}}\n'
    ;;
  "tab get")
    printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"w1"}}}\n' "\${3:-}"
    ;;
  "tab focus")
    printf '%s\n' '{"result":{"tab":{"tab_id":"wp:t0","workspace_id":"wp","focused":true}}}'
    ;;
  "tab create")
    n=\$(created_count)
    printf 'x\n' >> "\$CREATED"
    if [ "\$n" -lt 1 ]; then
      printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    else
      printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t8"},"root_pane":{"pane_id":"w1:p8"}}}'
    fi
    ;;
  "pane close")
    [ "\${FM_FAKE_REFUSE_CLOSE:-}" = "\${3:-}" ] || printf '%s\n' "\${3:-}" >> "\$CLOSED"
    printf '%s\n' '{"result":{}}'
    ;;
  "pane get")
    if closed "\${3:-}"; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w1","foreground_cwd":"%s"}}}\n' \
      "\${3:-}" "\$(pane_tab "\${3:-}")" "\$(pane_cwd "\${3:-}")"
    ;;
  "agent get")
    if closed "\${3:-}"; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    fi
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_reroot_case <name>: a home whose task reroot-z1 already has a bound
# version 2 projection journal and a projected meta recording the worktree tab,
# plus two real pooled worktrees - `wt` (what this run's `treehouse get` lands
# on) and `wt-prev` (the copy the previous run held).
make_reroot_case() {
  local name=$1 case_dir home proj wt prev fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  prev="$case_dir/wt-prev"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '\n' > "$home/config/herdr-presentation-spaces"
  printf 'herdr\n' > "$home/config/backend"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" worktree add --quiet -b "prev-$name" "$prev"
  mkdir -p "$wt/src/deep"
  mkdir -p "$home/data/reroot-z1"
  printf 'brief\n' > "$home/data/reroot-z1/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/reroot-z1.meta" \
    "window=$SESSION:w1:p1" \
    "endpoint_task_id=reroot-z1" \
    "worktree=$prev" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=$SESSION" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" \
    "herdr_pane_id=w1:p1" \
    "herdr_worktree_tab_id=w1:t9" \
    "herdr_worktree_pane_id=w1:p9"
  fm_write_meta "$home/state/reroot-z1.herdr-presentation" \
    'version=2' \
    'task_id=reroot-z1' \
    "projection_id=$TOKEN" \
    "home=$(cd "$home" && pwd -P)" \
    "session=$SESSION" \
    'workspace_id=w1' \
    'tab_id=w1:t1' \
    'pane_id=w1:p1' \
    'parent_workspace_id=wp' \
    'parent_label=firstmate' \
    "workspace_label=$WORKSPACE_LABEL" \
    'task_label=fm-reroot-z1'
  fakebin=$(make_reroot_fakebin "$case_dir" "$home")
  printf '%s\n' "$case_dir|$home|$proj|$wt|$prev|$fakebin"
}

read_reroot_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR PREV_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_reroot_spawn <worktree-tab-cwd> [refuse-close-pane]: restart the projected
# task with the recorded worktree tab reporting <worktree-tab-cwd>.
run_reroot_spawn() {
  local wt_cwd=$1 refuse=${2:-}
  : > "$CASE_DIR/herdr.log"; : > "$CASE_DIR/closed"; : > "$CASE_DIR/created"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 HERDR_SESSION="$SESSION" \
    FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" FM_FAKE_HERDR_CLOSED="$CASE_DIR/closed" \
    FM_FAKE_HERDR_CREATED="$CASE_DIR/created" \
    FM_FAKE_WT_CWD="$wt_cwd" FM_FAKE_TASK_CWD="$WT_DIR" FM_FAKE_NEW_WT_CWD="$WT_DIR" \
    FM_FAKE_REFUSE_CLOSE="$refuse" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" reroot-z1 "$PROJ_DIR" --mode local-only --yolo off --captain-pick codex \
    > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
}

# herdr_call_index <pattern>: 1-based line number of the first fake-herdr call
# matching <pattern>, or empty. The log records one line per real invocation.
herdr_call_index() {
  grep -n -- "$1" "$CASE_DIR/herdr.log" | head -1 | cut -d: -f1
}

assert_reclaim_reached() {
  local what=$1
  [ -n "$(herdr_call_index 'pane close w1:p1')" ] \
    || fail "$what: the fixture never reached the reclaim husk close, so the re-root block was never exercised"
}

# A worktree tab still rooted at this run's own worktree is left alone: no
# close, no replacement create, and its recorded ids survive into the refreshed
# metadata.
test_worktree_tab_at_the_current_worktree_is_kept() {
  local rec
  rec=$(make_reroot_case reroot-match)
  read_reroot_record "$rec"

  run_reroot_spawn "$WT_DIR"
  assert_reclaim_reached "reroot-match"
  [ -z "$(herdr_call_index 'pane close w1:p9')" ] \
    || fail "a worktree tab already rooted at this run's worktree must not be closed"
  [ -z "$(herdr_call_index '(worktree)')" ] \
    || fail "a worktree tab already rooted at this run's worktree must not be recreated"
  assert_grep 'herdr_worktree_pane_id=w1:p9' "$HOME_DIR/state/reroot-z1.meta" \
    "the kept worktree tab's recorded pane id did not survive into the refreshed metadata"
  assert_grep 'herdr_worktree_tab_id=w1:t9' "$HOME_DIR/state/reroot-z1.meta" \
    "the kept worktree tab's recorded tab id did not survive into the refreshed metadata"
  pass "a carried-forward worktree tab rooted at this run's own worktree is kept untouched"
}

# The captain is expected to cd around inside the copy while browsing, so a
# subdirectory of this run's worktree is still the right worktree.
test_worktree_tab_in_a_subdirectory_is_kept() {
  local rec
  rec=$(make_reroot_case reroot-subdir)
  read_reroot_record "$rec"

  run_reroot_spawn "$WT_DIR/src/deep"
  assert_reclaim_reached "reroot-subdir"
  [ -z "$(herdr_call_index 'pane close w1:p9')" ] \
    || fail "a captain who navigated into a subdirectory must not lose the tab to a re-root"
  assert_grep 'herdr_worktree_pane_id=w1:p9' "$HOME_DIR/state/reroot-z1.meta" \
    "a subdirectory cwd wrongly dropped the recorded worktree ids"
  pass "a carried-forward worktree tab sitting in a subdirectory of this run's worktree is kept"
}

# A tab left pointing at the copy the previous run held is closed and replaced
# by a fresh one rooted at this run's worktree.
test_worktree_tab_in_another_copy_is_rerooted() {
  local rec close_at create_at
  rec=$(make_reroot_case reroot-stale)
  read_reroot_record "$rec"

  run_reroot_spawn "$PREV_DIR"
  assert_reclaim_reached "reroot-stale"
  close_at=$(herdr_call_index 'pane close w1:p9')
  create_at=$(herdr_call_index "--cwd $WT_DIR --label fm-reroot-z1 (worktree)")
  [ -n "$close_at" ] || fail "a worktree tab rooted in another pooled copy was not closed"
  [ -n "$create_at" ] || fail "the stale worktree tab was not recreated at this run's own worktree"
  [ "$close_at" -lt "$create_at" ] \
    || fail "the stale pane must be closed before its replacement is created"
  assert_grep 'herdr_worktree_pane_id=w1:p8' "$HOME_DIR/state/reroot-z1.meta" \
    "the refreshed metadata did not record the re-rooted worktree pane"
  assert_no_grep 'herdr_worktree_pane_id=w1:p9' "$HOME_DIR/state/reroot-z1.meta" \
    "the refreshed metadata still records the stale worktree pane"
  pass "a carried-forward worktree tab rooted in another pooled copy is closed and re-rooted"
}

# An unreadable cwd is never trusted as a match - it re-roots like any other
# mismatch rather than silently keeping a tab it could not verify.
test_unreadable_worktree_tab_cwd_is_rerooted() {
  local rec
  rec=$(make_reroot_case reroot-unreadable)
  read_reroot_record "$rec"

  run_reroot_spawn ""
  assert_reclaim_reached "reroot-unreadable"
  [ -n "$(herdr_call_index 'pane close w1:p9')" ] \
    || fail "a worktree tab whose cwd could not be read must not be trusted as still correctly rooted"
  pass "a carried-forward worktree tab whose live cwd cannot be read is re-rooted, never trusted"
}

# The stale tab is presentation-only, so a close that cannot be confirmed still
# drops the recorded ids and still re-roots, warning by exact pane id rather
# than keeping a handle to a tab known to show the wrong copy.
test_unconfirmed_stale_close_still_clears_and_recreates() {
  local rec
  rec=$(make_reroot_case reroot-refused)
  read_reroot_record "$rec"

  run_reroot_spawn "$PREV_DIR" w1:p9
  assert_reclaim_reached "reroot-refused"
  [ -n "$(herdr_call_index 'pane close w1:p9')" ] \
    || fail "the refused-close fixture never attempted the stale close"
  assert_grep "pane 'w1:p9'" "$CASE_DIR/stderr" \
    "an unconfirmed stale-pane close did not name the exact pane an operator must close by hand"
  [ -n "$(herdr_call_index "--cwd $WT_DIR --label fm-reroot-z1 (worktree)")" ] \
    || fail "an unconfirmed close must still fall through to the fresh correctly-rooted create"
  assert_no_grep 'herdr_worktree_pane_id=w1:p9' "$HOME_DIR/state/reroot-z1.meta" \
    "an unconfirmed close must still drop the stale recorded pane id"
  pass "an unconfirmed stale-pane close still clears the recorded ids and re-roots the tab"
}

test_worktree_tab_at_the_current_worktree_is_kept
test_worktree_tab_in_a_subdirectory_is_kept
test_worktree_tab_in_another_copy_is_rerooted
test_unreadable_worktree_tab_cwd_is_rerooted
test_unconfirmed_stale_close_still_clears_and_recreates

echo "# all fm-spawn-herdr-worktree-reroot tests passed"
