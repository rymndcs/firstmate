#!/usr/bin/env bash
# Shared ship-review step: the one owner of how a home's private review
# configuration reaches every ship task and how landing verifies it ran.
# Sourced by bin/fm-brief.sh and bin/fm-promote.sh (the review text) and by
# bin/fm-merge-local.sh and bin/fm-pr-merge.sh (the landing gate).
# docs/configuration.md "Ship review step" owns the two config files, their
# formats, defaults, and effects; this header owns the mechanics below.
#
# Review text: when <config>/ship-review.md exists, its contents are appended to
# every ship brief and written beside a promoted scout's instructions. Three
# placeholders are replaced at scaffold time: {TASK_ID}, {BRANCH}, and
# {STATUS_FILE} (the task's absolute status-file path). No file, no change.
#
# Landing gate: when the first line of <config>/ship-review-gate is `required`,
# landing a task refuses unless the LAST line of state/<id>.status whose verb is
# `review` reads exactly
#   review: passed <absolute path to the review report>
# and that path names a non-empty regular file. The worker appends that line
# after committing the review's fixes and before `done:`; a later `review:` line
# of any other form (for example `review: reopened <why>`) withdraws the pass.
# An absent file, or first line `off`, means no gate. Any other first line, or an
# unreadable file, refuses landing and names the file: a broken gate never
# silently opens.
#
# Captain override: FM_SHIP_REVIEW_OVERRIDE='<the captain's reason>' on one
# landing invocation lands a task the gate would refuse. It is per invocation and
# never a stored default. The override is logged before landing proceeds, as one
# line in data/<id>/ship-review-overrides.log (which survives teardown) and one
# `SHIP REVIEW OVERRIDE:` line on stderr; if the log line cannot be written, the
# landing is refused. A blank reason is refused, and the override never repairs a
# malformed gate file.

fm_ship_review_config_dir() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:?FM_HOME must be set}/config}"
}

# Print the substituted review text for a ship task. Returns 1 when the home has
# no review text configured, 2 when the file exists but cannot be read.
fm_ship_review_text() {  # <task-id> <branch> <status-file>
  local id=$1 branch=$2 status_file=$3 file text
  file="$(fm_ship_review_config_dir)/ship-review.md"
  [ -e "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file exists but is not a readable file; fix or remove it" >&2
    return 2
  fi
  text=$(cat "$file") || return 2
  # Quoted replacements keep & and backslashes literal on every Bash version.
  text=${text//"{TASK_ID}"/"$id"}
  text=${text//"{BRANCH}"/"$branch"}
  text=${text//"{STATUS_FILE}"/"$status_file"}
  printf '%s\n' "$text"
}

# 0 when the gate is required, 1 when it is off or unconfigured, 2 (with a
# diagnostic on stderr) when the gate file is unreadable or malformed.
fm_ship_review_gate_required() {
  local file first=
  file="$(fm_ship_review_config_dir)/ship-review-gate"
  [ -e "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "REFUSED: ship review gate $file exists but is not a readable file; fix it to 'required' or 'off'" >&2
    return 2
  fi
  IFS= read -r first < "$file" || true
  first=${first%$'\r'}
  case "$first" in
    required) return 0 ;;
    off) return 1 ;;
    *)
      echo "REFUSED: ship review gate $file has first line '$first'; it must be 'required' or 'off'" >&2
      return 2
      ;;
  esac
}

# Print why the task's review record does not satisfy the gate, or nothing and
# return 0 when it does.
fm_ship_review_missing() {  # <status-file>
  local status_file=$1 line path
  if [ ! -f "$status_file" ]; then
    printf 'no "review: passed <report path>" line, because there is no status log at %s\n' "$status_file"
    return 1
  fi
  line=$(grep -E '^review:' "$status_file" 2>/dev/null | tail -1)
  line=${line%$'\r'}
  if [ -z "$line" ]; then
    printf 'no "review: passed <report path>" line in %s\n' "$status_file"
    return 1
  fi
  case "$line" in
    'review: passed '?*) ;;
    *)
      printf 'the latest review line in %s is "%s", not "review: passed <report path>"\n' "$status_file" "$line"
      return 1
      ;;
  esac
  path=${line#review: passed }
  path=${path%"${path##*[![:space:]]}"}
  case "$path" in
    /*) ;;
    *)
      printf 'the review report path "%s" in %s is not absolute\n' "$path" "$status_file"
      return 1
      ;;
  esac
  if [ ! -f "$path" ] || [ ! -s "$path" ]; then
    printf 'the review report %s named in %s does not exist or is empty\n' "$path" "$status_file"
    return 1
  fi
  return 0
}

# The landing gate. Returns 0 when landing may proceed, 1 when it must not.
fm_ship_review_gate() {  # <task-id> <status-file> <data-dir> <caller-name>
  local id=$1 status_file=$2 data=$3 caller=$4 required=0 missing reason log stamp
  fm_ship_review_gate_required || required=$?
  case "$required" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  missing=$(fm_ship_review_missing "$status_file") && return 0
  reason=${FM_SHIP_REVIEW_OVERRIDE:-}
  if [ -z "${reason//[[:space:]]/}" ]; then
    if [ -n "${FM_SHIP_REVIEW_OVERRIDE+x}" ]; then
      echo "REFUSED: FM_SHIP_REVIEW_OVERRIDE is set but blank; an override must state the captain's reason" >&2
    fi
    echo "REFUSED: task $id has no completed ship review: $missing." >&2
    echo "The worker must finish the review step in its instructions, then append 'review: passed <absolute report path>' to $status_file before landing." >&2
    echo "Only on the captain's explicit word, retry with FM_SHIP_REVIEW_OVERRIDE='<the captain's reason>'; the override is logged." >&2
    return 1
  fi
  reason=$(printf '%s' "$reason" | tr '\n\r' '  ')
  log="$data/$id/ship-review-overrides.log"
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! mkdir -p "$data/$id" 2>/dev/null \
    || ! printf '%s %s task=%s missing=[%s] reason=%s\n' "$stamp" "$caller" "$id" "$missing" "$reason" >> "$log" 2>/dev/null; then
    echo "REFUSED: cannot write the ship review override log $log; an override is never silent" >&2
    return 1
  fi
  echo "SHIP REVIEW OVERRIDE: landing task $id without a completed review ($missing); reason: $reason; logged to $log" >&2
  return 0
}
