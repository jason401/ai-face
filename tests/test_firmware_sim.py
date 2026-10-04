"""Builds the firmware against stub Arduino APIs and runs the simulator tests."""
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('c++') or shutil.which('clang++') or shutil.which('g++'), 'no C++ compiler')
class FirmwareSimTests(unittest.TestCase):
    def test_simulator(self):
        done = subprocess.run(['bash', str(ROOT / 'tools' / 'firmware_sim' / 'run.sh')],
                              capture_output=True, text=True, timeout=600)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('firmware simulator: OK', done.stdout)


if __name__ == '__main__':
    unittest.main()
