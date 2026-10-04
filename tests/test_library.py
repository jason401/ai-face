import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import library as lib  # noqa: E402


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        p = patch.object(lib, 'FOLDER', Path(self.tmp.name) / '사진 보관함'); p.start(); self.addCleanup(p.stop)
        p = patch.object(lib, 'LEGACY', Path(self.tmp.name) / 'old'); p.start(); self.addCleanup(p.stop)

    def test_add_list_read_delete(self):
        self.assertEqual(lib.listing(), [])
        a = lib.add('방.png', b'one')
        self.assertEqual(a, '방.png')
        self.assertEqual(lib.add('other name.png', b'one'), '방.png')     # same picture: no duplicate
        self.assertEqual(lib.add('방.png', b'two'), '방 (2).png')          # same name, other picture
        self.assertEqual(lib.add('../../evil.sh', b'three'), 'evil.jpg')   # no paths, image extension
        self.assertEqual(lib.add('', b'four'), 'photo.jpg')
        self.assertEqual({i['name'] for i in lib.listing()}, {'방.png', '방 (2).png', 'evil.jpg', 'photo.jpg'})
        self.assertEqual(lib.read('방 (2).png'), (b'two', 'image/png'))
        lib.delete('evil.jpg')
        self.assertNotIn('evil.jpg', {i['name'] for i in lib.listing()})
        with self.assertRaises(ValueError): lib.add('big.jpg', b'')

    def test_names_cannot_escape_the_folder(self):
        lib.add('a.jpg', b'x')
        (Path(self.tmp.name) / 'secret.jpg').write_bytes(b's')
        for bad in ('../secret.jpg', '/etc/passwd', '.hidden.jpg', '', None, 'missing.jpg'):
            with self.assertRaises(ValueError): lib.path_of(bad)

    def test_pictures_move_over_from_the_old_project_folder_once(self):
        lib.LEGACY.mkdir()
        (lib.LEGACY / 'room.png').write_bytes(b'r')
        (lib.LEGACY / 'notes.txt').write_bytes(b'n')
        self.assertEqual([i['name'] for i in lib.listing()], ['room.png'])
        lib.delete('room.png')
        self.assertEqual(lib.listing(), [])          # not copied again
        self.assertTrue((lib.LEGACY / 'room.png').exists())   # the original stays

    def test_finder_files_and_decomposed_names(self):
        lib.FOLDER.mkdir()
        nfd = unicodedata.normalize('NFD', '사진.HEIC')   # how macOS stores Korean names
        (lib.FOLDER / nfd).write_bytes(b'h')
        (lib.FOLDER / 'notes.txt').write_bytes(b'no')
        (lib.FOLDER / '.DS_Store').write_bytes(b'no')
        self.assertEqual([i['name'] for i in lib.listing()], ['사진.HEIC'])
        self.assertEqual(lib.read('사진.HEIC'), (b'h', 'image/heic'))


if __name__ == '__main__':
    unittest.main()
