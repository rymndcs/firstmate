#!/usr/bin/env bash
# Private homes for public PR registration and poll behavior tests.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-behavior.XXXXXX")
trap 'rm -rf "${PR_TMP:?}"' EXIT
PR_CODE="$PR_TMP/code"
mkdir -p "$PR_CODE"
cp -R "$ROOT/bin" "$PR_CODE/bin"
for tool in fm-guard fm-linear fm-standing-knowledge; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PR_CODE/bin/$tool.sh"
done
export FM_ROOT_OVERRIDE="$PR_CODE" FM_HOME="$PR_TMP/home"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config" "$PR_TMP/fakebin"
export PATH="$PR_TMP/fakebin:$PATH"
export FM_TEST_GH_STATE=OPEN FM_TEST_GH_HEAD=1111111111111111111111111111111111111111
export FM_TEST_GH_BUCKETS=pass FM_TEST_GH_CHECK_RC=0
export FM_TEST_GH_ALL_BUCKETS=fail FM_TEST_GH_ALL_RC=1
cat > "$PR_TMP/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *headRefOid*)
    case " $* " in
      *" ${FM_TEST_GH_HEAD_WAIT_URL:-none} "*)
        : > "$FM_HOME/head-wait-started"
        for _ in $(seq 600); do
          [ ! -e "$FM_HOME/head-wait-release" ] || break
          sleep 0.05
        done
        : > "$FM_HOME/head-wait-finished" ;;
    esac
    if [ -n "${FM_TEST_GH_HEAD_AFTER:-}" ]; then
      marker="$FM_HOME/head-query"
      if [ -f "$marker" ]; then
        printf '%s\n' "$FM_TEST_GH_HEAD_AFTER"
      else
        : > "$marker"
        printf '%s\n' "$FM_TEST_GH_HEAD"
      fi
    else
      printf '%s\n' "$FM_TEST_GH_HEAD"
    fi
    ;;
  *'pr checks '*)
    case " $* " in
      *' --required '*)
        [ -z "${FM_TEST_GH_CHECK_ERR:-}" ] || printf '%s\n' "$FM_TEST_GH_CHECK_ERR" >&2
        [ -z "$FM_TEST_GH_BUCKETS" ] || printf '%s\n' "$FM_TEST_GH_BUCKETS"
        exit "$FM_TEST_GH_CHECK_RC" ;;
      *) printf '%s\n' "$FM_TEST_GH_ALL_BUCKETS"; exit "$FM_TEST_GH_ALL_RC" ;;
    esac ;;
  *'pr view '*)
    case " $* " in
      *" ${FM_TEST_GH_MERGED_URL:-none} "*) printf 'MERGED\n' ;;
      *) printf '%s\n' "$FM_TEST_GH_STATE" ;;
    esac ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$PR_TMP/fakebin/gh"
url=https://github.com/owner/repo/pull/42
write_pr_task() {  # <task-id> [extra-meta-line...]
  fm_write_meta "$FM_HOME/state/$1.meta" "worktree=$PR_TMP" 'kind=ship' "${@:2}"
}
register_pr() {
  "$PR_CODE/bin/fm-pr-check.sh" "$1" "$url" > /dev/null 2> "$PR_TMP/register.err" || fail 'registration failed'
}
poll_pr() {
  local number=${1:-42}
  "$PR_CODE/bin/fm-pr-poll.sh" --validated github "https://github.com/owner/repo/pull/$number" github.com owner/repo "$number"
}
await_file() {
  for _ in $(seq 200); do
    [ ! -e "$1" ] || return 0
    sleep 0.05
  done
  fail "$2"
}
drain_pr() {
  "$PR_CODE/bin/fm-wake-drain.sh"
}
