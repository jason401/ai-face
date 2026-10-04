"""Imported by every test module before aiface: a temporary HOME, so tests never read or
write the real AI Face data folder (settings, photos, expression history)."""
import atexit
import os
import shutil
import tempfile

if not os.environ.get('AIFACE_TEST_HOME'):
    HOME = tempfile.mkdtemp(prefix='aiface-test-home-')
    os.environ['AIFACE_TEST_HOME'] = HOME
    os.environ['HOME'] = HOME
    atexit.register(shutil.rmtree, HOME, True)
