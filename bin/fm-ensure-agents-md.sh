#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# CLAUDE.md is the real project-intrinsic knowledge file; AGENTS.md is a
# relative symlink to it for compatibility. Creates a minimal CLAUDE.md skeleton
# when neither file exists, promotes a real AGENTS.md file when it is the only
# file present, reverses a legacy CLAUDE.md -> AGENTS.md pair (including one
# left dangling by a deleted AGENTS.md), and refuses to clobber distinct real
# files or wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project CLAUDE.md files, injecting it idempotently into created skeletons,
# promoted AGENTS.md files, and any existing CLAUDE.md that still lacks it.
# Refuses case-variant memory files such as lowercase agents.md or claude.md,
# because the AGENTS.md symlink must carry the uppercase literal CLAUDE.md target
# portably across case-sensitive and case-insensitive filesystems (issue #389).
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# Idempotently append the canonical self-governance section to CLAUDE.md when it
# is absent. Sets MAINT_INJECTED=1 when it appends and 0 when the section is
# already present, so callers can report whether the file changed.
MAINT_INJECTED=0
ensure_maintenance_section() {
  MAINT_INJECTED=0
  if grep -Fqx '## Maintaining this file' "$CLAUDE" ||
    grep -Fqx $'## Maintaining this file\r' "$CLAUDE"; then
    return 0
  fi
  local eol=$'\n' sep=''
  if LC_ALL=C grep -q $'\r$' "$CLAUDE"; then
    eol=$'\r\n'
  fi
  if [ -s "$CLAUDE" ]; then
    if [ -n "$(tail -c 1 "$CLAUDE")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$CLAUDE"
  MAINT_INJECTED=1
}

write_skeleton() {
  cat > "$CLAUDE" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

is_correct_agents_symlink() {
  [ -L "$AGENTS" ] || return 1
  target=$(readlink "$AGENTS")
  case "$target" in
    "$CLAUDE"|"./$CLAUDE") return 0 ;;
  esac
  [ -e "$CLAUDE" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$AGENTS" "$CLAUDE" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

is_legacy_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Refuse case-variant memory files (issue #389). On a case-insensitive filesystem
# a lowercase agents.md or claude.md satisfies the uppercase existence tests
# below, so the script could emit an uppercase-literal symlink that collides or
# dangles once the tree is checked out on a case-sensitive filesystem. Reading
# the real directory entries catches the mismatch on both filesystem kinds;
# surface it for manual reconciliation instead of linking blindly.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  case "$entry" in
    [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
      [ "$entry" = "$AGENTS" ] && continue
      echo "conflict: memory link is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so it links to CLAUDE.md portably" >&2
      exit 1
      ;;
    [Cc][Ll][Aa][Uu][Dd][Ee].[Mm][Dd])
      [ "$entry" = "$CLAUDE" ] && continue
      echo "conflict: memory file is named $entry in $DIR but the convention is CLAUDE.md; rename it to CLAUDE.md so AGENTS.md links portably" >&2
      exit 1
      ;;
  esac
done

if [ -L "$CLAUDE" ] && [ -f "$AGENTS" ] && is_legacy_claude_symlink; then
  rm "$CLAUDE"
  mv "$AGENTS" "$CLAUDE"
  ensure_maintenance_section
  ln -s "$CLAUDE" "$AGENTS"
  echo "promoted: reversed legacy CLAUDE.md -> AGENTS.md to AGENTS.md -> CLAUDE.md in $DIR"
  exit 0
fi
if [ -L "$CLAUDE" ] && is_legacy_claude_symlink && [ ! -e "$AGENTS" ] && [ ! -L "$AGENTS" ]; then
  rm "$CLAUDE"
  write_skeleton
  ln -s "$CLAUDE" "$AGENTS"
  echo "created: replaced dangling legacy CLAUDE.md -> AGENTS.md with CLAUDE.md and AGENTS.md -> CLAUDE.md in $DIR"
  exit 0
fi
if [ -L "$CLAUDE" ]; then
  echo "conflict: CLAUDE.md is a symlink in $DIR; expected CLAUDE.md to be the real file" >&2
  exit 1
fi
if [ -e "$CLAUDE" ] && [ ! -f "$CLAUDE" ]; then
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$CLAUDE" ]; then
  if [ -L "$AGENTS" ]; then
    if is_correct_agents_symlink; then
      ensure_maintenance_section
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to CLAUDE.md in $DIR"
      else
        echo "unchanged: CLAUDE.md with AGENTS.md -> CLAUDE.md in $DIR"
      fi
      exit 0
    fi
    echo "conflict: AGENTS.md is a symlink in $DIR but does not point to CLAUDE.md" >&2
    exit 1
  fi
  if [ ! -e "$AGENTS" ]; then
    ensure_maintenance_section
    ln -s "$CLAUDE" "$AGENTS"
    if [ "$MAINT_INJECTED" -eq 1 ]; then
      echo "updated: added ## Maintaining this file to CLAUDE.md and symlinked AGENTS.md -> CLAUDE.md in $DIR"
    else
      echo "symlinked: AGENTS.md -> CLAUDE.md in $DIR"
    fi
    exit 0
  fi
  if [ -f "$AGENTS" ]; then
    echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR; reconcile them manually" >&2
    exit 1
  fi
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

if [ -L "$AGENTS" ]; then
  if is_correct_agents_symlink; then
    write_skeleton
    echo "created: CLAUDE.md and kept AGENTS.md -> CLAUDE.md in $DIR"
    exit 0
  fi
  echo "conflict: AGENTS.md is a symlink in $DIR but CLAUDE.md is missing and the link does not point to CLAUDE.md" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  if [ -f "$AGENTS" ]; then
    mv "$AGENTS" "$CLAUDE"
    ensure_maintenance_section
    ln -s "$CLAUDE" "$AGENTS"
    echo "promoted: moved AGENTS.md to CLAUDE.md and symlinked AGENTS.md -> CLAUDE.md in $DIR"
    exit 0
  fi
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
ln -s "$CLAUDE" "$AGENTS"
echo "created: CLAUDE.md and AGENTS.md -> CLAUDE.md in $DIR"
