#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity
export ROOT
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['ROOT'])


class CleanupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fm-leftovers-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.repo = self.home / 'projects' / 'demo'
        self.state = self.home / 'state'
        self.state.mkdir()
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT),
                        FM_STATE_OVERRIDE=str(self.state), HOME=str(self.home),
                        FM_GATE_REFUSE_BYPASS='1')
        self.git('init', '-q', '-b', 'main', str(self.repo), root=self.home)
        self.git('config', 'commit.gpgsign', 'false')
        (self.repo / '.gitignore').write_text('ignored\n')
        (self.repo / 'file').write_text('base\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')

    def git(self, *args, root=None):
        return subprocess.check_output(['git', '-C', str(root or self.repo), *args],
                                       env=self.env, stderr=subprocess.DEVNULL).decode().strip()

    def wt(self, name='leftover', path=None):
        path = path or self.home / name
        self.git('worktree', 'add', '-qb', name, str(path))
        return path

    def run_cleanup(self, *args):
        p = subprocess.run([str(ROOT / 'bin/fm-leftover-worktrees.sh'), *args],
                           env=self.env, text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def test_external_landed_and_detached_removed(self):
        a = self.wt(path=self.home / 'elsewhere' / 'with spaces')
        b = self.wt('detached')
        self.git('checkout', '-q', '--detach', root=b)
        out = self.run_cleanup()
        self.assertFalse(a.exists())
        self.assertFalse(b.exists())
        self.assertTrue(self.repo.exists())
        self.assertIn(str(a), out)
        self.assertEqual(self.run_cleanup(), '')

    def test_dirty_and_untracked_named_once_then_removed(self):
        a, b = self.wt(), self.wt('untracked')
        (a / 'file').write_text('dirty\n')
        (b / 'new').write_text('new\n')
        first = self.run_cleanup()
        self.assertIn(str(a), first)
        self.assertIn(str(b), first)
        self.assertTrue(a.exists() and b.exists())
        self.assertEqual(self.run_cleanup(), '')
        (a / 'file').write_text('base\n')
        (b / 'new').unlink()
        self.run_cleanup()
        self.assertFalse(a.exists() or b.exists())

    def test_unlanded_and_stash_preserved(self):
        a = self.wt()
        (a / 'file').write_text('unique\n')
        self.git('commit', '-qam', 'unique', root=a)
        self.assertIn(str(a), self.run_cleanup())
        self.assertTrue(a.exists())
        b = self.wt('stash')
        (b / 'file').write_text('saved\n')
        self.git('stash', 'push', '-qm', 'saved', root=b)
        self.run_cleanup()
        self.assertTrue(a.exists() and b.exists())

    def test_hidden_index_changes_preserved(self):
        a = self.wt()
        self.git('update-index', '--skip-worktree', 'file', root=a)
        (a / 'file').write_text('hidden edit\n')
        self.assertEqual(self.git('status', '--porcelain', root=a), '')
        self.run_cleanup()
        self.assertTrue(a.exists())

    def test_unreachable_origin_and_corrupt_state_preserved(self):
        a = self.wt()
        self.git('remote', 'add', 'origin', str(self.home / 'unreachable'))
        self.assertIn(str(a), self.run_cleanup())
        self.assertTrue(a.exists())
        self.git('remote', 'remove', 'origin')
        (self.state / 'leftover-worktrees.json').write_text('invalid')
        p = subprocess.run([str(ROOT / 'bin/fm-leftover-worktrees.sh')],
                           env=self.env, capture_output=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertTrue(a.exists())

    def test_orca_inventory_failure_preserves_candidates(self):
        a = self.wt()
        fakebin = self.home / 'fakebin'
        fakebin.mkdir()
        orca = fakebin / 'orca'
        orca.write_text('#!/bin/sh\nexit 1\n')
        orca.chmod(0o755)
        self.env['PATH'] = str(fakebin) + ':' + self.env['PATH']
        self.assertIn(str(a), self.run_cleanup())
        self.assertTrue(a.exists())
        orca.write_text('#!/bin/sh\necho "[]"\n')
        self.assertEqual(self.run_cleanup(), '')
        self.assertTrue(a.exists())

    def test_unreadable_task_identity_named_once(self):
        a = self.wt()
        (self.state / 'unknown.meta').write_text('kind=ship\n')
        self.assertIn(str(a), self.run_cleanup())
        self.assertTrue(a.exists())
        self.assertEqual(self.run_cleanup(), '')

    def test_landing_inspection_keeps_gate_agent_refusal(self):
        a = self.wt()
        env = dict(self.env, NO_MISTAKES_GATE='review')
        env.pop('FM_GATE_REFUSE_BYPASS', None)
        p = subprocess.run([str(ROOT / 'bin/fm-teardown.sh'), '--check-default-content',
                            str(self.repo), str(a)], env=env, capture_output=True)
        self.assertEqual(p.returncode, 3)
        self.assertTrue(a.exists())

    def test_orca_inventory_protects_arbitrary_managed_path(self):
        a, b = self.wt(), self.wt('outside')
        fakebin = self.home / 'fakebin'
        fakebin.mkdir()
        orca = fakebin / 'orca'
        payload = json.dumps({'ok': True, 'result': {'worktrees': [{'path': str(a)}]}})
        orca.write_text(f'#!/bin/sh\nprintf "%s\\n" \'{payload}\'\n')
        orca.chmod(0o755)
        self.env['PATH'] = str(fakebin) + ':' + self.env['PATH']
        self.run_cleanup()
        self.assertTrue(a.exists())
        self.assertFalse(b.exists())

    def test_fresh_task_registration_during_comparison_preserves_tree(self):
        a = self.wt()
        fakebin = self.home / 'fakebin'
        fakebin.mkdir()
        wrapper = fakebin / 'git'
        real = subprocess.check_output(['which', 'git'], text=True).strip()
        wrapper.write_text('#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\n'
                           f'if "merge-tree" in sys.argv: Path({str(self.state / "new.meta")!r}).write_text({f"worktree={a}"!r})\n'
                           f'os.execv({real!r}, [{real!r}] + sys.argv[1:])\n')
        wrapper.chmod(0o755)
        self.env['PATH'] = str(fakebin) + ':' + self.env['PATH']
        self.run_cleanup()
        self.assertTrue(a.exists())

    def test_squash_landed_removed_but_open_pushed_work_kept(self):
        a = self.wt()
        (a / 'extra').write_text('feature\n')
        self.git('add', 'extra', root=a)
        self.git('commit', '-qm', 'feature', root=a)
        self.git('merge', '--squash', 'leftover')
        self.git('commit', '-qm', 'squashed')
        self.run_cleanup()
        self.assertFalse(a.exists())
        b = self.wt('open')
        (b / 'extra').write_text('open\n')
        self.git('commit', '-qam', 'open', root=b)
        remote = self.home / 'remote.git'
        self.git('clone', '-q', '--bare', str(self.repo), str(remote))
        self.git('remote', 'add', 'origin', str(remote))
        self.git('push', '-q', 'origin', 'open')
        self.run_cleanup()
        self.assertTrue(b.exists())

    def test_task_nested_slot_locked_and_legacy_preserved(self):
        active = self.wt('active')
        nested = self.wt('nested', active / '.claude/worktrees/nested')
        (self.state / 'live.meta').write_text(f'worktree={active}\n')
        locked = self.wt('locked')
        self.git('worktree', 'lock', str(locked))
        legacy = self.wt('legacy', self.home / 'projects/thanos-worktrees/legacy-claude/x')
        pool = self.home / 'pool'
        slot = self.wt('slot', pool / 'one')
        (pool / 'treehouse-state.json').write_text('{}')
        secondmate = self.wt('secondmate')
        (secondmate / '.fm-secondmate-home').write_text('home')
        self.run_cleanup()
        for path in (active, nested, locked, legacy, slot, secondmate):
            self.assertTrue(path.exists(), str(path))

    def test_away_skips_all_writes(self):
        a = self.wt()
        (self.state / '.afk').touch()
        self.assertEqual(self.run_cleanup(), '')
        self.assertTrue(a.exists())

    def test_help_includes_safety_contract_without_cleanup(self):
        a = self.wt()
        out = self.run_cleanup('--help')
        self.assertIn('Away mode skips both arming and project writes.', out)
        self.assertTrue(a.exists())

    def test_ignored_material_removed_without_force(self):
        a = self.wt()
        (a / 'ignored').write_text('local ignored data')
        self.run_cleanup()
        self.assertFalse(a.exists())

    def test_secondmate_registry_and_orca_pool_preserved(self):
        a = self.wt('secondmate')
        data = self.home / 'data'
        data.mkdir()
        (data / 'secondmates.md').write_text(f'- two - domain (home: {a}; scope: demo; projects: demo; added 2026-11-11)\n')
        b = self.wt('orca-slot', self.home / 'orca' / 'slot')
        self.run_cleanup()
        self.assertTrue(a.exists() and b.exists())

    def test_fleet_sync_arms_cleanup_instead_of_doing_it_at_startup(self):
        a = self.wt()
        p = subprocess.run([str(ROOT / 'bin/fm-fleet-sync.sh')], env=self.env,
                           text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(a.exists())
        self.assertTrue((self.state / 'leftover-worktrees.check-trust').exists())

    def test_arm_registers_check_without_running_cleanup(self):
        a = self.wt()
        self.run_cleanup('--arm')
        self.assertTrue(a.exists())
        check = self.state / 'leftover-worktrees.check.sh'
        self.assertTrue(check.exists())
        self.assertTrue((self.state / 'leftover-worktrees.check-trust').exists())
        p = subprocess.run(['bash', str(check)], env=self.env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(a.exists())

    def db_tool(self, lines, apply_extra=''):
        self.repo.rename(self.repo.with_name('thanos'))
        self.repo = self.repo.with_name('thanos')
        tool = self.repo / 'bin/worktree-cleanup'
        tool.parent.mkdir()
        tool.write_text('#!/usr/bin/env python3\nimport os\nfrom pathlib import Path\nimport sys\n'
                        f'lines = {lines!r}\n'
                        'if "--apply" in sys.argv:\n'
                        '    Path(os.environ["FM_HOME"], "applied").touch()\n'
                        f'    {apply_extra or "pass"}\n'
                        '    print(lines.replace("WOULD DROP", "DROP"))\n'
                        'else:\n    print(lines)\n'
                        '    target = os.environ.get("REAPPEAR")\n'
                        '    if target: Path(target).mkdir()\n')
        tool.chmod(0o755)
        self.git('add', 'bin/worktree-cleanup')
        self.git('commit', '-qm', 'cleanup tool')

    def test_global_db_dry_run_apply_and_report(self):
        missing = self.home / 'missing'
        self.db_tool(f'WOULD DROP  path={missing}  dbs=thanos_dev_old,thanos_test_old  index=2')
        out = self.run_cleanup()
        self.assertTrue((self.home / 'applied').exists())
        self.assertIn('thanos_dev_old', out)
        self.assertIn('DROP', out)

    def test_database_cleanup_runs_before_worktree_comparison_budget(self):
        missing = self.home / 'missing'
        candidate = self.home / 'leftover'
        self.db_tool(f'WOULD DROP  path={missing}  dbs=thanos_dev_old  index=2',
                     f'Path({str(self.home / "order")!r}).write_text("present" if Path({str(candidate)!r}).exists() else "removed")')
        self.wt()
        self.run_cleanup()
        self.assertEqual((self.home / 'order').read_text(), 'present')
        self.assertFalse(candidate.exists())

    def test_db_active_nested_or_reappearing_path_blocks_apply_once(self):
        missing = self.home / 'active/.claude/worktrees/missing'
        self.db_tool(f'WOULD DROP  path={missing}  dbs=thanos_dev_old  index=2')
        (self.state / 'live.meta').write_text(f'worktree={self.home / "active"}\n')
        out = self.run_cleanup()
        self.assertFalse((self.home / 'applied').exists())
        self.assertIn(str(missing), out)
        self.assertEqual(self.run_cleanup(), '')
        (self.state / 'live.meta').unlink()
        self.env['REAPPEAR'] = str(missing)
        self.run_cleanup()
        self.assertFalse((self.home / 'applied').exists())

    def test_db_live_name_and_malformed_output_block_apply(self):
        missing = self.home / 'missing'
        self.db_tool(f'WOULD DROP  path={missing}  dbs=thanos_development  index=2')
        self.run_cleanup()
        self.assertFalse((self.home / 'applied').exists())
        tool = self.repo / 'bin/worktree-cleanup'
        tool.write_text('#!/bin/sh\necho "WOULD DROP unparseable"\n')
        self.run_cleanup()
        self.assertFalse((self.home / 'applied').exists())


unittest.main(verbosity=2)
PY
