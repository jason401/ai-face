"""Keep awake with a fake pmset and sudo (the real ones only exist on a Mac)."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import awake  # noqa: E402

PMSET = r'''#!/bin/sh
# fake pmset: -g prints SleepDisabled from a file, "-a disablesleep N" writes it, -g batt
D="$(dirname "$0")"
if [ "$1" = "-g" ] && [ "$2" = "batt" ]; then cat "$D/batt"; exit 0; fi
if [ "$1" = "-g" ]; then echo " standby 1"; echo " SleepDisabled $(cat "$D/value")"; exit 0; fi
if [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then echo "$3" > "$D/value"; echo "$3" >> "$D/calls"; exit 0; fi
exit 1
'''
SUDO = r'''#!/bin/sh
# fake sudo: only "-n" use; allowed when the "rule" file exists
D="$(dirname "$0")"
[ "$1" = "-n" ] || exit 1; shift
[ -f "$D/rule" ] || exit 1
if [ "$1" = "-l" ]; then exit 0; fi
exec "$@"
'''


class AwakeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        for name, text in (('pmset', PMSET), ('sudo', SUDO)):
            f = self.dir / name
            f.write_text(text)
            f.chmod(f.stat().st_mode | stat.S_IEXEC)
        (self.dir / 'value').write_text('0\n')
        (self.dir / 'rule').write_text('')
        self.batt("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%; charging;")
        for name, value in (('PMSET', str(self.dir / 'pmset')), ('SUDO', str(self.dir / 'sudo')),
                            ('STATE', self.dir / 'awake.json')):
            p = patch.object(awake, name, value); p.start(); self.addCleanup(p.stop)
        awake._cache.update(on=False, ready=None, checked=0.0)
        self.addCleanup(lambda: awake.stop('test end'))

    def batt(self, text):
        (self.dir / 'batt').write_text(text + '\n')

    def value(self):
        return (self.dir / 'value').read_text().strip()

    def test_on_then_off(self):
        self.assertEqual((awake.status()['ready'], awake.status()['on']), (True, False))
        s = awake.start(60)
        self.assertEqual((s['on'], s['ours'], self.value()), (True, True, '1'))
        self.assertGreater(s['left'], 3590)
        failsafe = json.loads(awake.STATE.read_text())['failsafe']
        self.assertIsNone(subprocess.run(['kill', '-0', str(failsafe)]).returncode or None)
        self.assertTrue(awake.stop('by hand'))
        self.assertEqual((self.value(), awake.STATE.exists(), awake.last_reason), ('0', False, 'by hand'))
        time.sleep(0.2)
        self.assertNotEqual(subprocess.run(['kill', '-0', str(failsafe)], stderr=subprocess.DEVNULL).returncode, 0)

    def test_deadline_and_battery(self):
        now = time.time()
        awake.start(1, now)
        self.assertEqual(awake.check(now + 30), '')
        self.assertEqual(self.value(), '1')
        self.assertTrue(awake.check(now + 61))          # time is up
        self.assertEqual(self.value(), '0')
        awake.start(120)
        self.batt("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t19%; discharging;")
        self.assertIn('19%', awake.check())
        self.assertEqual(self.value(), '0')
        with self.assertRaises(ValueError):             # and it will not turn on like this
            awake.start(60)

    def test_needs_setup_and_valid_minutes(self):
        (self.dir / 'rule').unlink()
        awake._cache['ready'] = None
        self.assertFalse(awake.status()['ready'])
        with self.assertRaises(ValueError):
            awake.start(60)
        (self.dir / 'rule').write_text('')
        for bad in (0, -5, 10000, True, '60'):
            with self.assertRaises(ValueError):
                awake.start(bad)
        self.assertEqual(self.value(), '0')

    def test_failsafe_turns_off_without_the_app(self):
        awake.set_state(True)
        pid = awake._start_failsafe(1)
        self.assertTrue(pid)
        deadline = time.time() + 5
        while self.value() != '0' and time.time() < deadline:
            time.sleep(0.1)
        self.assertEqual(self.value(), '0')

    def test_only_turns_off_what_it_turned_on(self):
        (self.dir / 'value').write_text('1\n')     # another app keeps the Mac awake
        self.assertFalse(awake.stop('quit'))
        self.assertEqual(self.value(), '1')
        self.assertTrue(awake.stop('by hand', force=True))
        self.assertEqual(self.value(), '0')

    def test_startup_forgets_a_period_lost_to_a_restart(self):
        awake.start(60)
        (self.dir / 'value').write_text('0\n')     # the Mac restarted: the setting is back to 0
        awake.startup()
        self.assertFalse(awake.STATE.exists())
        awake.start(60)
        awake.startup(time.time() + 3601)          # ran out while the app was closed
        self.assertEqual((self.value(), awake.STATE.exists()), ('0', False))


if __name__ == '__main__':
    unittest.main()
