"""Automatic updates (updater.py) against throwaway git repositories: no network, no real build."""
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isolate  # noqa: E402,F401
sys.path.insert(0, str(ROOT / 'core'))
from aiface import moods as face_modes, paths, updater  # noqa: E402


def run(cwd, *args):
    subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'init.defaultBranch=main', *args],
                   cwd=str(cwd), check=True, capture_output=True)


class FakeDevice:
    def __init__(self):
        self.owner, self.changed, self.flashing, self.message = '', 0, False, ''
        self.lock = threading.RLock()
        self.shown = []

    def show_emotion(self, preset, owner='user', record=True):
        self.shown.append(preset['id'])


@unittest.skipUnless(shutil.which('git'), 'no git')
class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.remote, self.seed, self.work = base / 'remote.git', base / 'seed', base / 'work'
        run(base, 'init', '--bare', '-q', str(self.remote))
        run(base, 'clone', '-q', str(self.remote), str(self.seed))
        self.commit('a.txt', 'one', 'First')
        run(base, 'clone', '-q', str(self.remote), str(self.work))
        self.installs, self.tests_ok, self.ran_tests = [], True, 0

        def tests(root):
            self.ran_tests += 1
            return self.tests_ok, 'log'
        for p in [patch.object(paths, 'DATA', base / 'data'),
                  patch.object(paths, 'project_root', return_value=self.work),
                  patch.object(updater, 'run_tests', side_effect=tests),
                  patch.object(updater, 'compile_app', return_value=(True, '')),
                  patch.object(updater, 'install_app', side_effect=self.installs.append),
                  patch.object(face_modes, 'SETTINGS', base / 'data' / 'settings.json'),
                  patch.object(updater.awake, 'status', return_value={'ours': False, 'leases': []})]:
            p.start()
            self.addCleanup(p.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, name, text, subject, where=None):
        where = where or self.seed
        (where / name).write_text(text)
        run(where, 'add', name)
        run(where, 'commit', '-q', '-m', subject)
        if where == self.seed:
            run(where, 'push', '-q', 'origin', 'main')

    def head(self):
        return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=str(self.work), capture_output=True,
                              text=True).stdout.strip()

    def test_latest(self):
        self.assertEqual(updater.check(FakeDevice())['result'], 'latest')
        self.assertEqual(self.installs, [])

    def test_installs_new_version(self):
        self.commit('b.txt', 'two', 'Add b')
        s = updater.check(FakeDevice())
        self.assertEqual(s['result'], 'installing')
        self.assertTrue((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [self.work])
        self.assertEqual(updater.load_state()['changes'], ['Add b'])
        device = FakeDevice()
        updater.announce(device)
        self.assertEqual(device.shown, ['happy'])
        self.assertIn('Add b', device.message)
        updater.announce(device)   # only once
        self.assertEqual(device.shown, ['happy'])
        self.assertEqual(updater.status()['result'], 'updated')

    def test_failed_tests_keep_the_running_version(self):
        old = self.head()
        self.commit('b.txt', 'two', 'Broken')
        self.tests_ok = False
        s = updater.check(FakeDevice())
        self.assertEqual(s['result'], 'failed')
        self.assertEqual(self.head(), old)
        self.assertFalse((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [])
        updater.check(FakeDevice())   # the same broken version is not tried again by itself
        self.assertEqual(self.ran_tests, 1)
        self.tests_ok = True
        self.assertEqual(updater.check(FakeDevice(), manual=True)['result'], 'installing')   # "Check now" does

    def test_skips_local_changes_and_commits(self):
        self.commit('b.txt', 'two', 'Add b')
        (self.work / 'a.txt').write_text('edited here')
        self.assertEqual(updater.check(FakeDevice())['result'], 'skipped')
        run(self.work, 'checkout', '-q', 'a.txt')
        self.commit('c.txt', 'mine', 'Local only', where=self.work)
        self.assertEqual(updater.check(FakeDevice())['result'], 'skipped')
        self.assertFalse((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [])

    def test_waits_while_an_ai_is_chatting(self):
        self.commit('b.txt', 'two', 'Add b')
        device = FakeDevice()
        device.owner, device.changed = 'claude', time.time()
        self.assertEqual(updater.check(device)['result'], 'waiting')
        self.assertEqual(self.installs, [])
        self.assertEqual(updater.check(device, manual=True)['result'], 'installing')

    def test_waits_for_a_timer(self):
        self.commit('b.txt', 'two', 'Add b')
        face_modes.save_settings(timer={'end': time.time() + 60, 'total': 60, 'color': 'blue'})
        self.assertEqual(updater.check(FakeDevice(), manual=True)['result'], 'waiting')

    def test_switch_survives_other_settings(self):
        self.assertTrue(updater.enabled())
        updater.set_enabled(False)
        face_modes.save_settings(mono=True)
        self.assertFalse(updater.enabled())
        with self.assertRaises(ValueError):
            updater.set_enabled('yes')


if __name__ == '__main__':
    unittest.main()
