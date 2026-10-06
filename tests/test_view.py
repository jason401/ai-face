import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import moods as face_modes  # noqa: E402
from aiface import board as esp_display  # noqa: E402


class ViewTests(unittest.TestCase):
    """What the menu bar shows, with no board attached."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        p = patch.object(face_modes, 'SETTINGS', Path(self.tmp.name) / 'settings.json'); p.start(); self.addCleanup(p.stop)
        p = patch.object(esp_display, 'ports', return_value=[]); p.start(); self.addCleanup(p.stop)
        p = patch.object(face_modes, 'PHOTO_DIR', Path(self.tmp.name) / 'photos'); p.start(); self.addCleanup(p.stop)
        self.d = esp_display.Device()
        self.happy = next(m for m in face_modes.emotions() if m['id'] == 'happy')

    def test_emotion_without_board(self):
        self.d.show_emotion(self.happy, 'claude')
        v = self.d.view()
        self.assertEqual((v['kind'], v['emotion'], v['owner'], v['board']), ('face', 'happy', 'claude', False))
        self.assertEqual(v['name'], '행복')
        self.assertIn('메뉴바', self.d.message)

    def test_working_mood_left_on_returns_to_calm(self):
        from aiface import history
        by = {m['id']: m for m in face_modes.emotions()}
        self.d.show_emotion(by['processing'], 'claude')
        start = self.d.changed
        self.assertFalse(self.d.expire_working(start + 60))
        logged = len(history.recent(50))
        self.assertTrue(self.d.expire_working(start + 200))
        self.assertEqual((self.d.emotion, self.d.owner, self.d.changed), ('calm', 'claude', start))
        self.assertEqual(len(history.recent(50)), logged)   # not logged as a choice
        self.d.show_emotion(by['thinking'], 'claude')        # a reply's tone: stays
        self.assertFalse(self.d.expire_working(self.d.changed + 999))
        self.d.show_emotion(by['processing'], 'user')        # picked by hand: stays
        self.assertFalse(self.d.expire_working(self.d.changed + 999))

    def test_nothing_chosen_yet_is_asleep(self):
        self.assertEqual(self.d.view()['emotion'], 'sleeping')

    def test_screen_saver(self):
        face_modes.save_settings(saver=dict(after=1, type='sleep', clock=False, slide=60))
        self.d.show_emotion(self.happy)
        now = time.time()
        self.assertEqual(self.d.view(now + 30)['emotion'], 'happy')
        self.assertEqual(self.d.view(now + 61)['emotion'], 'sleepy')
        self.assertEqual(self.d.view(now + 121)['emotion'], 'sleeping')
        face_modes.save_settings(saver=dict(after=1, type='fire', clock=False, slide=60))
        self.assertEqual(self.d.view(now + 61)['kind'], 'fire')
        face_modes.save_settings(saver=dict(after=1, type='photo', clock=True, slide=60))
        self.assertEqual(self.d.view(now + 61)['emotion'], 'sleeping')    # no photo on this Mac: asleep
        face_modes.PHOTO_DIR.mkdir()
        for pid in (2, 5):
            face_modes.photo_copy(pid).write_bytes(bytes(face_modes.PHOTO_BYTES))
        v = self.d.view(now + 61)
        self.assertEqual((v['kind'], v['photo'], v['clock'], v['name']), ('photo', 2, True, '사진'))
        face_modes.save_settings(saver=dict(after=1, type='slideshow', clock=False, slide=30))
        self.assertEqual([self.d.view(now + 61 + k * 30)['photo'] for k in range(3)], [2, 5, 2])
        face_modes.save_settings(saver=dict(after=1, type='clock', clock=False, slide=60))
        self.assertEqual(self.d.view(now + 61)['kind'], 'clock')
        face_modes.save_settings(saver=dict(after=1, type='off', clock=False, slide=60))
        self.assertEqual(self.d.view(now + 9999)['emotion'], 'happy')

    def test_history_and_mono(self):
        from aiface import history
        self.d.show_emotion(self.happy, 'claude')
        self.d.show_emotion(self.happy, 'gpt')
        last = history.recent(5)
        self.assertEqual([(e['owner'], e['emotion']) for e in last][:2], [('gpt', 'happy'), ('claude', 'happy')])
        self.assertFalse(self.d.view()['mono'])
        self.d.set_style(True)
        self.assertTrue(self.d.view()['mono'] and face_modes.load_settings()['mono'])
        with self.assertRaises(ValueError):
            self.d.set_style('yes')

    def test_clock_and_timer_without_board(self):
        self.d.set_mode('FIRE')
        self.assertEqual((self.d.view()['kind'], self.d.view()['name']), ('fire', '모닥불'))
        self.d.set_mode('CLOCK')
        self.assertEqual(self.d.view()['kind'], 'clock')
        self.d.start_timer(120, 'red')
        t = self.d.view()['timer']
        self.assertEqual((t['total'], t['color']), (120, 'red'))
        self.assertTrue(118 <= t['left'] <= 120)


if __name__ == '__main__':
    unittest.main()
