"""Where AI Face keeps things, in one place so the app, the MCP server and the tools agree."""
import json
from pathlib import Path

# User data (settings, photo library, thumbnails, firmware build cache, MCP runtime).
# The folder keeps its ESP32-era name until the app itself is renamed and bundled.
DATA = Path.home() / 'Library' / 'Application Support' / 'ESP32Face'
SETTINGS = DATA / 'settings.json'
DISCOVERY = DATA / 'controller.json'      # port/token of the running app, for the MCP server
LIBRARY = DATA / '사진 보관함'              # originals of photos dropped into the app
SOURCE_INFO = DATA / 'source.json'        # project folder, recorded by tools/install_mcp.py
LEGACY_PROJECT = Path.home() / 'Documents' / 'ESP32'

PACKAGE = Path(__file__).resolve().parent  # core/aiface in the project, or the MCP runtime copy


def project_root():
    """The AI Face project folder (with firmware/ and web/), or None if unknown."""
    here = PACKAGE.parents[1]
    if (here / 'firmware').is_dir() and (here / 'web').is_dir():
        return here
    try:
        root = Path(json.loads(SOURCE_INFO.read_text())['source'])
        return root if (root / 'firmware').is_dir() else None
    except (OSError, ValueError, KeyError, TypeError):
        return None
