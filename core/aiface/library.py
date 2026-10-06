"""Photo library: originals of every picture dropped into the controller app, kept in
~/Library/Application Support/AI Face/Photo Library so they can be sent to the board again
later. Pictures copied into that folder in Finder show up too. Python standard library only.
"""
import hashlib
import shutil
import mimetypes
import os
import subprocess
import unicodedata

from . import paths
from .i18n import T

FOLDER = paths.LIBRARY
LEGACY = paths.LEGACY_PROJECT / '사진 보관함'   # where the ESP32-era app kept them
EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.heif', '.bmp', '.tif', '.tiff'}
MAX_BYTES = 60 * 1024 * 1024
mimetypes.add_type('image/heic', '.heic')
mimetypes.add_type('image/heif', '.heif')
mimetypes.add_type('image/webp', '.webp')


def _norm(name):
    # macOS file names come back decomposed (NFD); compare in composed form.
    return unicodedata.normalize('NFC', name)


def is_image(path):
    return path.is_file() and path.suffix.lower() in EXTENSIONS and not path.name.startswith('.')


def migrate():
    """First run after the move: copy pictures from the old project folder (once)."""
    if FOLDER.exists():
        return
    try:
        if paths.LIBRARY_KO.is_dir():   # renamed from the Korean-only versions
            paths.LIBRARY_KO.rename(FOLDER)
            return
    except OSError:
        pass
    try:
        old = [p for p in LEGACY.iterdir() if is_image(p)]
    except OSError:
        return
    FOLDER.mkdir(parents=True, exist_ok=True)
    for p in old:
        try:
            shutil.copy2(p, FOLDER / p.name)
        except OSError:
            pass


def listing():
    """Newest first: [{'name', 'size', 'mtime'}]."""
    migrate()
    try:
        files = [p for p in FOLDER.iterdir() if is_image(p)]
    except OSError:
        return []
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return [dict(name=_norm(p.name), size=p.stat().st_size, mtime=int(p.stat().st_mtime)) for p in files]


def path_of(name):
    """The file for a listed name, or ValueError (no paths outside the folder)."""
    if not isinstance(name, str) or not name or '/' in name or '\\' in name or name.startswith('.'):
        raise ValueError(T('사진 이름이 올바르지 않습니다.', 'Invalid photo name.'))
    try:
        for p in FOLDER.iterdir():
            if _norm(p.name) == _norm(name) and is_image(p):
                return p
    except OSError:
        pass
    raise ValueError(T('보관함에 그 사진이 없습니다.', 'That photo is not in the library.'))


def read(name):
    p = path_of(name)
    return p.read_bytes(), mimetypes.guess_type(p.name)[0] or 'application/octet-stream'


def _clean_name(name):
    name = _norm(os.path.basename(str(name or '')).strip()) or 'photo.jpg'
    name = ''.join(c for c in name if c not in '/\\:\0' and ord(c) >= 32).lstrip('.') or 'photo.jpg'
    stem, ext = os.path.splitext(name)
    if ext.lower() not in EXTENSIONS:
        ext = '.jpg'
    return stem[:80] or 'photo', ext


def add(name, data):
    """Save an original. The same picture again is not duplicated; a different picture
    with a taken name gets ' (2)', ' (3)', ... Returns the stored name."""
    if not data or len(data) > MAX_BYTES:
        raise ValueError(T('사진 파일이 비어 있거나 너무 큽니다 (최대 60MB).', 'The photo file is empty or too big (max 60 MB).'))
    FOLDER.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha1(data).hexdigest()
    for p in FOLDER.iterdir():
        if is_image(p) and p.stat().st_size == len(data) and hashlib.sha1(p.read_bytes()).hexdigest() == digest:
            os.utime(p)   # move it to the top of the list
            return _norm(p.name)
    stem, ext = _clean_name(name)
    n = 1
    while True:
        target = FOLDER / (f'{stem}{ext}' if n == 1 else f'{stem} ({n}){ext}')
        try:
            with open(target, 'xb') as f:   # never overwrite
                f.write(data)
            return _norm(target.name)
        except FileExistsError:
            n += 1


def delete(name):
    path_of(name).unlink()


def open_in_finder():
    FOLDER.mkdir(parents=True, exist_ok=True)
    subprocess.run(['open', str(FOLDER)], check=False)
