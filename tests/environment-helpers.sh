# shellcheck shell=bash
# Shared operational environment for every runner child and standalone test.
# fm_test_environment <private-home> resets inherited home, state, queue, lock,
# and claim paths before creating a fresh home; fixtures may then override them.
fm_test_environment() {
  local private_home=$1
  unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE \
    FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_ROOT STATE FM_WAKE_QUEUE \
    FM_WAKE_QUEUE_LOCK FM_PROCEVENT_CLAIM_ROOT FM_LOCK_OWNER_DIR \
    FM_LOCK_HELD_PID FM_BACKEND FM_PROC_ROOT_OVERRIDE
  export FM_HOME="$private_home"
  export FM_PROCEVENT_CLAIM_ROOT="$private_home/procevent-claims"
  mkdir -p "$FM_HOME/state" "$FM_PROCEVENT_CLAIM_ROOT" || return 1
  chmod 0700 "$FM_HOME"
}
