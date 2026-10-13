"""Calendar reading with a fake app binary (the real one needs EventKit on a Mac)."""
import datetime
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isolate  # noqa: E402,F401
sys.path.insert(0, str(ROOT / 'core'))
from aiface import calendar_access as cal, moods  # noqa: E402

FAKE = r'''#!/usr/bin/env python3
import json, sys
args = sys.argv[2:]
log = open(sys.argv[0] + '.log', 'a'); log.write(json.dumps(args) + '\n'); log.close()
access = open(sys.argv[0] + '.access').read().strip()
if args[0] == 'status':
    print(json.dumps({'status': access})); sys.exit()
if access != 'full':
    print(json.dumps({'error': 'no_access', 'status': access})); sys.exit()
if args[0] == 'calendars':
    print(json.dumps([{'id': 'w', 'title': 'Calendar', 'account': 'Stanford', 'kind': 'exchange'},
                      {'id': 'h', 'title': 'US Holidays', 'account': 'Subscribed', 'kind': 'subscribed'}]))
elif args[0] == 'events':
    start = float(args[1])
    ids = args[3].split(',')
    out = []
    if 'w' in ids:
        e = {'title': 'Meeting with Prof', 'start': start + 14 * 3600, 'end': start + 15 * 3600, 'all_day': False,
             'location': 'Packard 312', 'calendar': 'Calendar', 'calendar_id': 'w'}
        if args[4] == 'details':
            e.update(notes='Zoom 123  passcode 9', attendees=['A', 'B'])
        out.append(e)
    if 'h' in ids:
        out.append({'title': 'Holiday', 'start': start, 'end': start + 86400, 'all_day': True, 'location': '',
                    'calendar': 'US Holidays', 'calendar_id': 'h'})
    print(json.dumps(out))
'''


class CalendarTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.exe = Path(tmp.name) / 'AIFace'
        self.exe.write_text(FAKE)
        self.exe.chmod(self.exe.stat().st_mode | stat.S_IEXEC)
        self.access('full')
        p = patch.object(cal, 'binary', return_value=self.exe); p.start(); self.addCleanup(p.stop)
        p = patch.object(moods, 'SETTINGS', Path(tmp.name) / 'settings.json'); p.start(); self.addCleanup(p.stop)
        self.now = datetime.datetime(2026, 10, 15, 9, 0)

    def access(self, value):
        Path(str(self.exe) + '.access').write_text(value)

    def calls(self):
        return [json.loads(x) for x in Path(str(self.exe) + '.log').read_text().splitlines()]

    def test_claude_reads_today_by_default_gpt_does_not(self):
        text = cal.events('claude', now=self.now)
        self.assertIn('2026-10-15 Thu', text)
        self.assertIn('- 10-15 Thu 14:00–15:00 Meeting with Prof @ Packard 312 [Calendar]', text)
        self.assertIn('10-15 Thu all day Holiday [US Holidays]', text)
        self.assertNotIn('passcode', text)                     # details are off by default
        with self.assertRaises(PermissionError):
            cal.events('gpt', now=self.now)
        cal.save({'apps': {'gpt': True}})
        self.assertIn('Meeting', cal.events('gpt', now=self.now))

    def test_hidden_calendars_details_and_query(self):
        cal.save({'hidden': ['h'], 'details': True})
        text = cal.events('claude', '2026-10-15', '2026-10-16', now=self.now)
        self.assertNotIn('Holiday', text)
        self.assertIn('with A, B', text)
        self.assertIn('notes: Zoom 123 passcode 9', text)
        last = self.calls()[-1]
        self.assertEqual((last[0], last[3], last[4]), ('events', 'w', 'details'))
        self.assertEqual(float(last[2]) - float(last[1]), 2 * 86400)     # end date is inclusive
        self.assertIn('No events', cal.events('claude', query='dentist', now=self.now))
        status = cal.status()
        self.assertEqual(status['access'], 'full')
        self.assertEqual({c['id']: c['shown'] for c in status['calendars']}, {'w': True, 'h': False})
        self.assertEqual(moods.load_settings()['calendar']['hidden'], ['h'])   # kept by other saves
        moods.save_settings(mono=True)
        self.assertEqual(cal.settings()['hidden'], ['h'])

    def test_bad_ranges_and_no_access(self):
        for start, end in (('2026-10-15', '2026-10-14'), ('2026-10-01', '2026-12-31'), ('soon', None)):
            with self.assertRaises(ValueError):
                cal.events('claude', start, end, now=self.now)
        self.access('notDetermined')
        with self.assertRaises(PermissionError):
            cal.events('claude', now=self.now)
        self.assertEqual(cal.status()['access'], 'notDetermined')


if __name__ == '__main__':
    unittest.main()
