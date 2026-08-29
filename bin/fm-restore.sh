#!/usr/bin/env bash
# fm-restore.sh - rebuild a complete firstmate setup from one bin/fm-backup.sh
# archive, as a drop-in replacement: the account-level agent rules, hooks,
# commands, and skills under ~/.claude with their executable bits intact, the
# harness rule symlinks recreated as symlinks pointed at the restored rules, the
# operational home with its private data/, config/, and state/, and every project
# clone rebuilt from its bundle with its full history, local remotes, git hooks,
# and any uncommitted work the backup found.
#
# bin/fm-backup.sh owns the archive layout and its FORMAT value; this script
# refuses an archive whose format it does not implement rather than restoring a
# partial setup from a layout it does not understand.
#
# Usage:
#   fm-restore.sh <archive.tar.gz> [--dest <dir>] [--force] [--dry-run] [--help]
#
# Options:
#   --dest <dir>   account home to restore into (default: $HOME). The operational
#                  home lands at <dir>/<the backup's home directory name>, and the
#                  agent rules at <dir>/.claude, so a scratch directory gives a
#                  complete verifiable restore that touches nothing live.
#   --force        allow restoring over an existing setup. Without it, an
#                  existing <dest>/.claude or operational home stops the restore
#                  and nothing is written.
#   --dry-run      print exactly what would be restored and write nothing.
#   -h, --help     print this header.
#
# Uncommitted work at the destination is never destroyed, --force included: a
# destination repository holding uncommitted work this archive does not already
# contain stops the restore before anything is written, naming the repository and
# the files. Land or set that work aside first, then re-run. Work the archive
# does carry is not at risk and does not block, so restoring the same archive
# twice is a no-op rather than a refusal.
#
# Symlinks whose target pointed inside the backed-up account home are re-anchored
# to --dest, so the harness rule files stay symlinks into the restored
# ~/.claude/CLAUDE.md instead of forking into separate copies that then drift.
# File modes come back exactly as captured, so a restored hook is executable and
# fires; a hook restored non-executable would silently never run, which is the
# failure this pair exists to prevent.
#
# Steps that cannot be automated - re-authentication, dependency installs, and
# any credential file the backup deliberately left out - are printed as a
# numbered list at the end. The list is derived from the archive, so it names
# what this particular restore still needs rather than a generic checklist.
set -eu

FORMAT_SUPPORTED=fm-backup.v1

ARCHIVE=
DEST="${HOME:-}"
FORCE=0
DRY_RUN=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-restore: %s\n' "$*" >&2
  exit 2
}

say() {
  printf '%s\n' "$*"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) [ "$#" -gt 1 ] || die "--dest requires a directory"; DEST=$2; shift 2 ;;
    --dest=*) DEST=${1#--dest=}; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *)
      [ -z "$ARCHIVE" ] || die "only one archive may be restored at a time"
      ARCHIVE=$1
      shift
      ;;
  esac
done

[ -n "$ARCHIVE" ] || die "usage: fm-restore.sh <archive.tar.gz> [--dest <dir>] (see --help)"
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
[ -n "$DEST" ] || die "no destination: set HOME or pass --dest"
ARCHIVE=$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")

command -v git >/dev/null || die "git is required"
command -v tar >/dev/null || die "tar is required"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-restore.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

tar -xzpf "$ARCHIVE" -C "$WORK"
PAYLOAD=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$PAYLOAD" ] || die "archive has no payload directory: $ARCHIVE"
[ -f "$PAYLOAD/MANIFEST" ] || die "archive has no MANIFEST; not an fm-backup archive: $ARCHIVE"

manifest_get() {  # <key>
  sed -n "s/^$1=//p" "$PAYLOAD/MANIFEST" | head -n 1
}

FORMAT=$(manifest_get format)
[ "$FORMAT" = "$FORMAT_SUPPORTED" ] \
  || die "archive format '$FORMAT' is not '$FORMAT_SUPPORTED'; use the fm-restore.sh that shipped with it"

SRC_USER_HOME=$(manifest_get source_user_home)
FM_BASENAME=$(manifest_get fm_home_basename)
CREATED=$(manifest_get created)
SRC_HOST=$(manifest_get host)
HAD_SECRETS=$(manifest_get include_secrets)
[ -n "$FM_BASENAME" ] || die "archive MANIFEST has no fm_home_basename"

# A dry run must write nothing at all, the destination directory included.
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$DEST"
fi
if [ -d "$DEST" ]; then
  DEST=$(cd "$DEST" && pwd)
else
  case "$DEST" in
    /*) : ;;
    *) DEST="$PWD/$DEST" ;;
  esac
fi
FM_DEST="$DEST/$FM_BASENAME"

say "fm-restore: archive $ARCHIVE"
say "fm-restore: taken $CREATED on $SRC_HOST from $SRC_USER_HOME"
say "fm-restore: restoring into $DEST (operational home: $FM_DEST)"
[ "$DRY_RUN" -eq 0 ] || say "fm-restore: --dry-run, nothing will be written"
say ""

# ---------------------------------------------------------------- preflight ---
# Two separate refusals. Clobbering a live setup is allowed with --force because
# it is what an in-place recovery needs. Destroying uncommitted work is not
# allowed at all, because no flag makes that recoverable.
blockers=0
if [ "$FORCE" -eq 0 ]; then
  for existing in "$DEST/.claude" "$FM_DEST"; do
    if [ -e "$existing" ]; then
      printf 'fm-restore: refusing to overwrite an existing setup at %s\n' "$existing" >&2
      blockers=$((blockers + 1))
    fi
  done
  if [ "$blockers" -gt 0 ]; then
    printf 'fm-restore: nothing was written. Re-run with --force to restore over it, or --dest <empty dir> to restore beside it.\n' >&2
    exit 3
  fi
fi

# The exclusion list the archive was built with, so a destination path the
# backup would never have captured is not mistaken for work at risk. The list
# has one owner, bin/fm-backup.sh, which writes it into every archive.
EXCLUDE_RE=
if [ -s "$PAYLOAD/EXCLUDES" ]; then
  while IFS= read -r frag; do
    [ -n "$frag" ] || continue
    escaped=$(printf '%s' "$frag" | sed 's/\./\\./g')
    if [ -z "$EXCLUDE_RE" ]; then EXCLUDE_RE="$escaped"; else EXCLUDE_RE="$EXCLUDE_RE|$escaped"; fi
  done <<EOF
$(tr ' ' '\n' <"$PAYLOAD/EXCLUDES")
EOF
  EXCLUDE_RE="(^|/)($EXCLUDE_RE)(/|\$)"
fi

# True when everything uncommitted at <repo> is byte-identical to the
# uncommitted work <payload> carries for it. That is the whole question the
# guard below has to answer: work the archive already holds is not work a
# restore can lose, while anything else is, whatever --force says.
uncommitted_matches_archive() {  # <repo-dir> <payload-repo-dir>
  local repo=$1 src=$2 here rel
  if [ -f "$src/dirty.patch" ]; then
    # A project: its tracked modifications were captured as a patch.
    here=$(mktemp "$WORK/dirty.XXXXXX")
    git -C "$repo" diff HEAD --binary >"$here" 2>/dev/null || : >"$here"
    cmp -s "$here" "$src/dirty.patch" || return 1
  else
    # The operational home: its whole working tree was captured, so a modified
    # file matches when its bytes match the captured copy, and a file missing on
    # both sides matches too.
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ -e "$repo/$rel" ]; then
        [ -f "$src/tree/$rel" ] || return 1
        cmp -s "$repo/$rel" "$src/tree/$rel" || return 1
      else
        [ ! -e "$src/tree/$rel" ] || return 1
      fi
    done <<EOF
$(git -C "$repo" diff HEAD --name-only 2>/dev/null || true)
EOF
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -n "$EXCLUDE_RE" ] && printf '%s\n' "$rel" | grep -Eq "$EXCLUDE_RE"; then
      continue
    fi
    [ -f "$src/tree/$rel" ] || return 1
    cmp -s "$repo/$rel" "$src/tree/$rel" || return 1
  done <<EOF
$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null || true)
EOF
  return 0
}

check_clean() {  # <repo-dir> <label> [payload-repo-dir]
  local repo=$1 label=$2 src=${3:-} dirty
  [ -d "$repo" ] || return 0
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  [ -n "$dirty" ] || return 0
  if [ -n "$src" ] && uncommitted_matches_archive "$repo" "$src"; then
    return 0
  fi
  printf 'fm-restore: %s has uncommitted work this archive does not contain, and it will not be overwritten:\n' "$label" >&2
  printf '%s\n' "$dirty" | sed 's/^/  /' >&2
  return 1
}

dirty_blockers=0
check_clean "$FM_DEST" "the operational home at $FM_DEST" "$PAYLOAD/home" \
  || dirty_blockers=$((dirty_blockers + 1))
if [ -d "$PAYLOAD/projects" ]; then
  for pdir in "$PAYLOAD"/projects/*; do
    [ -d "$pdir" ] || continue
    pname=$(basename "$pdir")
    check_clean "$FM_DEST/projects/$pname" "project $pname at $FM_DEST/projects/$pname" "$pdir" \
      || dirty_blockers=$((dirty_blockers + 1))
  done
fi
if [ "$dirty_blockers" -gt 0 ]; then
  printf 'fm-restore: nothing was written. Commit or set that work aside, then re-run.\n' >&2
  exit 4
fi

# ------------------------------------------------------------------ helpers ---
copy_into() {  # <src-dir> <dst-dir>  preserving modes and symlinks
  local src=$1 dst=$2
  [ "$DRY_RUN" -eq 0 ] || return 0
  mkdir -p "$dst"
  ( cd "$src" && tar -cf - . ) | ( cd "$dst" && tar -xpf - )
}

# Rebuild one repository from its bundle plus its captured local git settings.
restore_repo() {  # <payload-repo-dir> <dest-repo-dir> <label>
  local src=$1 dst=$2 label=$3 branch sha gitdir fallback
  branch=$(sed -n 's/^branch=//p' "$src/HEAD" 2>/dev/null | head -n 1)
  sha=$(sed -n 's/^sha=//p' "$src/HEAD" 2>/dev/null | head -n 1)

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would rebuild $label at $dst from its bundle, at ${branch:-detached $sha}"
    return 0
  fi

  mkdir -p "$dst"
  if [ ! -d "$dst/.git" ]; then
    git -C "$dst" init --quiet
  fi
  if [ -f "$src/repo.bundle" ]; then
    # Park HEAD on an unborn staging branch first: git refuses to fetch into the
    # branch a non-bare repository has checked out, and the branch the backup
    # recorded is exactly the one we are about to write.
    git -C "$dst" symbolic-ref HEAD refs/heads/fm-restore-staging
    # Restore every ref namespace the bundle carries, not just heads: tags,
    # remote-tracking refs, and any tool's own refs/<ns>/ come back at the exact
    # values the backup held, so the restored clone knows what was already
    # pushed instead of having to rediscover it from a network it may not have.
    git -C "$dst" fetch --quiet "$src/repo.bundle" 'refs/*:refs/*' --force
  fi

  gitdir=$(git -C "$dst" rev-parse --absolute-git-dir)
  if [ -f "$src/git/config" ]; then
    cp -p "$src/git/config" "$gitdir/config"
  fi
  if [ -f "$src/git/info-exclude" ]; then
    mkdir -p "$gitdir/info"
    cp -p "$src/git/info-exclude" "$gitdir/info/exclude"
  fi
  if [ -d "$src/git/hooks" ]; then
    mkdir -p "$gitdir/hooks"
    ( cd "$src/git/hooks" && tar -cf - . ) | ( cd "$gitdir/hooks" && tar -xpf - )
  fi

  if [ -n "$branch" ] && git -C "$dst" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    # Never leave the staging ref behind as the checked-out branch.
    git -C "$dst" symbolic-ref HEAD "refs/heads/$branch"
    git -C "$dst" reset --quiet --hard "refs/heads/$branch"
  elif [ -n "$sha" ] && [ "$sha" != unknown ] \
    && git -C "$dst" rev-parse --verify --quiet "$sha^{commit}" >/dev/null; then
    git -C "$dst" checkout --quiet --force --detach "$sha"
  else
    # Neither the recorded branch nor the recorded commit resolved. Land on some
    # real branch rather than leaving the repository parked on the staging ref;
    # a repository with no branches at all was empty when it was captured and
    # correctly stays that way.
    fallback=$(git -C "$dst" for-each-ref --format='%(refname)' refs/heads \
      | grep -v '^refs/heads/fm-restore-staging$' | head -n 1)
    if [ -n "$fallback" ]; then
      git -C "$dst" symbolic-ref HEAD "$fallback"
      git -C "$dst" reset --quiet --hard "$fallback"
    fi
  fi
}

restored=0
MANUAL_STEPS="$WORK/manual"
: >"$MANUAL_STEPS"
add_manual() { printf '%s\n' "$*" >>"$MANUAL_STEPS"; }

# -------------------------------------------------------------- account home ---
if [ -d "$PAYLOAD/global" ]; then
  copy_into "$PAYLOAD/global" "$DEST"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -L "$PAYLOAD/global/${rel#./}" ]; then
      kind=symlink
    elif [ -x "$PAYLOAD/global/${rel#./}" ]; then
      kind='executable file, mode preserved'
    else
      kind='file, mode preserved'
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      say "WOULD RESTORE ~/${rel#./} - $kind"
    else
      say "RESTORED ~/${rel#./} - $kind"
    fi
    restored=$((restored + 1))
  done <<EOF
$(cd "$PAYLOAD/global" && find . \( -type f -o -type l \) | LC_ALL=C sort)
EOF
else
  say "SKIPPED ~/.claude - the archive captured no account-level rules"
fi

# Re-anchor absolute symlinks that pointed inside the backed-up account home, so
# a restored rules symlink follows the restored rules file instead of the machine
# the backup came from.
if [ -s "$PAYLOAD/SYMLINKS" ]; then
  while IFS="$(printf '\t')" read -r linkpath target; do
    [ -n "$linkpath" ] || continue
    case "$linkpath" in
      global/*) dest_link="$DEST/${linkpath#global/}" ;;
      home/tree/*) dest_link="$FM_DEST/${linkpath#home/tree/}" ;;
      *) continue ;;
    esac
    dest_target="$DEST/${target#\~/}"
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  would re-anchor symlink ${dest_link#"$DEST"/} -> $dest_target"
      continue
    fi
    mkdir -p "$(dirname "$dest_link")"
    rm -f "$dest_link"
    ln -s "$dest_target" "$dest_link"
    say "RELINKED ${dest_link#"$DEST"/} -> $dest_target (symlink, not a copy)"
  done <"$PAYLOAD/SYMLINKS"
fi

# ---------------------------------------------------------- operational home ---
if [ -d "$PAYLOAD/home" ]; then
  restore_repo "$PAYLOAD/home" "$FM_DEST" "the operational home"
  if [ -d "$PAYLOAD/home/tree" ]; then
    copy_into "$PAYLOAD/home/tree" "$FM_DEST"
    # The checkout above restores every tracked file, including ones the captain
    # had deleted without committing. Reapply those deletions so the restored
    # home matches what was captured rather than what HEAD holds.
    if [ "$DRY_RUN" -eq 0 ] && [ -s "$PAYLOAD/home/deleted" ]; then
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        rm -f "$FM_DEST/$rel"
      done <"$PAYLOAD/home/deleted"
      say "RESTORED $FM_DEST - $(wc -l <"$PAYLOAD/home/deleted" | tr -d ' ') uncommitted deletion(s) reapplied"
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      say "RESTORED $FM_DEST - history, local remotes, and the complete working tree including data/, config/, and state/"
    fi
  fi
else
  say "SKIPPED the operational home - the archive captured none"
fi

# ------------------------------------------------------------------ projects ---
if [ -d "$PAYLOAD/projects" ]; then
  for pdir in "$PAYLOAD"/projects/*; do
    [ -d "$pdir" ] || continue
    pname=$(basename "$pdir")
    pdest="$FM_DEST/projects/$pname"
    restore_repo "$pdir" "$pdest" "project $pname"
    if [ "$DRY_RUN" -eq 0 ]; then
      if [ -s "$pdir/dirty.patch" ]; then
        if git -C "$pdest" apply --whitespace=nowarn "$pdir/dirty.patch" 2>/dev/null; then
          say "RESTORED project $pname uncommitted changes - patch applied to the working tree"
        else
          cp -p "$pdir/dirty.patch" "$pdest/fm-restore-uncommitted.patch"
          add_manual "Apply $pdest/fm-restore-uncommitted.patch by hand: it did not apply cleanly onto the restored $pname checkout."
        fi
      fi
      if [ -d "$pdir/tree" ]; then
        copy_into "$pdir/tree" "$pdest"
      fi
      if [ -d "$pdir/secrets" ]; then
        for sfile in "$pdir"/secrets/*; do
          [ -f "$sfile" ] || continue
          cp -p "$sfile" "$pdest/$(basename "$sfile")"
          say "RESTORED project $pname $(basename "$sfile") - credential file from the archive"
        done
      fi
      say "RESTORED project $pname at $pdest - $(git -C "$pdest" for-each-ref --format='%(refname:short)' refs/heads | wc -l | tr -d ' ') branch(es), full history"
    fi
  done
fi

# ------------------------------------------------------------- manual steps ---
if [ "$HAD_SECRETS" != 1 ]; then
  add_manual "Sign in again to each harness: the archive deliberately carried no credential files. Run the harness once (for example 'claude') and complete its login."
  if grep -q '^SKIPPED .*credential class' "$PAYLOAD/INVENTORY" 2>/dev/null; then
    add_manual "Recreate these credential files, which the backup named but did not carry:"
    while IFS= read -r line; do
      add_manual "    ${line#SKIPPED }"
    done <<EOF
$(grep '^SKIPPED .*credential class' "$PAYLOAD/INVENTORY" | sed 's/ - credential class.*//')
EOF
  fi
fi
if [ -d "$FM_DEST/projects" ] || [ "$DRY_RUN" -eq 1 ]; then
  add_manual "Reinstall each project's dependencies; the backup excludes node_modules and other build output on purpose. Use whatever each project's README specifies."
fi
add_manual "Start firstmate in $FM_DEST and let its session start run; the pool worktrees under ~/.treehouse are recreated on demand and were not carried."

say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "fm-restore: --dry-run complete, nothing was written."
else
  say "fm-restore: restored $restored account-level item(s), the operational home, and every project in the archive."
fi
say ""
say "fm-restore: $(grep -cv '^    ' "$MANUAL_STEPS") step(s) this restore cannot do for you:"
n=0
while IFS= read -r step; do
  [ -n "$step" ] || continue
  case "$step" in
    "    "*) say "$step" ;;
    *) n=$((n + 1)); say "  $n. $step" ;;
  esac
done <"$MANUAL_STEPS"
