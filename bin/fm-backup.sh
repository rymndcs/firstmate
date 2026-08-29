#!/usr/bin/env bash
# fm-backup.sh - capture one restorable archive of a complete firstmate setup:
# the operational home with its private data/, config/, and state/, the
# account-level agent rules, hooks, commands, and skills under ~/.claude, the
# harness rule symlinks that point at them, every project clone's complete git
# history, and every repository's local git configuration, hooks, and exclude
# file.
#
# bin/fm-restore.sh is the only consumer, and the two are one contract: the
# FORMAT value below owns the archive layout, and restore refuses an archive
# whose FORMAT it does not implement.
#
# Why git bundle rather than a copy of the working files
#   The operational home and the project clones both carry commits that exist on
#   no remote (a fleet's own history, and project branches whose only "remote" is
#   a local mirror). An archive of working files alone loses all of it. `git
#   bundle create --all` takes one consistent snapshot of every ref into a single
#   self-contained file that `git fetch` reads natively, so restore needs no
#   extra tooling. Copying .git/ wholesale was rejected: it carries the index,
#   reflogs, and lock files, and can be captured torn if the repository is
#   written while the backup runs, whereas a bundle carries exactly the reachable
#   history and resolves its refs once.
#
# Usage:
#   fm-backup.sh [--out <path>] [--home <dir>] [--user-home <dir>]
#                [--include-secrets] [--list] [--help]
#
# Options:
#   --out <path>        archive to write (default: ./fm-backup-<host>-<stamp>.tar.gz).
#                       Created with mode 0600 and never widened.
#   --home <dir>        firstmate operational home to capture
#                       (default: $FM_HOME, else this checkout's root).
#   --user-home <dir>   account home holding .claude and the harness rule dirs
#                       (default: $HOME).
#   --include-secrets   also capture the credential-class files listed below.
#                       Without it they are named in the report as SKIPPED, never
#                       silently dropped.
#   --list              run the whole capture, print the report, then discard it
#                       instead of writing an archive. Every file is read exactly
#                       as a real run reads it, so it is a dry run that proves the
#                       capture works rather than a guess at what it would do.
#   -h, --help          print this header.
#
# Report
#   Every item prints one line to stdout as "<STATUS> <item> - <detail>" with
#   STATUS one of INCLUDED, SKIPPED, or EMPTY, and the same lines are stored in
#   the archive as INVENTORY. Nothing is captured or omitted without a line.
#
# Credential class (excluded unless --include-secrets)
#   <user-home>/.claude/.credentials.json   harness OAuth tokens
#   <user-home>/.claude.json                MCP server definitions and their env
#   <home>/.env*                            firstmate home secrets (root only)
#   <home>/projects/<name>/.env*            per-project secrets (repo root only)
#   The archive is mode 0600 either way. No encryption is applied: choosing where
#   an archive containing these may be stored is the captain's call, not this
#   script's.
#
# Excluded because it regenerates
#   Working trees (home and project untracked files):
#     node_modules, tmp, public/assets, .ruby-lsp, .playwright-mcp, __pycache__
#   Never traversed at all:
#     <user-home>/.treehouse         pool worktrees, recreated on demand
#     <user-home>/.no-mistakes       local mirror repos; every ref they hold is
#                                    already in this archive's bundles
#     project files matched by the project's own .gitignore, except the
#     credential class above
#   Under <user-home>/.claude only these are captured, so its runtime bulk -
#   cache, paste-cache, file-history, downloads, projects, session-env, security,
#   sessions, shell-snapshots, telemetry, backups, history.jsonl, and the plugin
#   caches and marketplaces - is left out by construction:
#     CLAUDE.md, settings.json, settings.local.json, hooks/, commands/, skills/,
#     agents/, plugins/installed_plugins.json, plugins/known_marketplaces.json
#   <user-home>/.agents is captured whole: it is the shared cross-runtime skills
#   root that <user-home>/.claude/skills links into, so leaving it out would
#   restore those links dangling.
#
# Symlinks are stored as symlinks. Any whose target is an absolute path inside
# the captured account home is additionally recorded in the archive's SYMLINKS
# file so restore can re-anchor it to the restore destination instead of leaving
# it pointing at the machine the backup came from.
set -eu

FORMAT=fm-backup.v1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

SRC_FM_HOME="${FM_HOME:-$FM_ROOT}"
SRC_USER_HOME="${HOME:-}"
OUT=
INCLUDE_SECRETS=0
LIST_ONLY=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-backup: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -gt 1 ] || die "--out requires a path"; OUT=$2; shift 2 ;;
    --out=*) OUT=${1#--out=}; shift ;;
    --home) [ "$#" -gt 1 ] || die "--home requires a directory"; SRC_FM_HOME=$2; shift 2 ;;
    --home=*) SRC_FM_HOME=${1#--home=}; shift ;;
    --user-home) [ "$#" -gt 1 ] || die "--user-home requires a directory"; SRC_USER_HOME=$2; shift 2 ;;
    --user-home=*) SRC_USER_HOME=${1#--user-home=}; shift ;;
    --include-secrets) INCLUDE_SECRETS=1; shift ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$SRC_USER_HOME" ] || die "no account home: set HOME or pass --user-home"
[ -d "$SRC_FM_HOME" ] || die "firstmate home not found: $SRC_FM_HOME"
[ -d "$SRC_USER_HOME" ] || die "account home not found: $SRC_USER_HOME"
SRC_FM_HOME=$(cd "$SRC_FM_HOME" && pwd)
SRC_USER_HOME=$(cd "$SRC_USER_HOME" && pwd)
[ -d "$SRC_FM_HOME/.git" ] || die "not a firstmate home (no .git): $SRC_FM_HOME"

command -v git >/dev/null || die "git is required"
command -v tar >/dev/null || die "tar is required"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
HOSTNAME_SHORT=$(hostname 2>/dev/null | cut -d. -f1)
[ -n "$HOSTNAME_SHORT" ] || HOSTNAME_SHORT=unknown-host
ROOTNAME="fm-backup-$HOSTNAME_SHORT-$STAMP"
[ -n "$OUT" ] || OUT="$PWD/$ROOTNAME.tar.gz"

# Working-tree exclusions, one owner. EXCLUDE_FRAGMENTS is the list; the tar
# patterns prune them out of a directory walk, and EXCLUDE_RE drops them out of
# an explicit file list, where a --exclude pattern for the directory has nothing
# to match against.
EXCLUDE_FRAGMENTS="node_modules tmp .ruby-lsp .playwright-mcp __pycache__ public/assets"
TAR_EXCLUDES=()
EXCLUDE_RE=
for frag in $EXCLUDE_FRAGMENTS; do
  TAR_EXCLUDES+=("--exclude=./$frag" "--exclude=*/$frag")
  escaped=$(printf '%s' "$frag" | sed 's/\./\\./g')
  if [ -z "$EXCLUDE_RE" ]; then
    EXCLUDE_RE="$escaped"
  else
    EXCLUDE_RE="$EXCLUDE_RE|$escaped"
  fi
done
EXCLUDE_RE="(^|/)($EXCLUDE_RE)(/|\$)"
# Not a second owner of the list: the archive carries the one this run used, so
# bin/fm-restore.sh compares destination work against the same exclusions
# without re-spelling them.

# Drop excluded paths from an explicit list on stdin.
filter_excluded() {
  grep -Ev "$EXCLUDE_RE" || true
}

# The <user-home>/.claude allowlist, one owner.
CLAUDE_KEEP="CLAUDE.md settings.json settings.local.json hooks commands skills agents plugins/installed_plugins.json plugins/known_marketplaces.json"

# Account-level directories captured whole because they are small, shared, and
# linked into from .claude: losing one leaves a dangling link on the restore.
GLOBAL_DIRS=".agents"

# Account-level agent rule files outside .claude, usually symlinks into it.
HARNESS_RULES=".codex/AGENTS.md .codex/CLAUDE.md .pi/agent/AGENTS.md .pi/agent/CLAUDE.md .opencode/AGENTS.md .grok/AGENTS.md .kimi/AGENTS.md"

# mktemp -d creates the staging root 0700 whatever the umask, so the capture is
# private while it is built. Inside it a normal umask keeps the directories this
# script has to create itself at their ordinary modes: every captured file and
# directory that exists at the source is written with the source's own mode, and
# the finished archive is narrowed to 0600 before a byte is written into it.
# Report labels name paths the way the captain reads them, relative to the
# account home. Held in a variable so it stays display text rather than a path
# the shell would try to expand.
ACCOUNT='~'

umask 022
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fm-backup.XXXXXX")
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT HUP INT TERM

PAYLOAD="$STAGE/$ROOTNAME"
mkdir -p "$PAYLOAD"
INVENTORY="$PAYLOAD/INVENTORY"
EXCLUDES_FILE="$PAYLOAD/EXCLUDES"
SYMLINKS="$PAYLOAD/SYMLINKS"
: >"$INVENTORY"
: >"$SYMLINKS"

note() {  # <status> <item> <detail>
  printf '%s %s - %s\n' "$1" "$2" "$3" | tee -a "$INVENTORY"
}

# Copy one tree with the shared exclusions, preserving modes and symlinks.
copy_tree() {  # <src-dir> <dst-dir>
  local src=$1 dst=$2
  mkdir -p "$dst"
  ( cd "$src" && tar -cf - ${TAR_EXCLUDES[@]+"${TAR_EXCLUDES[@]}"} . ) \
    | ( cd "$dst" && tar -xpf - )
}

# Record an absolute symlink target that lives inside the captured account home,
# so restore can re-anchor it. <archive-path> is relative to the payload root.
record_symlink() {  # <archive-path> <link-file>
  local archive_path=$1 link=$2 target
  [ -L "$link" ] || return 0
  target=$(readlink "$link")
  case "$target" in
    "$SRC_USER_HOME"/*)
      printf '%s\t~/%s\n' "$archive_path" "${target#"$SRC_USER_HOME"/}" >>"$SYMLINKS"
      ;;
  esac
}

# Record every absolute-into-the-account-home symlink inside a copied directory,
# not just a top-level one: a rules or skills directory routinely links out to a
# shared root, and a link left pointing at the source machine is a dangling link
# on the restored one.
record_symlinks_in() {  # <src-dir> <archive-prefix>
  local src=$1 prefix=$2 rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    record_symlink "$prefix/${rel#./}" "$src/${rel#./}"
  done <<EOF
$(cd "$src" && find . -type l 2>/dev/null || true)
EOF
}

# Bundle every ref of one repository. Prints the detail line, returns non-zero
# when the repository has no commits to bundle.
bundle_repo() {  # <repo-dir> <out-bundle>
  local repo=$1 out=$2 refs local_only
  git -C "$repo" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 1
  git -C "$repo" bundle create "$out" --all >/dev/null 2>&1 || return 1
  refs=$(git -C "$repo" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')
  # Commits on a local ref that no remote-tracking ref reaches: the work that
  # exists on this machine only, and the reason this archive carries history at
  # all rather than a copy of the checked-out files.
  local_only=$(git -C "$repo" rev-list --count --all --not --remotes 2>/dev/null || echo 0)
  printf '%s local branch(es), %s commit(s) on no remote, %s\n' \
    "$refs" "$local_only" "$(du -h "$out" | cut -f1 | tr -d ' ')"
}

# Capture a repository's local-only git settings: remotes and identity live in
# config, and hooks and info/exclude have no other copy anywhere.
copy_git_local() {  # <repo-dir> <dst-dir> <label>
  local repo=$1 dst=$2 label=$3 gitdir hooks n
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir)
  mkdir -p "$dst"
  if [ -f "$gitdir/config" ]; then
    cp -p "$gitdir/config" "$dst/config"
    note INCLUDED "$label git config" "remotes and local repository settings"
  fi
  if [ -f "$gitdir/info/exclude" ]; then
    cp -p "$gitdir/info/exclude" "$dst/info-exclude"
    note INCLUDED "$label git info/exclude" "local ignore rules, tracked nowhere"
  fi
  hooks=$(find "$gitdir/hooks" -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null | LC_ALL=C sort || true)
  if [ -n "$hooks" ]; then
    mkdir -p "$dst/hooks"
    n=0
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      cp -p "$h" "$dst/hooks/$(basename "$h")"
      n=$((n + 1))
    done <<EOF
$hooks
EOF
    note INCLUDED "$label git hooks" "$n hook(s), modes preserved"
  else
    note EMPTY "$label git hooks" "no non-sample hooks installed"
  fi
}

capture_secret() {  # <abs-path> <archive-dest> <label>
  local src=$1 dest=$2 label=$3
  [ -e "$src" ] || return 0
  if [ "$INCLUDE_SECRETS" -eq 1 ]; then
    mkdir -p "$(dirname "$dest")"
    cp -p "$src" "$dest"
    note INCLUDED "$label" "credential class, present in this archive (--include-secrets)"
  else
    note SKIPPED "$label" "credential class; re-run with --include-secrets to capture it"
  fi
}

if [ "$LIST_ONLY" -eq 1 ]; then
  note INFO "mode" "--list: capturing everything, then discarding it instead of writing an archive"
fi

printf '%s\n' "$EXCLUDE_FRAGMENTS" >"$EXCLUDES_FILE"

if [ "$LIST_ONLY" -eq 1 ]; then
  note INFO "mode" "--list: capturing everything, then discarding it instead of writing an archive"
fi

# ---------------------------------------------------------------- manifest ---
FM_HEAD=$(git -C "$SRC_FM_HOME" rev-parse HEAD 2>/dev/null || echo unknown)
{
  printf 'format=%s\n' "$FORMAT"
  printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host=%s\n' "$HOSTNAME_SHORT"
  printf 'source_user_home=%s\n' "$SRC_USER_HOME"
  printf 'source_fm_home=%s\n' "$SRC_FM_HOME"
  printf 'fm_home_basename=%s\n' "$(basename "$SRC_FM_HOME")"
  printf 'fm_head=%s\n' "$FM_HEAD"
  printf 'git_version=%s\n' "$(git --version)"
  printf 'include_secrets=%s\n' "$INCLUDE_SECRETS"
} >"$PAYLOAD/MANIFEST"

# ------------------------------------------------------------ account home ---
mkdir -p "$PAYLOAD/global"
if [ -d "$SRC_USER_HOME/.claude" ]; then
  for rel in $CLAUDE_KEEP; do
    src="$SRC_USER_HOME/.claude/$rel"
    if [ ! -e "$src" ] && [ ! -L "$src" ]; then
      note SKIPPED "$ACCOUNT/.claude/$rel" "not present on this machine"
      continue
    fi
    dst="$PAYLOAD/global/.claude/$rel"
    mkdir -p "$(dirname "$dst")"
    if [ -L "$src" ]; then
      cp -P "$src" "$dst"
      record_symlink "global/.claude/$rel" "$src"
      note INCLUDED "$ACCOUNT/.claude/$rel" "symlink to $(readlink "$src")"
    elif [ -d "$src" ]; then
      copy_tree "$src" "$dst"
      record_symlinks_in "$src" "global/.claude/$rel"
      count=$(find "$dst" -type f | wc -l | tr -d ' ')
      execs=$(find "$dst" -type f -perm -u+x | wc -l | tr -d ' ')
      note INCLUDED "$ACCOUNT/.claude/$rel" "$count file(s), $execs executable, modes preserved"
    else
      cp -p "$src" "$dst"
      note INCLUDED "$ACCOUNT/.claude/$rel" "$(wc -c <"$src" | tr -d ' ') bytes"
    fi
  done
else
  note SKIPPED "$ACCOUNT/.claude" "directory not present on this machine"
fi

for rel in $GLOBAL_DIRS; do
  src="$SRC_USER_HOME/$rel"
  if [ ! -d "$src" ]; then
    note SKIPPED "$ACCOUNT/$rel" "not present on this machine"
    continue
  fi
  copy_tree "$src" "$PAYLOAD/global/$rel"
  record_symlinks_in "$src" "global/$rel"
  note INCLUDED "$ACCOUNT/$rel" \
    "$(find "$src" -type f | wc -l | tr -d ' ') file(s), shared skills root that ~/.claude links into"
done

for rel in $HARNESS_RULES; do
  src="$SRC_USER_HOME/$rel"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    continue
  fi
  dst="$PAYLOAD/global/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$src" ]; then
    cp -P "$src" "$dst"
    record_symlink "global/$rel" "$src"
    note INCLUDED "$ACCOUNT/$rel" "symlink to $(readlink "$src"), restored as a symlink"
  else
    cp -p "$src" "$dst"
    note INCLUDED "$ACCOUNT/$rel" "regular file, $(wc -c <"$src" | tr -d ' ') bytes"
  fi
done

capture_secret "$SRC_USER_HOME/.claude/.credentials.json" \
  "$PAYLOAD/global/.claude/.credentials.json" "$ACCOUNT/.claude/.credentials.json"
capture_secret "$SRC_USER_HOME/.claude.json" \
  "$PAYLOAD/global/.claude.json" "$ACCOUNT/.claude.json"

note SKIPPED "$ACCOUNT/.treehouse" "pool worktrees, recreated on demand from the project clones"
note SKIPPED "$ACCOUNT/.no-mistakes" "local mirror repos; every ref they hold is in this archive's bundles"

# -------------------------------------------------------- operational home ---
mkdir -p "$PAYLOAD/home"
if detail=$(bundle_repo "$SRC_FM_HOME" "$PAYLOAD/home/repo.bundle"); then
  note INCLUDED "firstmate home history" "$detail"
else
  note SKIPPED "firstmate home history" "repository has no commits to bundle"
fi
copy_git_local "$SRC_FM_HOME" "$PAYLOAD/home/git" "firstmate home"

fm_branch=$(git -C "$SRC_FM_HOME" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
{
  printf 'branch=%s\n' "$fm_branch"
  printf 'sha=%s\n' "$FM_HEAD"
} >"$PAYLOAD/home/HEAD"

# The whole home working tree, minus projects/ (captured per project below) and
# .git/ (the bundle plus the local settings above own it). This is deliberately
# a complete copy rather than an enumeration: it is what makes uncommitted edits,
# every gitignored private directory, and files no list anticipated survive.
# The credential class is held out of the whole-tree copy so it can only ever
# enter the archive through capture_secret, which is the one place that honours
# --include-secrets and reports what it did.
FM_TREE_EXCLUDES=("--exclude=./projects" "--exclude=./.git" "--exclude=./.env" "--exclude=./.env.*")
(
  cd "$SRC_FM_HOME" \
    && tar -cf - "${FM_TREE_EXCLUDES[@]}" ${TAR_EXCLUDES[@]+"${TAR_EXCLUDES[@]}"} .
) | ( mkdir -p "$PAYLOAD/home/tree" && cd "$PAYLOAD/home/tree" && tar -xf - )
while IFS= read -r link; do
  [ -n "$link" ] || continue
  record_symlink "home/tree/${link#./}" "$SRC_FM_HOME/${link#./}"
done <<EOF
$(cd "$SRC_FM_HOME" && find . -type l -not -path './projects/*' -not -path './.git/*' 2>/dev/null || true)
EOF
# Files the home tracks but the captain has deleted without committing. The
# tree copy cannot express an absence, and the restore's checkout would bring
# them back, so the deletions are captured as their own list.
git -C "$SRC_FM_HOME" diff HEAD --name-only --diff-filter=D >"$PAYLOAD/home/deleted" 2>/dev/null \
  || : >"$PAYLOAD/home/deleted"
if [ -s "$PAYLOAD/home/deleted" ]; then
  note INCLUDED "home deleted-but-uncommitted files" \
    "$(wc -l <"$PAYLOAD/home/deleted" | tr -d ' ') tracked file(s) deleted in the working tree"
fi

for private in data config state; do
  if [ -d "$SRC_FM_HOME/$private" ]; then
    note INCLUDED "home $private/" \
      "$(find "$SRC_FM_HOME/$private" -type f | wc -l | tr -d ' ') file(s), $(du -sh "$SRC_FM_HOME/$private" | cut -f1 | tr -d ' ')"
  else
    note SKIPPED "home $private/" "not present in $SRC_FM_HOME"
  fi
done
note INCLUDED "home working tree" \
  "$(find "$PAYLOAD/home/tree" -type f | wc -l | tr -d ' ') file(s) including every gitignored private file, projects/ excluded"

home_secrets=0
for env in "$SRC_FM_HOME"/.env "$SRC_FM_HOME"/.env.*; do
  [ -f "$env" ] || continue
  home_secrets=$((home_secrets + 1))
  capture_secret "$env" "$PAYLOAD/home/tree/$(basename "$env")" "home $(basename "$env")"
done
if [ "$home_secrets" -eq 0 ]; then
  note EMPTY "home .env" "no credential file in this home"
fi

# ---------------------------------------------------------------- projects ---
mkdir -p "$PAYLOAD/projects"
project_count=0
if [ -d "$SRC_FM_HOME/projects" ]; then
  for proj in "$SRC_FM_HOME"/projects/*; do
    [ -d "$proj" ] || continue
    name=$(basename "$proj")
    if ! git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
      note SKIPPED "project $name" "not a git repository"
      continue
    fi
    project_count=$((project_count + 1))
    pdst="$PAYLOAD/projects/$name"
    mkdir -p "$pdst"

    if detail=$(bundle_repo "$proj" "$pdst/repo.bundle"); then
      note INCLUDED "project $name history" "$detail"
    else
      note SKIPPED "project $name history" "repository has no commits to bundle"
    fi

    copy_git_local "$proj" "$pdst/git" "project $name"

    pbranch=$(git -C "$proj" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    {
      printf 'branch=%s\n' "$pbranch"
      printf 'sha=%s\n' "$(git -C "$proj" rev-parse HEAD 2>/dev/null || echo unknown)"
    } >"$pdst/HEAD"

    git -C "$proj" diff HEAD --binary >"$pdst/dirty.patch" 2>/dev/null || : >"$pdst/dirty.patch"
    if [ -s "$pdst/dirty.patch" ]; then
      note INCLUDED "project $name uncommitted changes" \
        "$(git -C "$proj" diff HEAD --name-only | wc -l | tr -d ' ') modified file(s), stored as a patch"
    else
      note EMPTY "project $name uncommitted changes" "working tree matches HEAD"
    fi

    untracked_all=$(git -C "$proj" ls-files --others --exclude-standard 2>/dev/null || true)
    # Root-level .env* never rides along in the bulk copy: it is credential class
    # and reaches the archive only through capture_secret below.
    untracked=$(printf '%s' "$untracked_all" | filter_excluded | grep -Ev '^\.env($|\.)' || true)
    if [ -n "$untracked" ]; then
      mkdir -p "$pdst/tree"
      ( cd "$proj" && tar -cf - ${TAR_EXCLUDES[@]+"${TAR_EXCLUDES[@]}"} -T - <<EOF
$untracked
EOF
      ) | ( cd "$pdst/tree" && tar -xpf - )
      note INCLUDED "project $name untracked files" \
        "$(printf '%s\n' "$untracked" | wc -l | tr -d ' ') file(s) not ignored by the project"
    else
      note EMPTY "project $name untracked files" "nothing untracked outside the project's .gitignore"
    fi
    dropped=$(( $(printf '%s' "$untracked_all" | grep -c . || true) - $(printf '%s' "$untracked" | grep -c . || true) ))
    if [ "$dropped" -gt 0 ]; then
      note SKIPPED "project $name regenerable files" \
        "$dropped untracked path(s) under $EXCLUDE_FRAGMENTS"
    fi

    for env in "$proj"/.env "$proj"/.env.*; do
      [ -e "$env" ] || continue
      capture_secret "$env" "$pdst/secrets/$(basename "$env")" "project $name $(basename "$env")"
    done
  done
fi
note INCLUDED "projects" "$project_count repository/repositories captured"

# ----------------------------------------------------------------- archive ---
sort -o "$SYMLINKS" "$SYMLINKS"
note INCLUDED "symlink manifest" \
  "$(wc -l <"$SYMLINKS" | tr -d ' ') absolute link(s) recorded for re-anchoring on restore"

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '\nfm-backup: --list: capture completed and discarded, no archive written\n'
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
: >"$OUT"
chmod 600 "$OUT"
( cd "$STAGE" && tar -czf - "$ROOTNAME" ) >"$OUT"

printf '\n'
if [ "$INCLUDE_SECRETS" -eq 1 ]; then
  printf 'fm-backup: this archive CONTAINS credential files (see the SKIPPED/INCLUDED lines above).\n'
else
  printf 'fm-backup: this archive contains NO credential files; any found were reported SKIPPED above.\n'
fi
printf 'fm-backup: archive %s (%s, mode 0600)\n' "$OUT" "$(du -h "$OUT" | cut -f1 | tr -d ' ')"
printf 'fm-backup: restore it with bin/fm-restore.sh %s\n' "$OUT"
