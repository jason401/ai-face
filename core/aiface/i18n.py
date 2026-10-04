"""Language of messages: English or Korean, following the Mac's language like the app.

The app passes the language it picked from the Mac's preferred languages (AIFACE_LANG) to
the server, and the server saves it in settings.json so the MCP server (started by the
chat apps) uses the same one. Without either, the Mac's preferred languages decide.
Anything not Korean is English. Python standard library only.
"""
import json
import os
import subprocess

from . import paths

SUPPORTED = ('en', 'ko')
_current = None


def _pick(code):
    code = (code or '').strip().lower().replace('_', '-')
    return 'ko' if code.startswith('ko') else 'en' if code else None


def _from_settings():
    try:
        data = json.loads(paths.SETTINGS.read_text())
        return _pick(data.get('language')) if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _from_mac():
    """First supported language in the Mac's preferred languages, else English."""
    try:
        out = subprocess.run(['defaults', 'read', '-g', 'AppleLanguages'], capture_output=True,
                             text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for item in out.replace('(', ' ').replace(')', ' ').replace('"', ' ').replace(',', ' ').split():
        if item.lower().startswith('ko'):
            return 'ko'
        if item.lower().startswith('en'):
            return 'en'
    return 'en' if out.strip() else None


def lang():
    global _current
    if _current is None:
        _current = _pick(os.environ.get('AIFACE_LANG')) or _from_settings() or _from_mac() or 'en'
    return _current


def set_lang(code):
    """Use this language from now on (tests, and the server at start)."""
    global _current
    _current = _pick(code) or 'en'
    return _current


def T(ko, en):
    """The Korean or the English text, by the current language."""
    return ko if lang() == 'ko' else en
