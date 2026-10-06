import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import history, moods  # noqa: E402


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        p = patch.object(history, 'FOLDER', Path(self.tmp.name) / 'history'); p.start(); self.addCleanup(p.stop)

    def test_summary_week_and_recent(self):
        noon = time.mktime((2026, 10, 4, 12, 0, 0, 0, 0, -1))
        for i, (who, mood) in enumerate([('claude', 'happy'), ('claude', 'thinking'), ('claude', 'happy'),
                                          ('gpt', 'sad'), ('user', 'calm')]):
            history.record(who, mood, noon + i * 60)
        history.record('claude', 'idea', noon - 86400)      # yesterday
        history.record('robot', 'happy', noon)              # ignored
        (history.FOLDER / '2026-10-04.jsonl').open('a').write('not json\n')
        s = history.summary('2026-10-04', moods.emotions())
        self.assertEqual(s['total'], 5)
        self.assertEqual(s['owners']['claude']['count'], 3)
        self.assertEqual(s['owners']['claude']['top'][0], dict(id='happy', name='행복', count=2))
        self.assertEqual(s['owners']['claude']['groups'], {'joy': 2, 'mind': 1})
        self.assertEqual([e['owner'] for e in s['timeline']], ['claude', 'claude', 'claude', 'gpt', 'user'])
        w = history.week('2026-10-04')
        self.assertEqual(len(w), 7)
        self.assertEqual(w[-1], dict(day='2026-10-04', claude=3, gpt=1, user=1))
        self.assertEqual(w[-2]['claude'], 1)
        r = history.recent(3, noon + 600)
        self.assertEqual([e['emotion'] for e in r], ['calm', 'sad', 'happy'])
        self.assertEqual(history.summary('bad-day', [])['total'], 0)

    def test_clear(self):
        history.record('claude', 'happy', time.time() - 3 * 86400)
        history.record('gpt', 'sad')
        history.record('user', 'calm')
        self.assertEqual(history.clear(), 3)
        self.assertEqual(history.recent(10), [])
        self.assertEqual(history.clear(), 0)

    def test_prune(self):
        history.record('user', 'calm', time.time() - 500 * 86400)
        history.record('user', 'calm')
        history.prune()
        self.assertEqual(len(list(history.FOLDER.iterdir())), 1)


if __name__ == '__main__':
    unittest.main()
