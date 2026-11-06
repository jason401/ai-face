"""First installation (tools/first_install.py) with disposable ad-hoc signed bundles."""
import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location('first_install', TOOLS / 'first_install.py')
fi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fi)


def bundle(path, mark):
    """A minimal signed AI Face-shaped app; a different mark gives a different signature."""
    (path / 'Contents/MacOS').mkdir(parents=True)
    (path / 'Contents/Helpers').mkdir()
    shutil.copy('/usr/bin/true', path / 'Contents/MacOS/AIFace')
    shutil.copy('/usr/bin/true', path / 'Contents/Helpers/InstallBridge')
    res = path / 'Contents/Resources'
    for name in ['core/run_server.py', 'core/ai_face_mcp.py', 'core/ai_face_awake.py',
                 'firmware/ESP32_Display/ESP32_Display.ino', 'install_app.py']:
        (res / name).parent.mkdir(parents=True, exist_ok=True)
        (res / name).write_text(mark)
    with (path / 'Contents/Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleIdentifier': 'local.aiface', 'CFBundleExecutable': 'AIFace',
                       'CFBundlePackageType': 'APPL', 'AISourceRevision': mark}, f)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'local.aiface', str(path)],
                   check=True, capture_output=True)
    return path


class FirstInstallTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.staged = bundle(self.root / 'build' / 'AI Face.update.app', 'new')
        self.target = self.root / 'Applications' / 'AI Face.app'
        self.target.parent.mkdir()
        self.trash = self.root / 'Trash'

    def revision(self, app):
        with (app / 'Contents/Info.plist').open('rb') as f:
            return plistlib.load(f)['AISourceRevision']

    def test_fresh_mac(self):
        self.assertEqual(fi.install(self.staged, self.target, self.trash, open_app=False), 'installed')
        self.assertEqual(self.revision(self.target), 'new')
        self.assertFalse(self.trash.exists())
        self.assertEqual([p.name for p in self.target.parent.iterdir()], ['AI Face.app'])   # no leftovers

    def test_app_signed_on_another_mac_is_replaced(self):
        bundle(self.target, 'old download')
        self.assertEqual(fi.install(self.staged, self.target, self.trash, open_app=False), 'installed')
        self.assertEqual(self.revision(self.target), 'new')
        moved = list(self.trash.iterdir())
        self.assertEqual(len(moved), 1)
        self.assertEqual(self.revision(moved[0]), 'old download')

    def test_app_signed_on_this_mac_is_left_alone(self):
        subprocess.run(['/usr/bin/ditto', str(self.staged), str(self.target)], check=True)
        inode = self.target.stat().st_ino
        self.assertEqual(fi.install(self.staged, self.target, self.trash, open_app=False), 'kept')
        self.assertEqual(self.target.stat().st_ino, inode)   # the same folder, untouched
        self.assertFalse(self.trash.exists())

    def test_incomplete_build_is_refused(self):
        (self.staged / 'Contents/Resources/core/ai_face_mcp.py').unlink()
        with self.assertRaises(Exception):
            fi.install(self.staged, self.target, self.trash, open_app=False)
        self.assertFalse(self.target.exists())


if __name__ == '__main__':
    unittest.main()
