import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import board, i18n, mcp_server, moods, paths  # noqa: E402


class LanguageTests(unittest.TestCase):
    def tearDown(self):
        i18n.set_lang('ko')

    def test_pick(self):
        for code, want in [('ko', 'ko'), ('ko-KR', 'ko'), ('en_US', 'en'), ('ja', 'en'), ('fr-CA', 'en')]:
            self.assertEqual(i18n.set_lang(code), want)

    def test_english(self):
        i18n.set_lang('en')
        by = {m['id']: m for m in moods.emotions()}
        self.assertEqual((by['hopeful']['name'], by['hopeful']['group'], by['hopeful']['group_id']),
                         ('Fingers crossed', 'Anxiety & tension', 'tense'))
        self.assertEqual(by['happy']['name_ko'], '행복')
        self.assertEqual(moods.duration_text(90), '1 min 30 s')
        with self.assertRaises(ValueError) as ctx:
            moods.timer_command(99999, 99999)
        self.assertIn('24 hours', str(ctx.exception))
        with tempfile.TemporaryDirectory() as tmp, patch.object(moods, 'SETTINGS', Path(tmp) / 's.json'), \
                patch.object(board, 'ports', return_value=[]):
            d = board.Device()
            self.assertIn('menu bar', d.message)
            d.set_mode('FIRE')
            self.assertEqual(d.view()['name'], 'Campfire')
            d.start_timer(90)
            self.assertEqual(d.message, '1 min 30 s timer started')

    def test_korean(self):
        i18n.set_lang('ko')
        self.assertEqual({m['id']: m for m in moods.emotions()}['hopeful']['name'], '조마조마')
        self.assertEqual(moods.duration_text(90), '1분 30초')

    def test_language_from_settings_survives_other_saves(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(moods, 'SETTINGS', Path(tmp) / 's.json'), \
                patch.object(paths, 'SETTINGS', Path(tmp) / 's.json'), patch.dict('os.environ', {'AIFACE_LANG': ''}):
            moods.save_settings(language='en')
            moods.save_settings(mono=True)
            self.assertEqual(json.loads(moods.SETTINGS.read_text())['language'], 'en')
            i18n._current = None
            self.assertEqual(i18n.lang(), 'en')

    def test_tool_catalog_is_bilingual(self):
        text = mcp_server.TOOLS[0]['description']
        self.assertIn('hopeful: Fingers crossed / 조마조마 (Anxiety & tension)', text)


if __name__ == '__main__':
    unittest.main()
