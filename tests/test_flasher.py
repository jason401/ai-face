import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import flasher  # noqa: E402


class FlasherTests(unittest.TestCase):
    """Runs flasher.flash against a fake arduino-cli shell script."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.cli = root / 'arduino-cli'; self.log = root / 'calls.txt'
        for name, value in (('BUILD', root / 'build'), ('IDE_CONFIG', root / 'none.yaml')):
            p = patch.object(flasher, name, value); p.start(); self.addCleanup(p.stop)
        p = patch.dict(os.environ, {'ARDUINO_CLI': str(self.cli)}); p.start(); self.addCleanup(p.stop)

    def fake(self, compile_code=0, upload_code=0, compile_out='Sketch uses 345678 bytes (10%) of program storage space.'):
        self.cli.write_text(f"""#!/bin/sh
echo "$@" >> '{self.log}'
case "$2" in
  compile) echo '{compile_out}'; exit {compile_code} ;;
  upload) echo 'Hard resetting via RTS pin...'; [ {upload_code} -ne 0 ] && echo 'Could not open port: Resource busy' >&2; exit {upload_code} ;;
esac
""")
        self.cli.chmod(self.cli.stat().st_mode | stat.S_IEXEC)

    def test_compile_and_upload(self):
        self.fake()
        report = flasher.flash('/dev/cu.usbmodem1101')
        self.assertIn('업로드 완료', report); self.assertIn('Sketch uses', report)
        calls = self.log.read_text().splitlines()
        self.assertTrue(calls[0].startswith('--no-color compile --fqbn esp32:esp32:XIAO_ESP32S3 --build-path'))
        self.assertTrue(calls[0].endswith('ESP32_Display'))
        self.assertIn('--no-color upload -p /dev/cu.usbmodem1101 --fqbn esp32:esp32:XIAO_ESP32S3 --input-dir', calls[1])

    def test_compile_error_is_returned(self):
        self.fake(compile_code=1, compile_out="ESP32_Display.ino:88:10: error: x was not declared")
        with self.assertRaises(flasher.FlashError) as ctx: flasher.flash('/dev/cu.usbmodem1101')
        self.assertIn("88:10: error: x was not declared", str(ctx.exception))
        self.assertEqual(len(self.log.read_text().splitlines()), 1)   # no upload attempted

    def test_busy_port_hint(self):
        self.fake(upload_code=2)
        with self.assertRaises(flasher.FlashError) as ctx: flasher.flash('/dev/cu.usbmodem1101')
        self.assertIn('Serial Monitor', str(ctx.exception))

    def test_missing_cli(self):
        with patch.dict(os.environ, {'ARDUINO_CLI': ''}), patch.object(flasher, 'CLI_CANDIDATES', []), \
                patch.object(flasher.shutil, 'which', return_value=None):
            with self.assertRaises(flasher.FlashError) as ctx: flasher.find_cli()
        self.assertIn('Arduino IDE', str(ctx.exception))


if __name__ == '__main__':
    unittest.main()
