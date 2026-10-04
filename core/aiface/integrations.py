"""Connect AI apps to the AI Face MCP server ("esp32-face"): Claude desktop and Codex.

The server runs from a copy of this package in Application Support, because macOS does
not let the chat apps start a program stored in ~/Documents. Only the esp32-face entry of
each app's settings is touched, and the settings file is backed up first.
Python standard library only.
"""
import json
import re
import shutil
import time
from pathlib import Path

from . import paths

NAME = 'esp32-face'
PYTHON = '/usr/bin/python3'
OLD_FILES = ['face_modes.py', 'esp_display.py', 'flasher.py', 'photo_library.py', 'controller.html']
SHIM = """#!/usr/bin/env python3
# AI Face MCP server (installed by the AI Face app or tools/install_mcp.py).
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from aiface.mcp_server import main
main()
"""


def runtime():
    return paths.DATA


def server_path():
    # Same file name as in the ESP32 days, so existing registrations keep working.
    return runtime() / 'esp32_mcp.py'


def claude_config():
    return Path.home() / 'Library' / 'Application Support' / 'Claude' / 'claude_desktop_config.json'


def codex_config():
    return Path.home() / '.codex' / 'config.toml'


def _backup(path):
    if path.exists():
        backup = path.with_name(path.name + time.strftime('.backup-%Y%m%d-%H%M%S'))
        shutil.copy2(path, backup)
        return backup
    return None


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(text)
    temp.replace(path)


# ---------------------------------------------------------------------------
# The server files
# ---------------------------------------------------------------------------
def copy_runtime(source=None):
    """Copy core/aiface of the project into the runtime folder."""
    source = Path(source) if source else paths.project_root()
    package = (source / 'core' / 'aiface') if source else paths.PACKAGE
    if not (package / 'mcp_server.py').is_file():
        raise ValueError('AI Face 코드(core/aiface)를 찾지 못했습니다.')
    target = runtime() / 'aiface'
    if package.resolve() == target.resolve():
        return
    runtime().mkdir(parents=True, exist_ok=True)
    temp = runtime() / 'aiface.new'
    if temp.exists():
        shutil.rmtree(temp)
    shutil.copytree(package, temp, ignore=shutil.ignore_patterns('__pycache__'))
    if target.exists():
        shutil.rmtree(target)
    temp.rename(target)
    server_path().write_text(SHIM)
    for name in OLD_FILES:
        (runtime() / name).unlink(missing_ok=True)
    if source:
        # Where the project lives, for update_firmware (the firmware is not copied).
        paths.SOURCE_INFO.write_text(json.dumps({'source': str(source)}, ensure_ascii=False))


def refresh_runtime():
    """Keep an installed server in step with the project code (run when the app starts)."""
    if server_path().exists():
        copy_runtime()


def remove_runtime():
    """Server files only: settings and the photo library in the same folder are kept."""
    shutil.rmtree(runtime() / 'aiface', ignore_errors=True)
    for name in ['esp32_mcp.py', 'source.json'] + OLD_FILES:
        (runtime() / name).unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Claude desktop: JSON, mcpServers.<name>
# ---------------------------------------------------------------------------
def _claude_entry():
    # ESP32_AGENT tells the server which AI it serves (Claude: orange ring).
    return {'command': PYTHON, 'args': [str(server_path())], 'env': {'ESP32_AGENT': 'claude'}}


def _claude_load():
    path = claude_config()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text() or '{}')
    except ValueError:
        raise ValueError(f'Claude 설정 파일 형식이 올바르지 않아 고치지 않았습니다: {path}')
    if not isinstance(data, dict):
        raise ValueError(f'Claude 설정 파일 형식이 올바르지 않습니다: {path}')
    return data


def claude_status():
    try:
        entry = (_claude_load().get('mcpServers') or {}).get(NAME)
    except (OSError, ValueError, AttributeError):
        return 'error'
    if not isinstance(entry, dict):
        return 'off'
    args = entry.get('args') or []
    return 'on' if args and args[0] == str(server_path()) else 'other'


def claude_install():
    data = _claude_load()
    _backup(claude_config())
    servers = data.setdefault('mcpServers', {})
    if not isinstance(servers, dict):
        raise ValueError('Claude 설정의 mcpServers 형식이 올바르지 않습니다.')
    servers[NAME] = _claude_entry()
    _write(claude_config(), json.dumps(data, indent=2, ensure_ascii=False))


def claude_remove():
    data = _claude_load()
    servers = data.get('mcpServers')
    if isinstance(servers, dict) and NAME in servers:
        _backup(claude_config())
        del servers[NAME]
        _write(claude_config(), json.dumps(data, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Codex: TOML, [mcp_servers.<name>] (edited as text: no TOML library in Python 3.9)
# ---------------------------------------------------------------------------
_HEADER = re.compile(r'^\s*\[\s*mcp_servers\s*\.\s*(?:"esp32-face"|\'esp32-face\'|esp32-face)\s*(?:\.[^\]]*)?\]\s*$')
_ANY_HEADER = re.compile(r'^\s*\[')


def _codex_split(text):
    """Lines of the file without the esp32-face tables, and those tables' lines."""
    keep, ours, inside = [], [], False
    for line in text.splitlines():
        if _ANY_HEADER.match(line):
            inside = bool(_HEADER.match(line))
        (ours if inside else keep).append(line)
    return keep, ours


def codex_available():
    return codex_config().parent.is_dir()


def codex_status():
    path = codex_config()
    try:
        text = path.read_text() if path.exists() else ''
    except OSError:
        return 'error'
    _, ours = _codex_split(text)
    if not ours:
        return 'off'
    return 'on' if any(str(server_path()) in line for line in ours) else 'other'


def codex_install():
    path = codex_config()
    text = path.read_text() if path.exists() else ''
    keep, _ = _codex_split(text)
    while keep and not keep[-1].strip():
        keep.pop()
    block = [f'[mcp_servers.{NAME}]',
             f'command = {json.dumps(PYTHON)}',
             f'args = [{json.dumps(str(server_path()), ensure_ascii=False)}]',
             '',
             f'[mcp_servers.{NAME}.env]',
             'ESP32_AGENT = "gpt"']
    _backup(path)
    _write(path, '\n'.join(keep + ([''] if keep else []) + block) + '\n')


def codex_remove():
    path = codex_config()
    if not path.exists():
        return
    keep, ours = _codex_split(path.read_text())
    if ours:
        _backup(path)
        while keep and not keep[-1].strip():
            keep.pop()
        _write(path, '\n'.join(keep) + '\n' if keep else '')


# ---------------------------------------------------------------------------
TARGETS = {'claude': (claude_status, claude_install, claude_remove),
           'codex': (codex_status, codex_install, codex_remove)}


def status():
    return dict(claude=claude_status(), codex=codex_status(), codex_available=codex_available(),
                server=str(server_path()), python=PYTHON)


def install(target):
    if target not in TARGETS:
        raise ValueError('알 수 없는 앱입니다.')
    copy_runtime()
    TARGETS[target][1]()
    return status()


def remove(target):
    if target not in TARGETS:
        raise ValueError('알 수 없는 앱입니다.')
    TARGETS[target][2]()   # server files stay: Claude Code or other apps may still use them
    return status()
