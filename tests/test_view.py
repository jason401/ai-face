import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import moods as face_modes  # noqa: E402
from aiface import board as esp_display  # noqa: E402


class ViewTests(unittest.TestCase):
    """What the menu bar shows, with no board attached."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        p = patch.object(face_modes, 'SETTINGS', Path(self.tmp.name) / 'settings.json'); p.start(); self.addCleanup(p.stop)
        p = patch.object(esp_display, 'ports', return_value=[]); p.start(); self.addCleanup(p.stop)
        self.d = esp_display.Device()
        self.happy = next(m for m in face_modes.emotions() if m['id'] == 'happy')

    def test_emotion_without_board(self):
        self.d.show_emotion(self.happy, 'claude')
        v = self.d.view()
        self.assertEqual((v['kind'], v['emotion'], v['owner'], v['board']), ('face', 'happy', 'claude', False))
        self.assertEqual(v['name'], '행복')
        self.assertIn('메뉴바', self.d.message)

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
        face_modes.save_settings(saver=dict(after=1, type='photo', clock=False, slide=60))
        self.assertEqual(self.d.view(now + 61)['emotion'], 'sleeping')    # photo savers: asleep in the menu bar
        face_modes.save_settings(saver=dict(after=1, type='clock', clock=False, slide=60))
        self.assertEqual(self.d.view(now + 61)['kind'], 'clock')
        face_modes.save_settings(saver=dict(after=1, type='off', clock=False, slide=60))
        self.assertEqual(self.d.view(now + 9999)['emotion'], 'happy')

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
