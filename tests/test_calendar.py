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
import threading  # noqa: E402
import time  # noqa: E402

FAKE = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[2:]
here = sys.argv[0]
log = open(here + '.log', 'a'); log.write(json.dumps(args) + '\n'); log.close()
access = open(here + '.access').read().strip()
store = here + '.store'
added = json.load(open(store)) if os.path.exists(store) else []
if args[0] == 'status':
    print(json.dumps({'status': access})); sys.exit()
if access != 'full':
    print(json.dumps({'error': 'no_access', 'status': access})); sys.exit()
if args[0] == 'calendars':
    print(json.dumps([{'id': 'w', 'title': 'Calendar', 'account': 'Stanford', 'kind': 'exchange', 'writable': True, 'default': True},
                      {'id': 'h', 'title': 'US Holidays', 'account': 'Subscribed', 'kind': 'subscribed', 'writable': False, 'default': False},
                      {'id': 'home', 'title': 'Home', 'account': 'iCloud', 'kind': 'caldav', 'writable': True, 'default': False}]))
elif args[0] == 'events':
    import datetime
    start = float(args[1]); end = float(args[2])
    ids = args[3].split(',') if args[3] != '-' else ['w', 'h', 'home']
    first = datetime.datetime.fromtimestamp(start)
    start = datetime.datetime(first.year, first.month, first.day).timestamp()   # events at fixed times of day
    if start < float(args[1]):
        start += 86400
    out = []
    if 'w' in ids and start + 14 * 3600 < end:
        e = {'id': 'EX1', 'title': 'Meeting with Prof', 'start': start + 14 * 3600, 'end': start + 15 * 3600, 'all_day': False,
             'location': 'Packard 312', 'calendar': 'Calendar', 'calendar_id': 'w', 'ours': False}
        if args[4] == 'details':
            e.update(notes='Zoom 123  passcode 9', attendees=['A', 'B'])
        out.append(e)
    if 'h' in ids and start < end:
        out.append({'id': 'H1', 'title': 'Holiday', 'start': start, 'end': start + 86400, 'all_day': True, 'location': '',
                    'calendar': 'US Holidays', 'calendar_id': 'h', 'ours': False})
    out += [e for e in added if e['calendar_id'] in ids and start <= e['start'] < end]
    print(json.dumps(out))
elif args[0] in ('add', 'update', 'delete'):
    f = json.load(sys.stdin)
    if args[0] == 'add':
        e = dict(id='NEW%d' % (len(added) + 1), title=f['title'], start=f['start'], end=f['end'],
                 all_day=f.get('all_day', False), location=f.get('location', ''), calendar_id=f['calendar_id'],
                 calendar={'w': 'Calendar', 'home': 'Home'}[f['calendar_id']], ours=True, notes=f.get('notes', ''))
        added.append(e); json.dump(added, open(store, 'w')); print(json.dumps({'event': e})); sys.exit()
    e = next((x for x in added if x['id'] == f['id']), None)
    if e is None:
        print(json.dumps({'error': 'not_ours' if f['id'] == 'EX1' else 'not_found'})); sys.exit()
    before = dict(e)
    if args[0] == 'delete':
        added.remove(e); json.dump(added, open(store, 'w')); print(json.dumps({'before': before})); sys.exit()
    e.update({k: f[k] for k in ('title', 'start', 'end', 'all_day', 'location') if k in f})
    json.dump(added, open(store, 'w')); print(json.dumps({'before': before, 'event': e}))
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
        p = patch.object(cal, 'LOG', Path(tmp.name) / 'changes.json'); p.start(); self.addCleanup(p.stop)
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
        self.assertEqual((last[0], last[3], last[4]), ('events', 'w,home', 'details'))
        self.assertEqual(float(last[2]) - float(last[1]), 2 * 86400)     # end date is inclusive
        self.assertIn('No events', cal.events('claude', query='dentist', now=self.now))
        status = cal.status()
        self.assertEqual(status['access'], 'full')
        self.assertEqual({c['id']: c['shown'] for c in status['calendars']}, {'w': True, 'h': False, 'home': True})
        self.assertEqual(moods.load_settings()['calendar']['hidden'], ['h'])   # kept by other saves
        moods.save_settings(mono=True)
        self.assertEqual(cal.settings()['hidden'], ['h'])

    def test_place_hides_meeting_secrets_unless_details(self):
        loc = 'https://stanford.zoom.us/j/9819?pwd=abc.1\nPassword: 42571540'
        self.assertEqual(cal.place(loc, False), 'stanford.zoom.us link')
        self.assertEqual(cal.place('P083 Lucas Center', False), 'P083 Lucas Center')
        self.assertIn('pwd=abc.1 Password: 42571540', cal.place(loc, True))

    def test_writing_is_off_until_allowed(self):
        with self.assertRaises(PermissionError):
            cal.add('claude', {'title': 'x', 'start': '2026-10-15T15:00'})
        self.assertNotIn('#e', cal.events('claude', now=self.now))      # no ids for readers only

    def test_add_change_delete_undo_without_asking(self):
        cal.save({'write_apps': {'claude': True}, 'confirm': False})
        text = cal.add('claude', {'title': 'Kristen', 'start': '2026-10-15T15:00'})
        self.assertTrue(text.startswith('Added: 10-15 Thu 15:00–16:00 Kristen [Calendar] #e'))   # default calendar
        listing = cal.events('claude', '2026-10-15', now=self.now)
        short = [w for w in listing.split() if w.startswith('#e')]
        self.assertEqual(len(short), 3)                                  # holiday, professor's meeting, ours
        ours = listing.split('Kristen')[1].split()[1].lstrip('#')
        prof = listing.split('Meeting with Prof')[1].split('#')[1].split()[0]
        with self.assertRaises(PermissionError):
            cal.update('claude', prof, {'title': 'hacked'})              # not added via AI Face
        self.assertIn('16:00–17:00', cal.update('claude', ours, {'start': '2026-10-15T16:00', 'end': '2026-10-15T17:00'}))
        with self.assertRaises(PermissionError):
            cal.add('claude', {'title': 'x', 'start': '2026-10-15T15:00', 'calendar': 'US Holidays'})
        changes = cal.recent_changes()
        self.assertEqual([c['n'] for c in changes], [2, 1])
        cal.undo(2)                                                      # back to 15:00
        self.assertIn('15:00–16:00 Kristen', cal.events('claude', '2026-10-15', now=self.now))
        with self.assertRaises(ValueError):
            cal.undo(2)
        cal.undo(1)                                                      # the add: removed
        self.assertNotIn('Kristen', cal.events('claude', '2026-10-15', now=self.now))

    def test_writable_calendars_choice(self):
        cal.save({'write_apps': {'claude': True}, 'confirm': False, 'writable': ['home']})
        self.assertIn('[Home]', cal.add('claude', {'title': 'Gym', 'start': '2026-10-16T07:00'}))
        with self.assertRaises(PermissionError):
            cal.add('claude', {'title': 'x', 'start': '2026-10-16T07:00', 'calendar': 'Calendar'})
        self.assertEqual({c['id']: c['write'] for c in cal.status()['calendars']}, {'w': False, 'h': False, 'home': True})

    def test_change_waits_for_the_users_ok(self):
        cal.save({'write_apps': {'claude': True}})
        answers = []

        def user(allow):
            for _ in range(100):
                asks = cal.pending()
                if asks:
                    answers.append(asks[0]['text'])
                    cal.decide(asks[0]['id'], allow)
                    return
                time.sleep(0.02)
        t = threading.Thread(target=user, args=(False,)); t.start()
        with self.assertRaises(PermissionError):
            cal.add('claude', {'title': 'Kristen', 'start': '2026-10-15T15:00'})
        t.join()
        self.assertIn('Claude', answers[0]); self.assertIn('Kristen', answers[0])
        t = threading.Thread(target=user, args=(True,)); t.start()
        self.assertTrue(cal.add('claude', {'title': 'Kristen', 'start': '2026-10-15T15:00'}).startswith('Added'))
        t.join()
        self.assertEqual(cal.pending(), [])

    def test_safety_fixes(self):
        cal.save({'write_apps': {'claude': True}, 'confirm': False})
        first = cal.add('claude', {'title': 'Kristen', 'start': '2026-10-15T15:00'})
        again = cal.add('claude', {'title': 'Kristen', 'start': '2026-10-15T15:00'})
        self.assertTrue(again.startswith('Already there'))                       # no duplicate
        self.assertEqual(first.split('#')[1], again.split('#')[1])
        day = cal.add('claude', {'title': 'Retreat', 'start': '2026-10-16', 'all_day': True})
        store = json.loads(Path(str(self.exe) + '.store').read_text())
        retreat = next(e for e in store if e['title'] == 'Retreat')
        self.assertEqual(retreat['start'], retreat['end'])                        # one day: start = end
        self.assertIn('10-16 Fri all day Retreat', day)
        # changed by hand after the AI added it: undo refuses
        next(e for e in store if e['title'] == 'Kristen')['title'] = 'Kristen (moved)'
        Path(str(self.exe) + '.store').write_text(json.dumps(store))
        with self.assertRaises(ValueError):
            cal.undo(1)
        # repeating events are left to the user
        store[0]['recurring'] = True
        Path(str(self.exe) + '.store').write_text(json.dumps(store))
        listing = cal.events('claude', '2026-10-15', now=self.now)
        short = listing.split('Kristen (moved)')[1].split('#')[1].split()[0]
        with self.assertRaises(PermissionError):
            cal.delete('claude', short)

    def test_same_calendar_name_needs_the_account(self):
        cals = [dict(id='a', title='Calendar', account='Stanford', writable=True, default=True),
                dict(id='b', title='Calendar', account='iCloud', writable=True, default=False)]
        conf = dict(cal.settings(), writable=['a', 'b'])
        with patch.object(cal, '_calendars', return_value=cals):
            with self.assertRaises(ValueError):
                cal._target(conf, 'calendar')
            self.assertEqual(cal._target(conf, 'Calendar (iCloud)')['id'], 'b')
            self.assertEqual(cal._target(conf, None)['id'], 'a')

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
