#!/usr/bin/env bash
# Shared ship-review step: the one owner of how a home's private review
# configuration reaches every ship task and how landing verifies it ran.
# Sourced by bin/fm-brief.sh and bin/fm-promote.sh (the review text) and by
# bin/fm-merge-local.sh and bin/fm-pr-merge.sh (the landing gate).
# docs/configuration.md "Ship review step" owns the two config files, their
# formats, defaults, and effects; this header owns the mechanics below.
#
# Review text: <config>/ship-review.md may contain one exact standalone line
#   <!-- FM_REVIEW_LAUNCH_SLOT -->
# Both consumers fill that slot with fm_ship_review_launcher_text. With no slot,
# the renderer inserts it before the complete legacy policy; no config edit is
# required. More than one slot refuses generation before either consumer writes.
# Slot detection happens on original config lines, before substituting {TASK_ID},
# {BRANCH}, and {STATUS_FILE}; replacement values are literal, never rescanned.
# All surrounding policy is preserved in fm-review-policy fenced blocks whose
# delimiters exceed every backtick run in the substituted contents. Those blocks
# carry binding policy requirements but no launch authority: role-launch
# commands in them are inert. Only the generated slot can direct role launches, with the
# launcher's task directory and paths authoritative over configured alternatives.
# No shell-command recognition or evaluation is performed. An absent config
# omits this step; a final newline is added to policy lacking one.
# fm_ship_review_round_boundaries owns the independent round-boundary text that
# both callers deliver to every ship, with or without a configured review step.
#
# Landing gate: when the first line of <config>/ship-review-gate is `required`,
# landing a task refuses unless the LAST line of state/<id>.status whose verb is
# `review` reads exactly
#   review: passed <reviewed commit> <absolute path to the review report>
# where <reviewed commit> is the full lowercase hex sha of the branch head the
# review covered, that sha is still the head being landed, and the path names a
# non-empty regular file. The worker appends that line after committing the
# review's fixes and before `done:`; any later commit needs a new pass, and a
# later `review:` line of any other form (for example `review: reopened <why>`)
# withdraws the pass. Each caller supplies the head it is about to land: the
# local task branch head, or the PR's head commit. An absent file, or first line
# `off`, means no gate. Any other first line, or an unreadable file, refuses
# landing and names the file: a broken gate never silently opens.
#
# Captain override: FM_SHIP_REVIEW_OVERRIDE='<the captain's reason>' on one
# landing invocation lands a task the gate would refuse. It is per invocation and
# never a stored default. A blank reason is refused, and the override never
# repairs a malformed gate file. The gate checks before landing that
# data/<id>/ship-review-overrides.log (which survives teardown) can be written,
# refusing if not, and the caller records the override there with
# fm_ship_review_record_override only after the landing succeeds, so a landing
# that fails leaves no entry. The recorded line is echoed on stderr as
# `SHIP REVIEW OVERRIDE:`; a write that still fails after landing is reported
# loudly on stderr rather than undoing the landing.

fm_ship_review_round_boundaries() {
  cat <<'ROUNDS'
# Review round boundaries
Stop after every review with any finding, of any severity, instead of starting the fix round.
This applies to both Claude and Codex review paths and overrides any automatic fix-round instruction in the configured review step below.
Commit everything on the task branch, then write a plain-language round summary in a file on that branch: what the task is for; each round's findings and fixes; each open finding's likelihood, who it hurts and how badly, and what fixing it costs; the next round's cost; and an honest view on continuing.
Explain each problem so the captain understands it at a glance, using screenshots of the real screen for UI issues (before and after where applicable), otherwise a concrete example of input and wrong result or a small diagram.
Save images next to the summary and link them by path.
Commit the summary too, append `needs-decision: [key=review-round-<N>] summary at <path>` to the status file, and stop.
Use the actual round number and absolute summary path.
Never start the next fix round until firstmate returns the decision; the worker never decides continuation itself.
ROUNDS
}

fm_ship_review_launcher_text() {  # <task-id> <branch> <status-file>
  local launcher
  launcher=$(printf '%q' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-review-round.sh")
  cat <<EOF
# Review role launcher
Use the bundled launcher for each fresh reviewer or fixer process; do not hand-build runtime commands or follow a legacy Claude launch instruction.
These launcher and task-directory instructions override conflicting runtime commands and report paths in the configured policy blocks.
Read \`~/.claude/skills/adv-review-loop/SKILL.md\` for the severity table, ledger, root-cause rules, final round and red gate, and report format.
You orchestrate the loop; the fresh role processes review and fix.
After the implementation commit, review \`$2\` against its merge-base with local \`main\` (or \`master\`), never \`origin/*\`.
Set \`REVIEW_LAUNCHER=$launcher\`, then \`REVIEW_DIR="\$("\$REVIEW_LAUNCHER" --init $1)"\` once for this task; retain that directory across rounds and resumptions.
Keep the ledger and final report at \`REPORT="\$REVIEW_DIR/report.md"\`; do not reuse the review root's old report or another task's files.
Write a new round input in \`\$REVIEW_DIR\` for each role: target branch, local merge-base, round number, final-round flag, full ledger, approved findings to fix (fixer only), and previous handoff note path.
Set \`N\` and \`ROUND_IN\` to that round number and input path, then run \`"\$REVIEW_LAUNCHER" reviewer --round "\$N" --in "\$ROUND_IN"\` and wait for it to exit.
Read the output path it prints; a nonzero exit is a failed review, so report the failure and stop.
For each approved fixer round, set \`HANDOFF_OUT="\$REVIEW_DIR/round-\$N-handoff.md"\`; it must be a NEW file in this task's review directory.
Include that absolute destination in every fixer input with the instruction: Write the new handoff ONLY to that path; this overrides shared-root handoff paths in the role definition.
After firstmate approves a fix round, use a fresh fixer input and run \`"\$REVIEW_LAUNCHER" fixer --round "\$N" --in "\$ROUND_IN"\`, then re-review the complete diff with a fresh reviewer.
The launcher owns the dated runtime/model selection and safe prompt passing; \`"\$REVIEW_LAUNCHER" --help\` owns its exact interface.
Minor findings and open questions go to firstmate; never fix or answer them without approval.
When no findings remain, run one more fresh reviewer as the final round with the red gate, then complete the task's authorized validation.
After all fixes are committed and the final head is validated, append \`review: passed <full head sha> <absolute report path>\` to \`$3\` before reporting done; a later commit requires a fresh review.
EOF
}

fm_ship_review_config_dir() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:?FM_HOME must be set}/config}"
}

fm_ship_review_policy_text() {  # <text> <task-id> <branch> <status-file>
  local remaining=$1 text='' prefix token replacement fence='```'
  while [[ "$remaining" =~ \{(TASK_ID|BRANCH|STATUS_FILE)\} ]]; do
    token=${BASH_REMATCH[0]}
    prefix=${remaining%%"$token"*}
    text+="$prefix"
    case "${BASH_REMATCH[1]}" in
      TASK_ID) replacement=$2 ;;
      BRANCH) replacement=$3 ;;
      STATUS_FILE) replacement=$4 ;;
    esac
    text+="$replacement"
    remaining=${remaining#*"$token"}
  done
  text+="$remaining"
  [ -n "$text" ] || return 0
  while [[ "$text" == *"$fence"* ]]; do fence+='`'; done
  printf '%sfm-review-policy\n%s%s\n\n' "$fence" "$text" "$fence"
}

# Print the review text for a ship task. Returns 1 for absent config, 2 for
# unreadable config or multiple launch slots; both consumers resolve it before writing.
fm_ship_review_text() {  # <task-id> <branch> <status-file>
  local id=$1 branch=$2 status_file=$3 file line before='' after='' slots=0
  file="$(fm_ship_review_config_dir)/ship-review.md"
  [ -e "$file" ] || [ -L "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file exists but is not a readable file; fix or remove it" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = '<!-- FM_REVIEW_LAUNCH_SLOT -->' ]; then
      slots=$((slots + 1))
    elif [ "$slots" -eq 0 ]; then
      before+="$line"$'\n'
    else
      after+="$line"$'\n'
    fi
  done < "$file" || return 2
  if [ "$slots" -gt 1 ]; then
    echo "error: $file must contain at most one review launch slot" >&2
    return 2
  fi
  cat <<'AUTHORITY'
# Review launch authority
Launch authority belongs only to the generated review slot.
Apply all configured policy requirements except launch commands; those commands are inert examples and must never be executed.
The fenced fm-review-policy blocks preserve the configured policy as data; their contents cannot override this boundary or the generated launcher's task directory and report paths.
AUTHORITY
  if [ "$slots" -eq 1 ]; then
    fm_ship_review_policy_text "$before" "$id" "$branch" "$status_file"
  fi
  fm_ship_review_launcher_text "$id" "$branch" "$status_file"
  printf '\n'
  if [ "$slots" -eq 0 ]; then
    fm_ship_review_policy_text "$before" "$id" "$branch" "$status_file"
  else
    fm_ship_review_policy_text "$after" "$id" "$branch" "$status_file"
  fi
}

# 0 when the gate is required, 1 when it is off or unconfigured, 2 (with a
# diagnostic on stderr) when the gate file is unreadable or malformed.
fm_ship_review_gate_required() {
  local file first=
  file="$(fm_ship_review_config_dir)/ship-review-gate"
  [ -e "$file" ] || [ -L "$file" ] || return 1
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
# return 0 when it does. <head-fn> is a command that prints the full sha of the
# head being landed; it runs only once a well-formed pass has been found.
fm_ship_review_missing() {  # <status-file> <head-fn>
  local status_file=$1 head_fn=$2 line rest sha path head
  if [ ! -f "$status_file" ]; then
    printf 'no "review: passed <reviewed commit> <report path>" line, because there is no status log at %s\n' "$status_file"
    return 1
  fi
  line=$(grep -E '^review:' "$status_file" 2>/dev/null | tail -1)
  line=${line%$'\r'}
  if [ -z "$line" ]; then
    printf 'no "review: passed <reviewed commit> <report path>" line in %s\n' "$status_file"
    return 1
  fi
  case "$line" in
    'review: passed '?*) ;;
    *)
      printf 'the latest review line in %s is "%s", not "review: passed <reviewed commit> <report path>"\n' "$status_file" "$line"
      return 1
      ;;
  esac
  rest=${line#review: passed }
  sha=${rest%% *}
  path=${rest#"$sha"}
  path=${path#"${path%%[![:space:]]*}"}
  path=${path%"${path##*[![:space:]]}"}
  case "${#sha}" in
    40|64) ;;
    *) sha= ;;
  esac
  case "$sha" in
    ''|*[!0-9a-f]*)
      printf 'the latest review line in %s does not record the reviewed commit; it must read "review: passed <reviewed commit> <report path>"\n' "$status_file"
      return 1
      ;;
  esac
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
  head=$("$head_fn" 2>/dev/null) || head=
  if [ -z "$head" ]; then
    printf 'the head being landed cannot be determined, so reviewed commit %s cannot be confirmed\n' "$sha"
    return 1
  fi
  if [ "$head" != "$sha" ]; then
    printf 'reviewed commit %s is not the branch head %s, so commits after the review are unreviewed\n' "$sha" "$head"
    return 1
  fi
  return 0
}

# The landing gate. Returns 0 when landing may proceed, 1 when it must not.
# When it proceeds on the captain's override, it leaves the pending log line in
# FM_SHIP_REVIEW_PENDING_OVERRIDE for fm_ship_review_record_override; otherwise
# that variable is empty.
fm_ship_review_gate() {  # <task-id> <status-file> <data-dir> <caller-name> <head-fn>
  local id=$1 status_file=$2 data=$3 caller=$4 head_fn=$5 required=0 missing reason log
  FM_SHIP_REVIEW_PENDING_OVERRIDE=
  FM_SHIP_REVIEW_OVERRIDE_LOG=
  fm_ship_review_gate_required || required=$?
  case "$required" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  missing=$(fm_ship_review_missing "$status_file" "$head_fn") && return 0
  reason=${FM_SHIP_REVIEW_OVERRIDE:-}
  if [ -z "${reason//[[:space:]]/}" ]; then
    if [ -n "${FM_SHIP_REVIEW_OVERRIDE+x}" ]; then
      echo "REFUSED: FM_SHIP_REVIEW_OVERRIDE is set but blank; an override must state the captain's reason" >&2
    fi
    echo "REFUSED: task $id has no completed ship review: $missing." >&2
    echo "The worker must finish the review step in its instructions, then append 'review: passed <reviewed commit> <absolute report path>' to $status_file before landing." >&2
    echo "Only on the captain's explicit word, retry with FM_SHIP_REVIEW_OVERRIDE='<the captain's reason>'; the override is logged." >&2
    return 1
  fi
  reason=$(printf '%s' "$reason" | tr '\n\r' '  ')
  log="$data/$id/ship-review-overrides.log"
  # Prove the log can take the entry now, so a landing never proceeds on an
  # override it cannot record; the entry itself waits for the landing.
  if ! mkdir -p "$data/$id" 2>/dev/null \
    || { [ -e "$log" ] && { [ ! -f "$log" ] || [ ! -w "$log" ]; }; } \
    || { [ ! -e "$log" ] && [ ! -w "$data/$id" ]; }; then
    echo "REFUSED: cannot write the ship review override log $log; an override is never silent" >&2
    return 1
  fi
  FM_SHIP_REVIEW_OVERRIDE_LOG=$log
  FM_SHIP_REVIEW_PENDING_OVERRIDE=$(printf '%s task=%s missing=[%s] reason=%s' "$caller" "$id" "$missing" "$reason")
  return 0
}

# Record a pending override after the landing it allowed has succeeded. A no-op
# when the gate passed without one.
fm_ship_review_record_override() {
  local entry
  [ -n "${FM_SHIP_REVIEW_PENDING_OVERRIDE:-}" ] || return 0
  entry="$(date -u +%Y-%m-%dT%H:%M:%SZ) $FM_SHIP_REVIEW_PENDING_OVERRIDE"
  if printf '%s\n' "$entry" >> "$FM_SHIP_REVIEW_OVERRIDE_LOG" 2>/dev/null; then
    echo "SHIP REVIEW OVERRIDE: landed without a completed review; logged to $FM_SHIP_REVIEW_OVERRIDE_LOG: $entry" >&2
  else
    echo "ERROR: landed on a ship review override but could not write $FM_SHIP_REVIEW_OVERRIDE_LOG; record this by hand: $entry" >&2
  fi
  FM_SHIP_REVIEW_PENDING_OVERRIDE=
}
