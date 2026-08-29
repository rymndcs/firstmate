#!/usr/bin/env bash
# Tests for bin/fm-backup.sh and bin/fm-restore.sh: whether a captured setup
# actually comes back, and whether the pair refuses the two things that would
# make it worse than no backup at all.
#
# Everything runs through the two executables against a synthetic account home,
# so nothing here reads either script's source and nothing touches the real HOME.
#
# Matrix:
#   (a) round trip     - executable hook modes, a symlink that stays a symlink and
#                        is re-anchored to the restore destination, the gitignored
#                        private directories, and a project's history including a
#                        commit that exists on no remote, its local remotes, its
#                        info/exclude, and its own git hook, plus the home's own
#                        uncommitted edit and uncommitted deletion
#   (b) uncommitted    - modified and untracked work in the source project is
#                        captured and reapplied at the destination
#   (c) regenerable    - node_modules is excluded, named in the report, and absent
#                        from the restore
#   (d) credentials    - excluded by default and named; carried with
#                        --include-secrets; the archive is 0600 either way
#   (e) clobber        - restore refuses an existing setup; --force proceeds and
#                        re-running over the work the archive already holds is a
#                        no-op rather than a refusal
#   (f) unbacked work at destination - refused even with --force, work left intact
#   (g) --dry-run      - writes nothing at all
#   (h) format         - an archive of an unknown format is refused
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# The report labels account-home paths this way; held in a variable so it stays
# display text rather than a path the shell would expand.
ACCOUNT='~'

BACKUP="$ROOT/bin/fm-backup.sh"
RESTORE="$ROOT/bin/fm-restore.sh"
TMP_ROOT=$(fm_test_tmproot fm-backup-restore)

# A synthetic account home: agent rules with an executable hook, a shared skills
# root that .claude links into with an absolute symlink, a harness rules symlink,
# credential files, and an operational home holding gitignored private state and
# one project whose latest commit is on no remote.
SRC="$TMP_ROOT/src"
FM="$SRC/ai-workspace"
PROJ="$FM/projects/demo"

mkdir -p "$SRC/.claude/hooks" "$SRC/.claude/skills" "$SRC/.agents/skills/shared" \
  "$SRC/.codex" "$SRC/.pi/agent"
printf 'captain rules\n' > "$SRC/.claude/CLAUDE.md"
printf '{"hooks":{}}\n' > "$SRC/.claude/settings.json"
printf '{"local":true}\n' > "$SRC/.claude/settings.local.json"
printf '#!/bin/sh\necho guard\n' > "$SRC/.claude/hooks/guard.sh"
chmod 755 "$SRC/.claude/hooks/guard.sh"
printf 'shared skill\n' > "$SRC/.agents/skills/shared/SKILL.md"
ln -s "$SRC/.agents/skills/shared" "$SRC/.claude/skills/shared"
ln -s "$SRC/.claude/CLAUDE.md" "$SRC/.codex/AGENTS.md"
ln -s "$SRC/.claude/CLAUDE.md" "$SRC/.pi/agent/AGENTS.md"
printf '{"token":"secret"}\n' > "$SRC/.claude/.credentials.json"
printf '{"mcpServers":{}}\n' > "$SRC/.claude.json"

mkdir -p "$FM/data" "$FM/config" "$FM/state"
printf 'projects/\ndata/\nconfig/\nstate/\n.env\nnode_modules/\n' > "$FM/.gitignore"
printf '# home\n' > "$FM/README.md"
printf 'captain preferences\n' > "$FM/data/captain.md"
printf 'crew=2\n' > "$FM/config/crew-limit"
printf 'wake\n' > "$FM/state/task.status"
printf 'FM_SECRET=1\n' > "$FM/.env"
git -C "$FM" init -q
git -C "$FM" add -A
git -C "$FM" commit -qm 'home initial'
printf 'local-only rule\n' > "$FM/.git/info/exclude"
# A tracked file the captain has edited but not committed, so the home carries
# uncommitted work of its own for the round trip and the re-run guard to face.
printf 'edited but not committed\n' >> "$FM/README.md"
# A tracked file deleted but not committed: a checkout alone would bring it back,
# so the capture has to express the absence too.
printf 'about to be deleted\n' > "$FM/doomed.txt"
git -C "$FM" add doomed.txt
git -C "$FM" commit -qm 'add a file the captain later deletes'
rm "$FM/doomed.txt"
# Gitignored regenerable bulk: the home tree is captured whole, gitignored files
# included, so only the exclusion list keeps this out.
mkdir -p "$FM/node_modules"
printf 'regenerable\n' > "$FM/node_modules/junk.js"

fm_git_init_commit "$PROJ"
fm_git_add_origin "$PROJ" "$TMP_ROOT/demo-remote.git"
git -C "$PROJ" fetch -q origin
printf 'never pushed\n' > "$PROJ/local-only.txt"
git -C "$PROJ" add local-only.txt
git -C "$PROJ" commit -qm 'commit that exists on no remote'
printf '#!/bin/sh\necho post-merge\n' > "$PROJ/.git/hooks/post-merge"
chmod 755 "$PROJ/.git/hooks/post-merge"
printf 'project local ignore\n' > "$PROJ/.git/info/exclude"
mkdir -p "$PROJ/node_modules"
printf 'regenerable\n' > "$PROJ/node_modules/dep.js"
printf 'edited by the captain\n' >> "$PROJ/README.md"
printf 'scratch note\n' > "$PROJ/notes.txt"

SRC_HEAD=$(git -C "$PROJ" rev-parse HEAD)
SRC_LOCAL_ONLY=$(git -C "$PROJ" rev-list --count --all --not --remotes)
[ "$SRC_LOCAL_ONLY" -ge 1 ] || fail "fixture is wrong: the project has no commit outside its remote"

# --- (a) (b) (c) (d) one backup, one restore ---------------------------------

ARCHIVE="$TMP_ROOT/backup.tar.gz"
out=$("$BACKUP" --home "$FM" --user-home "$SRC" --out "$ARCHIVE" 2>&1) \
  || fail "fm-backup.sh failed"$'\n'"$out"

assert_present "$ARCHIVE" "the backup wrote no archive"
# Exact-mode match through find, which is portable and does not parse ls output.
assert_mode() {  # <path> <octal> <msg>
  find "$1" -maxdepth 0 -perm "$2" | grep -q . || fail "$3"
}
assert_mode "$ARCHIVE" 0600 "the archive is not mode 0600 and could be world-readable"
pass "backup writes a single archive at mode 0600"

assert_contains "$out" "SKIPPED ~/.claude/.credentials.json" \
  "the report does not name the skipped harness credential file"
assert_contains "$out" "SKIPPED home .env" \
  "the report does not name the skipped home credential file"
assert_contains "$out" "contains NO credential files" \
  "the backup does not state plainly that it carried no credentials"
pass "credential files are named as skipped, never silently dropped"

assert_contains "$out" "SKIPPED project demo regenerable files" \
  "the report does not name the excluded regenerable files"
pass "excluded regenerable files are reported by name"

DEST="$TMP_ROOT/dest"
rout=$("$RESTORE" "$ARCHIVE" --dest "$DEST" 2>&1) || fail "fm-restore.sh failed"$'\n'"$rout"

assert_mode "$DEST/.claude/hooks/guard.sh" 0755 "the restored hook did not come back at its captured mode"
[ -x "$DEST/.claude/hooks/guard.sh" ] || fail "restored hook is not executable and would never fire"
pass "restored hooks keep their executable mode"

for link in .codex/AGENTS.md .pi/agent/AGENTS.md .claude/skills/shared; do
  [ -L "$DEST/$link" ] || fail "$link came back as a copy, not a symlink"
  [ -e "$DEST/$link" ] || fail "$link came back dangling"
  target=$(readlink "$DEST/$link")
  case "$target" in
    "$DEST"/*) : ;;
    *) fail "$link still points at the source machine: $target" ;;
  esac
done
assert_contains "$(cat "$DEST/.codex/AGENTS.md")" "captain rules" \
  "the restored harness rules symlink does not resolve to the restored rules"
pass "symlinks come back as symlinks re-anchored to the restore destination"

assert_grep "captain preferences" "$DEST/ai-workspace/data/captain.md" \
  "the gitignored data/ did not come back"
assert_grep "crew=2" "$DEST/ai-workspace/config/crew-limit" \
  "the gitignored config/ did not come back"
assert_grep "wake" "$DEST/ai-workspace/state/task.status" \
  "the gitignored state/ did not come back"
assert_grep "local-only rule" "$DEST/ai-workspace/.git/info/exclude" \
  "the operational home's local ignore rules did not come back"
assert_grep "edited but not committed" "$DEST/ai-workspace/README.md" \
  "the operational home's uncommitted edit did not come back"
assert_absent "$DEST/ai-workspace/doomed.txt" \
  "a file deleted but not committed came back from the checkout"
pass "the operational home's private directories and local git settings come back"

DPROJ="$DEST/ai-workspace/projects/demo"
[ "$(git -C "$DPROJ" rev-parse HEAD)" = "$SRC_HEAD" ] \
  || fail "the restored project is not at the commit the backup captured"
[ "$(git -C "$DPROJ" rev-list --count --all --not --remotes)" = "$SRC_LOCAL_ONLY" ] \
  || fail "the restored project lost commits that exist on no remote"
assert_contains "$(git -C "$DPROJ" remote -v)" "origin" \
  "the restored project lost its remotes"
[ -x "$DPROJ/.git/hooks/post-merge" ] \
  || fail "the restored project hook is missing or not executable"
assert_grep "project local ignore" "$DPROJ/.git/info/exclude" \
  "the restored project lost its local ignore rules"
pass "project history, remotes, hooks, and local ignore rules come back"

assert_grep "edited by the captain" "$DPROJ/README.md" \
  "uncommitted changes in the source project were not reapplied"
assert_grep "scratch note" "$DPROJ/notes.txt" \
  "untracked files in the source project were not restored"
pass "uncommitted and untracked work at the source comes back"

assert_absent "$DPROJ/node_modules/dep.js" "excluded project bulk was restored anyway"
assert_absent "$DEST/ai-workspace/node_modules/junk.js" "excluded home bulk was restored anyway"
pass "regenerable bulk stays out of the restore"

assert_absent "$DEST/.claude/.credentials.json" "a credential file was restored without --include-secrets"
assert_absent "$DEST/ai-workspace/.env" "a credential file was restored without --include-secrets"
assert_contains "$rout" "Sign in again to each harness" \
  "the restore does not tell the operator that credentials must be recreated"
assert_contains "$rout" "$ACCOUNT/.claude/.credentials.json" \
  "the restore does not name the credential file it could not carry"
pass "credentials stay out by default and the restore says what must be redone"

# --- (d) --include-secrets ---------------------------------------------------

SECRET_ARCHIVE="$TMP_ROOT/backup-secrets.tar.gz"
sout=$("$BACKUP" --home "$FM" --user-home "$SRC" --out "$SECRET_ARCHIVE" --include-secrets 2>&1) \
  || fail "fm-backup.sh --include-secrets failed"$'\n'"$sout"
assert_contains "$sout" "INCLUDED ~/.claude/.credentials.json" \
  "--include-secrets did not report the credential file as included"
assert_contains "$sout" "CONTAINS credential files" \
  "--include-secrets did not state plainly that the archive holds credentials"
assert_mode "$SECRET_ARCHIVE" 0600 "the --include-secrets archive is not mode 0600"

SDEST="$TMP_ROOT/dest-secrets"
"$RESTORE" "$SECRET_ARCHIVE" --dest "$SDEST" >/dev/null 2>&1 \
  || fail "restoring the --include-secrets archive failed"
assert_grep "secret" "$SDEST/.claude/.credentials.json" "the credential file did not come back"
assert_grep "FM_SECRET" "$SDEST/ai-workspace/.env" "the home credential file did not come back"
pass "--include-secrets carries the credential files and says so"

# --- (e) clobber refusal -----------------------------------------------------

set +e
cout=$("$RESTORE" "$ARCHIVE" --dest "$DEST" 2>&1)
ccode=$?
set -e
expect_code 3 "$ccode" "restoring over an existing setup"
assert_contains "$cout" "refusing to overwrite an existing setup" \
  "the refusal does not say what it refused"
assert_contains "$cout" "nothing was written" "the refusal does not say nothing was written"
pass "restore refuses an existing setup without --force"

fout=$("$RESTORE" "$ARCHIVE" --dest "$DEST" --force 2>&1) \
  || fail "--force did not restore over the existing setup"$'\n'"$fout"
assert_grep "captain preferences" "$DEST/ai-workspace/data/captain.md" \
  "--force left the setup incomplete"
# The destination now holds exactly the uncommitted work the archive carries, so
# the work guard must read that as nothing at risk rather than as a reason to
# refuse: restoring the same archive twice is a no-op, not a dead end.
assert_grep "edited by the captain" "$DPROJ/README.md" \
  "--force did not reapply the captured uncommitted work"
assert_grep "edited but not committed" "$DEST/ai-workspace/README.md" \
  "--force did not reapply the operational home's uncommitted edit"
pass "--force restores over an existing setup and re-running is idempotent"

# --- (f) uncommitted work at the destination ---------------------------------

printf 'work the captain has not landed\n' >> "$DPROJ/README.md"
set +e
uout=$("$RESTORE" "$ARCHIVE" --dest "$DEST" --force 2>&1)
ucode=$?
set -e
expect_code 4 "$ucode" "restoring over uncommitted work with --force"
assert_contains "$uout" "has uncommitted work this archive does not contain" \
  "the refusal does not say why it stopped"
assert_contains "$uout" "README.md" "the refusal does not name the file at risk"
assert_grep "work the captain has not landed" "$DPROJ/README.md" \
  "the refused restore destroyed uncommitted work anyway"
pass "restore never destroys uncommitted work at the destination, --force included"

# --- (g) --dry-run -----------------------------------------------------------

DRY="$TMP_ROOT/dry"
dout=$("$RESTORE" "$ARCHIVE" --dest "$DRY" --dry-run 2>&1) || fail "--dry-run failed"$'\n'"$dout"
assert_absent "$DRY" "--dry-run wrote to the destination"
assert_contains "$dout" "nothing was written" "--dry-run does not say it wrote nothing"
assert_contains "$dout" "would rebuild project demo" "--dry-run does not report the project it would rebuild"
pass "--dry-run reports the plan and writes nothing"

# --- (h) unknown archive format ----------------------------------------------

BOGUS="$TMP_ROOT/bogus"
mkdir -p "$BOGUS/fm-backup-elsewhere"
printf 'format=fm-backup.v99\nfm_home_basename=ai-workspace\n' > "$BOGUS/fm-backup-elsewhere/MANIFEST"
( cd "$BOGUS" && tar -czf "$TMP_ROOT/bogus.tar.gz" fm-backup-elsewhere )
set +e
bout=$("$RESTORE" "$TMP_ROOT/bogus.tar.gz" --dest "$TMP_ROOT/bogus-dest" 2>&1)
bcode=$?
set -e
expect_code 2 "$bcode" "restoring an archive of an unknown format"
assert_contains "$bout" "fm-backup.v99" "the refusal does not name the format it rejected"
pass "restore refuses an archive whose format it does not implement"

# --- reports and help --------------------------------------------------------

lout=$("$BACKUP" --home "$FM" --user-home "$SRC" --list 2>&1) || fail "fm-backup.sh --list failed"
assert_contains "$lout" "no archive written" "--list wrote or claimed to write an archive"
assert_contains "$lout" "INCLUDED home data/" "--list does not report the private directories"
pass "--list reports the capture without writing an archive"

hout=$("$BACKUP" --help 2>&1) || true
assert_contains "$hout" "node_modules" "the backup help does not state the exclusion list"
assert_contains "$hout" "--include-secrets" "the backup help does not document the credential flag"
rhout=$("$RESTORE" --help 2>&1) || true
assert_contains "$rhout" "--force" "the restore help does not document --force"
pass "both commands document their exclusions and flags in --help"
