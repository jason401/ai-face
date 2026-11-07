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
    p = subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'init.defaultBranch=main', *args],
                       cwd=str(cwd), capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(f'git {" ".join(args)}: {(p.stderr or p.stdout).strip()}')


SOURCE_CHECKOUT = updater.source_checkout


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
        base = Path(self.tmp.name).resolve()
        self.remote, self.seed, self.work = base / 'remote.git', base / 'seed', base / 'work'
        run(base, 'init', '--bare', '-q', str(self.remote))
        run(base, 'clone', '-q', str(self.remote), str(self.seed))
        self.commit('a.txt', 'one', 'First')
        run(base, 'clone', '-q', str(self.remote), str(self.work))
        self.installs, self.tests_ok, self.ran_tests = [], True, 0
        self.builds = 0
        with (self.work / '.git/info/exclude').open('a') as stream:
            stream.write('\nAI Face.update.app/\n')

        def build(root):
            self.builds += 1
            candidate = root / 'AI Face.update.app/Contents/MacOS/AIFace'
            candidate.parent.mkdir(parents=True, exist_ok=True)
            candidate.write_text(self.head())
            return True, ''

        def tests(root):
            self.ran_tests += 1
            return self.tests_ok, 'log'
        for p in [patch.object(updater, '_prepared', None),
                  patch.object(updater, '_wake', threading.Event()),
                  patch.object(paths, 'DATA', base / 'data'),
                  patch.object(updater, 'source_checkout', return_value=self.work),
                  patch.object(paths, 'running_revision', return_value=self.head()),
                  patch.object(paths, 'app_bundle', return_value=None),
                  patch.object(updater, 'BRANCH', 'main'),
                  patch.object(updater, 'run_tests', side_effect=tests),
                  patch.object(updater, 'compile_app', side_effect=build),
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
            self.publish('main')

    def publish(self, branch, source=None, ref='main'):
        """Like `git push origin <ref>:<branch>` from the seed, done as a fetch by the throwaway remote."""
        run(self.remote, 'fetch', '-q', str(source or self.seed), f'{ref}:refs/heads/{branch}')

    def head(self):
        return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=str(self.work), capture_output=True,
                              text=True).stdout.strip()

    def test_private_clone_uses_only_configured_repository(self):
        with patch.object(updater, 'REPOSITORY', str(self.remote)):
            source = SOURCE_CHECKOUT()
            self.assertEqual(source, paths.DATA / 'source')
            self.assertTrue((source / 'a.txt').is_file())
        with patch.object(updater, 'REPOSITORY', 'https://example.invalid/wrong.git'):
            with self.assertRaisesRegex(RuntimeError, 'Unexpected update repository'):
                SOURCE_CHECKOUT()

    def test_symlink_update_source_is_refused(self):
        paths.DATA.mkdir(parents=True)
        (paths.DATA / 'source').symlink_to(self.work, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symbolic link'):
            SOURCE_CHECKOUT()


    def test_latest(self):
        self.assertEqual(updater.check(FakeDevice())['result'], 'latest')
        self.assertEqual(self.installs, [])

    def test_never_goes_back_from_a_newer_build(self):
        # The running app was built from a main commit that stable does not have yet.
        self.commit('n.txt', 'new', 'Newer on main', where=self.work)
        newer = self.head()
        self.publish('dev', self.work, 'HEAD')
        run(self.work, 'reset', '-q', '--hard', 'HEAD~1')
        run(self.work, 'reflog', 'expire', '--expire=now', '--all')
        run(self.work, 'gc', '-q', '--prune=now')
        with patch.object(paths, 'running_revision', return_value=newer):
            s = updater.check(FakeDevice())
        self.assertEqual(s['result'], 'skipped')
        self.assertEqual(self.installs, [])

    def test_unknown_local_build_is_not_replaced(self):
        with patch.object(paths, 'running_revision', return_value='0' * 40):
            s = updater.check(FakeDevice())
        self.assertEqual(s['result'], 'skipped')
        self.assertEqual(self.installs, [])

    def test_check_only_finds_and_the_button_installs(self):
        self.commit('b.txt', 'two', 'Add b')
        s = updater.check(FakeDevice())   # the automatic check
        self.assertEqual((s['result'], s['changes']), ('available', ['Add b']))
        self.assertFalse((self.work / 'b.txt').exists())
        self.assertEqual((self.installs, self.ran_tests), ([], 0))
        s = updater.request_install(FakeDevice())   # "Update now"
        self.assertEqual(s['result'], 'installing')
        self.assertFalse(updater.load_state()['want_install'])
        self.assertTrue((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [self.work])
        self.assertEqual(updater.load_state()['changes'], ['Add b'])
        device = FakeDevice()
        updater.save_state(announce=True)  # Installer writes this only after startup acknowledgement.
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
        s = updater.check(FakeDevice(), manual=True, install=True)
        self.assertEqual(s['result'], 'failed')
        self.assertEqual(self.head(), old)
        self.assertFalse((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [])
        updater.check(FakeDevice())   # the same broken version is not tried again by itself
        self.assertEqual(self.ran_tests, 1)
        self.tests_ok = True
        self.assertEqual(updater.check(FakeDevice(), manual=True, install=True)['result'], 'installing')   # the button does

    def test_skips_local_changes_and_commits(self):
        self.commit('b.txt', 'two', 'Add b')
        (self.work / 'a.txt').write_text('edited here')
        self.assertEqual(updater.check(FakeDevice())['result'], 'skipped')
        run(self.work, 'checkout', '-q', 'a.txt')
        self.commit('c.txt', 'mine', 'Local only', where=self.work)
        self.assertEqual(updater.check(FakeDevice())['result'], 'skipped')
        self.assertFalse((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [])

    def test_checking_does_not_disturb_and_the_button_installs_while_chatting(self):
        self.commit('b.txt', 'two', 'Add b')
        device = FakeDevice()
        device.owner, device.changed = 'claude', time.time()
        self.assertEqual(updater.check(device)['result'], 'available')
        self.assertEqual(self.installs, [])
        self.assertEqual(updater.request_install(device)['result'], 'installing')

    def test_waits_for_a_timer(self):
        self.commit('b.txt', 'two', 'Add b')
        face_modes.save_settings(timer={'end': time.time() + 60, 'total': 60, 'color': 'blue'})
        self.assertEqual(updater.request_install(FakeDevice())['result'], 'waiting')
        self.assertTrue(updater.load_state()['want_install'])   # retried by the background loop

    def test_busy_started_during_build_prevents_install(self):
        self.commit('b.txt', 'two', 'Add b')
        device = FakeDevice()
        def compile_with_new_work(root):
            device.flashing = True
            return True, ''
        with patch.object(updater, 'compile_app', side_effect=compile_with_new_work):
            self.assertEqual(updater.check(device, manual=True, install=True)['result'], 'waiting')
        self.assertEqual(self.installs, [])
        # HEAD is already new, but the installed revision is old. Retry must still install.
        device.flashing = False
        self.assertEqual(updater.check(device, manual=True, install=True)['result'], 'installing')
        self.assertEqual(self.installs, [self.work])

    def test_busy_prepares_once_then_reuses_until_idle(self):
        self.commit('b.txt', 'two', 'Add b')
        face_modes.save_settings(timer={'end': time.time() + 60, 'total': 60, 'color': 'blue'})
        device = FakeDevice()
        result = updater.request_install(device)
        self.assertEqual((result['result'], self.ran_tests, self.builds), ('waiting', 1, 1))
        progress = updater.status()['progress']
        self.assertEqual(progress['stage'], 'install')
        self.assertTrue(progress['prepared'])
        self.assertAlmostEqual(progress['retry_at'] - progress['wait_checked_at'], 10)
        with patch.object(updater, 'git', wraps=updater.git) as git:
            for _ in range(3):
                self.assertEqual(updater.check(device, manual=True, install=True)['result'], 'waiting')
            self.assertFalse(any('fetch' in call.args for call in git.call_args_list))
        self.assertEqual((self.ran_tests, self.builds, self.installs), (1, 1, []))
        updater._progress['started'] = 1   # waiting time must not inflate install estimates
        face_modes.save_settings(timer=None)
        updater.notify_idle(device)
        self.assertTrue(updater._wake.is_set())
        self.assertTrue(updater.wait_for_check(threading.Event(), 3600))
        self.assertEqual(updater.check(device, manual=True, install=True)['result'], 'installing')
        self.assertEqual((self.ran_tests, self.builds, self.installs), (1, 1, [self.work]))
        self.assertGreater(updater.status()['progress']['started'], 1)
        self.assertNotIn('stopped', updater.status()['progress'])

    def test_modified_candidate_is_built_again(self):
        self.commit('b.txt', 'two', 'Add b')
        face_modes.save_settings(timer={'end': time.time() + 60, 'total': 60, 'color': 'blue'})
        updater.request_install(FakeDevice())
        staged = self.work / 'AI Face.update.app/Contents/MacOS/AIFace'
        staged.write_text('changed outside the updater')
        updater.check(FakeDevice(), manual=True, install=True)
        self.assertEqual((self.ran_tests, self.builds), (2, 2))

    def test_idle_request_signal_respects_other_requests(self):
        self.commit('b.txt', 'two', 'Add b')
        self.assertTrue(updater.request_started())
        self.assertTrue(updater.request_started())
        try:
            updater.request_install(FakeDevice())
            self.assertEqual(updater.status()['progress']['stage'], 'install')
            updater.request_finished(FakeDevice())
            self.assertFalse(updater._wake.is_set())
        finally:
            updater.request_finished(FakeDevice())
        self.assertTrue(updater._wake.is_set())

    def test_channel_change_during_build_does_not_install(self):
        self.commit('b.txt', 'two', 'Add b')
        def switch(root):
            updater.set_channel('stable')
            return True, ''
        self.publish('stable')
        with patch.object(updater, 'compile_app', side_effect=switch):
            updater.request_install(FakeDevice())
        self.assertEqual(self.installs, [])
        self.assertIsNone(updater._prepared)
        self.assertFalse(updater.load_state()['want_install'])

    def test_switching_away_and_back_still_cancels_preparation(self):
        self.commit('b.txt', 'two', 'Add b')
        def switch(root):
            updater.set_channel('stable')
            updater.set_channel('main')
            return True, ''
        with patch.object(updater, 'compile_app', side_effect=switch):
            result = updater.request_install(FakeDevice())
        self.assertEqual(result['result'], 'skipped')
        self.assertEqual(self.installs, [])
        self.assertIsNone(updater._prepared)

    def test_stopped_watcher_does_not_run(self):
        stop = threading.Event()
        stop.set()
        self.assertFalse(updater.wait_for_check(stop, 3600))

    def test_no_reset_of_developer_changes(self):
        developer = Path(self.tmp.name) / 'developer'
        developer.mkdir()
        marker = developer / 'notes.txt'
        marker.write_text('uncommitted research notes')
        self.commit('b.txt', 'two', 'Broken')
        self.tests_ok = False
        with patch.object(paths, 'project_root', return_value=developer):
            updater.check(FakeDevice(), manual=True, install=True)
        self.assertEqual(marker.read_text(), 'uncommitted research notes')

    def test_prepare_freezes_only_when_idle(self):
        updater.cancel_installation()
        self.addCleanup(updater.cancel_installation)
        device = FakeDevice()
        self.assertTrue(updater.request_started())  # preparation request
        self.assertTrue(updater.request_started())  # a concurrent mail/calendar/photo request
        self.assertTrue(updater.prepare_installation(device))
        updater.request_finished()
        self.assertEqual(updater.prepare_installation(device), '')
        self.assertFalse(updater.request_started())
        updater.request_finished()
        updater.cancel_installation()
        self.assertTrue(updater.request_started())
        updater.request_finished()


    def test_switch_survives_other_settings(self):
        self.assertTrue(updater.enabled())
        updater.set_enabled(False)
        face_modes.save_settings(mono=True)
        self.assertFalse(updater.enabled())
        with self.assertRaises(ValueError):
            updater.set_enabled('yes')

    # Update channels: stable (default) and main (beta).

    def branch(self):
        return subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], cwd=str(self.work),
                              capture_output=True, text=True).stdout.strip()

    def on_stable(self):
        """stable = main on the remote; the update source follows stable."""
        self.publish('stable')
        run(self.work, 'fetch', '-q', 'origin', 'stable')
        run(self.work, 'checkout', '-q', '-B', 'stable', 'FETCH_HEAD')
        face_modes.save_settings(update_channel='stable')

    def test_channel_setting(self):
        self.on_stable()
        self.assertEqual((updater.channel(), updater.status()['channel']), ('stable', 'stable'))
        for wrong in ('beta', 'dev', None, 1):
            with self.assertRaises(ValueError):
                updater.set_channel(wrong)
        updater.save_state(result='available', next='abc1234', changes=['Old'], want_install=True)
        updater.set_channel('main')
        face_modes.save_settings(mono=True)
        self.assertEqual(updater.channel(), 'main')
        s = updater.status()
        self.assertEqual((s['result'], s['next'], s['changes'], s['want_install']), ('', '', [], False))

    def test_switch_to_beta_installs_main(self):
        self.on_stable()
        self.commit('b.txt', 'two', 'Beta change')   # pushed to main only
        self.assertEqual(updater.check(FakeDevice())['result'], 'latest')
        updater.set_channel('main')
        s = updater.check(FakeDevice())
        self.assertEqual((s['result'], s['changes']), ('available', ['Beta change']))
        self.assertEqual(self.branch(), 'stable')   # only looked
        self.assertEqual(updater.request_install(FakeDevice())['result'], 'installing')
        self.assertEqual(self.branch(), 'main')
        self.assertTrue((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [self.work])

    def test_failed_switch_restores_branch_and_commit(self):
        self.on_stable()
        old = self.head()
        self.commit('b.txt', 'two', 'Broken beta')
        updater.set_channel('main')
        self.tests_ok = False
        self.assertEqual(updater.check(FakeDevice(), manual=True, install=True)['result'], 'failed')
        self.assertEqual((self.branch(), self.head()), ('stable', old))
        self.assertFalse((self.work / 'b.txt').exists())
        self.assertEqual(self.installs, [])

    def test_back_to_stable_waits_until_stable_catches_up(self):
        self.on_stable()
        self.commit('b.txt', 'two', 'Beta change')
        updater.set_channel('main')
        updater.request_install(FakeDevice())
        beta = self.head()
        with patch.object(paths, 'running_revision', return_value=beta):   # now runs the beta build
            updater.set_channel('stable')
            s = updater.check(FakeDevice())
            self.assertEqual(s['result'], 'skipped')
            self.assertIn('stable', s['detail'])
            self.assertEqual(self.branch(), 'main')
            self.publish('stable')   # stable publishes the beta commit
            self.assertEqual(updater.check(FakeDevice())['result'], 'latest')
            self.assertEqual((self.branch(), self.head()), ('stable', beta))
            self.commit('c.txt', 'three', 'Next')
            self.publish('stable')
            s = updater.check(FakeDevice())
            self.assertEqual((s['result'], s['changes']), ('available', ['Next']))
        self.assertEqual(len(self.installs), 1)


    def test_timed_out_switch_restores_and_stops_retrying(self):
        self.on_stable()
        old = self.head()
        self.commit('b.txt', 'two', 'Slow beta')
        updater.set_channel('main')
        with patch.object(updater, 'compile_app', side_effect=subprocess.TimeoutExpired('build', 1200)):
            s = updater.request_install(FakeDevice())
        self.assertEqual(s['result'], 'failed')
        self.assertFalse(s['want_install'])
        self.assertEqual((self.branch(), self.head()), ('stable', old))
        self.assertEqual(self.installs, [])
        self.assertEqual(updater.check(FakeDevice())['result'], 'failed')   # not built again by itself
        self.assertEqual(self.ran_tests, 1)

    def test_unexpected_install_error_stops_retrying(self):
        self.commit('b.txt', 'two', 'Add b')
        with patch.object(updater, 'install_app', side_effect=RuntimeError('Installer failed')):
            s = updater.request_install(FakeDevice())
        self.assertEqual(s['result'], 'error')
        self.assertFalse(s['want_install'])

    def test_channel_changed_during_a_check_discards_its_result(self):
        self.on_stable()
        self.commit('b.txt', 'two', 'Beta change')   # main only: stable has nothing new
        real = updater._check

        def switched_meanwhile(*args):
            result = real(*args)
            if updater.channel() == 'stable':
                updater.set_channel('main')   # the user picked Beta while stable was checked
            return result
        with patch.object(updater, '_check', side_effect=switched_meanwhile):
            s = updater.check(FakeDevice())
        self.assertEqual((s['result'], s['changes']), ('available', ['Beta change']))
        self.assertEqual((self.installs, self.ran_tests), ([], 0))


    def test_progress_follows_real_work_and_reuses_stage_times(self):
        self.commit('b.txt', 'two', 'Add b')
        seen = []
        def stage(name):
            def run(root):
                snapshot = updater.status()['progress']
                seen.append(snapshot['stage'])
                self.assertEqual(snapshot['stage'], name)
                return True, name + ' output'
            return run
        with patch.object(updater, 'run_tests', side_effect=stage('test')), \
                patch.object(updater, 'compile_app', side_effect=stage('build')):
            updater.request_install(FakeDevice())
        self.assertEqual(seen, ['test', 'build'])
        self.assertEqual(updater.status()['progress']['stage'], 'install')
        self.assertIn('build', updater.load_state()['step_times'])
        updater.check(FakeDevice())
        self.assertIsNone(updater.status()['progress'])

    def test_failed_and_waiting_progress_stop_at_the_actual_stage(self):
        self.commit('b.txt', 'two', 'Add b')
        self.tests_ok = False
        updater.request_install(FakeDevice())
        failed = updater.status()['progress']
        self.assertEqual(failed['stage'], 'test')
        self.assertTrue(failed['failed'])
        self.assertEqual(failed['line'], 'log')
        self.assertIn('stopped', failed)
        self.tests_ok = True
        with patch.object(updater, 'compile_app', return_value=(False, 'compiler failed')):
            updater.request_install(FakeDevice())
        self.assertEqual(updater.status()['progress']['stage'], 'build')
        face_modes.save_settings(timer={'end': time.time() + 60, 'total': 60, 'color': 'blue'})
        updater.request_install(FakeDevice())
        waiting = updater.status()['progress']
        self.assertTrue(waiting['waiting'])
        self.assertFalse(waiting['failed'])


class LoggedCommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = patch.object(paths, 'DATA', Path(self.tmp.name) / 'data')
        p.start()
        self.addCleanup(p.stop)
        p = patch.object(updater, '_progress', None)
        p.start()
        self.addCleanup(p.stop)
        updater.progress_step('test')

    def test_output_is_live_and_bounded_with_a_failing_exit(self):
        reported = threading.Event()
        real = updater.progress_output
        def output(text):
            real(text)
            reported.set()
        with patch.object(updater, 'progress_output', side_effect=output):
            def run():
                self.reply = updater._run_logged(
                    [sys.executable, '-u', '-c',
                     "import sys,time; print('ready', flush=True); time.sleep(1); "
                     "print('x'*5000); print('last line'); sys.exit(7)"],
                    Path(self.tmp.name), timeout=10)
            worker = threading.Thread(target=run)
            worker.start()
            try:
                self.assertTrue(reported.wait(5))
                self.assertTrue(worker.is_alive())
                self.assertEqual(updater.progress_status()['line'], 'ready')
            finally:
                worker.join(10)
        self.assertFalse(worker.is_alive())
        self.assertFalse(self.reply[0])
        self.assertLessEqual(len(self.reply[1]), 2000)
        self.assertTrue(self.reply[1].endswith('last line\n'))
        self.assertEqual(updater.progress_status()['line'], 'last line')

    def test_timeout_stops_the_command(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            updater._run_logged([sys.executable, '-c', 'import time; time.sleep(10)'],
                                Path(self.tmp.name), timeout=0.05)

if __name__ == '__main__':
    unittest.main()
