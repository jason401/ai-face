"""Where AI Face keeps things, in one place so the app, the MCP server and the tools agree."""
from pathlib import Path

# User data (settings, photo library, history, firmware build cache, the MCP server file).
DATA = Path.home() / 'Library' / 'Application Support' / 'AI Face'
LEGACY_DATA = Path.home() / 'Library' / 'Application Support' / 'ESP32Face'   # before October 2026
SETTINGS = DATA / 'settings.json'
DISCOVERY = DATA / 'controller.json'      # port/token of the running app, for the MCP server
CATALOG = DATA / 'moods.json'             # the moods, for the MCP server's tool list
LIBRARY = DATA / 'Photo Library'          # originals of photos dropped into the app
LIBRARY_KO = DATA / '사진 보관함'           # its name before the app had an English version
LEGACY_PROJECT = Path.home() / 'Documents' / 'ESP32'

PACKAGE = Path(__file__).resolve().parent  # core/aiface in the project


def migrate_data():
    """Move the data folder of earlier versions (ESP32Face) to its new name, once."""
    if LEGACY_DATA.is_dir() and not DATA.exists():
        LEGACY_DATA.rename(DATA)
        return True
    return False


def project_root():
    """The AI Face project folder (with firmware/ and core/), or None if unknown."""
    here = PACKAGE.parents[1]
    if (here / 'firmware').is_dir() and (here / 'core').is_dir():
        return here
    return None


def app_bundle():
    """Installed bundle inferred from this package, or the explicit app launch context."""
    import os
    configured = os.environ.get('AIFACE_APP_BUNDLE')
    if configured:
        return Path(configured)
    for parent in PACKAGE.parents:
        if parent.suffix == '.app' and (parent / 'Contents/Info.plist').is_file():
            return parent
    return None


def app_executable():
    bundle = app_bundle()
    if bundle:
        return bundle / 'Contents/MacOS/AIFace'
    root = project_root()
    return root / 'AI Face.app/Contents/MacOS/AIFace' if root else None


def running_revision():
    import os
    return os.environ.get('AIFACE_REVISION', '')


def update_source():
    return DATA / 'source'
