"""Connect AI apps to the AI Face MCP server ("ai-face"): Claude desktop and Codex.

The MCP server is one small file (core/ai_face_mcp.py) that only forwards requests to the
running app. It is copied to ~/Library/Application Support/AI Face, because macOS does not
let the chat apps start a program stored in ~/Documents. Only AI Face's own entry in each
app's settings is touched (plus the "esp32-face" entry of older versions, which is
replaced), and the settings file is backed up first. Python standard library only.
"""
import json
import re
import shutil
import time
from pathlib import Path

from . import paths
from .i18n import T

NAME = 'ai-face'
OLD_NAMES = ('esp32-face',)   # earlier versions registered under this name
PYTHON = '/usr/bin/python3'
SERVER_FILE = 'ai_face_mcp.py'
# Files of earlier versions in the data folder (the server used to be a copy of the package).
OLD_FILES = ['esp32_mcp.py', 'source.json', 'face_modes.py', 'esp_display.py', 'flasher.py',
             'photo_library.py', 'controller.html']


def runtime():
    return paths.DATA


def server_path():
    return runtime() / SERVER_FILE


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
# The server file
# ---------------------------------------------------------------------------
def install_server():
    """Copy the MCP server file next to the app's data, and remove older server files."""
    source = paths.PACKAGE.parent / SERVER_FILE
    if not source.is_file():
        raise ValueError(T('AI Face MCP 서버 파일을 찾지 못했습니다.', 'The AI Face MCP server file is missing.'))
    runtime().mkdir(parents=True, exist_ok=True)
    temp = server_path().with_name(SERVER_FILE + '.tmp')
    shutil.copyfile(source, temp)
    temp.replace(server_path())
    remove_old_files()


def remove_old_files():
    shutil.rmtree(runtime() / 'aiface', ignore_errors=True)
    for name in OLD_FILES:
        (runtime() / name).unlink(missing_ok=True)


def remove_server():
    """Server files only: settings, photos and history in the same folder are kept."""
    server_path().unlink(missing_ok=True)
    remove_old_files()


# ---------------------------------------------------------------------------
# Claude desktop: JSON, mcpServers.<name>
# ---------------------------------------------------------------------------
def _claude_entry():
    # AIFACE_AGENT tells the server which AI it serves (Claude: orange ring).
    return {'command': PYTHON, 'args': [str(server_path())], 'env': {'AIFACE_AGENT': 'claude'}}


def _claude_load():
    path = claude_config()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text() or '{}')
    except ValueError:
        raise ValueError(T(f'Claude 설정 파일 형식이 올바르지 않아 고치지 않았습니다: {path}',
                           f'The Claude settings file is not valid JSON, so it was left alone: {path}'))
    if not isinstance(data, dict):
        raise ValueError(T(f'Claude 설정 파일 형식이 올바르지 않습니다: {path}',
                           f'The Claude settings file has an unexpected format: {path}'))
    return data


def claude_status():
    """'on', 'other' (registered, but an older name or another path), 'off' or 'error'."""
    try:
        servers = _claude_load().get('mcpServers') or {}
    except (OSError, ValueError, AttributeError):
        return 'error'
    if not isinstance(servers, dict):
        return 'error'
    entry = servers.get(NAME)
    if isinstance(entry, dict):
        args = entry.get('args') or []
        return 'on' if args and args[0] == str(server_path()) else 'other'
    return 'other' if any(isinstance(servers.get(n), dict) for n in OLD_NAMES) else 'off'


def claude_install():
    data = _claude_load()
    _backup(claude_config())
    servers = data.setdefault('mcpServers', {})
    if not isinstance(servers, dict):
        raise ValueError(T('Claude 설정의 mcpServers 형식이 올바르지 않습니다.',
                           'mcpServers in the Claude settings has an unexpected format.'))
    for old in OLD_NAMES:
        servers.pop(old, None)
    servers[NAME] = _claude_entry()
    _write(claude_config(), json.dumps(data, indent=2, ensure_ascii=False))


def claude_remove():
    data = _claude_load()
    servers = data.get('mcpServers')
    names = [n for n in (NAME,) + OLD_NAMES if isinstance(servers, dict) and n in servers]
    if names:
        _backup(claude_config())
        for n in names:
            del servers[n]
        _write(claude_config(), json.dumps(data, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Codex: TOML, [mcp_servers.<name>] (edited as text: no TOML library in Python 3.9)
# ---------------------------------------------------------------------------
_ANY_HEADER = re.compile(r'^\s*\[')


def _header(names):
    alts = '|'.join(re.escape(n) for n in names)
    return re.compile(r'^\s*\[\s*mcp_servers\s*\.\s*(?:"(?:%s)"|\'(?:%s)\'|(?:%s))\s*(?:\.[^\]]*)?\]\s*$'
                      % (alts, alts, alts))


def _codex_split(text, names):
    """Lines of the file without the tables of these servers, and those tables' lines."""
    header = _header(names)
    keep, ours, inside = [], [], False
    for line in text.splitlines():
        if _ANY_HEADER.match(line):
            inside = bool(header.match(line))
        (ours if inside else keep).append(line)
    return keep, ours


def codex_available():
    return codex_config().parent.is_dir()


def _codex_text():
    path = codex_config()
    return path.read_text() if path.exists() else ''


def codex_status():
    try:
        text = _codex_text()
    except OSError:
        return 'error'
    _, ours = _codex_split(text, (NAME,))
    if ours:
        return 'on' if any(str(server_path()) in line for line in ours) else 'other'
    _, old = _codex_split(text, OLD_NAMES)
    return 'other' if old else 'off'


def codex_install():
    path = codex_config()
    keep, _ = _codex_split(_codex_text(), (NAME,) + OLD_NAMES)
    while keep and not keep[-1].strip():
        keep.pop()
    block = [f'[mcp_servers.{NAME}]',
             f'command = {json.dumps(PYTHON)}',
             f'args = [{json.dumps(str(server_path()), ensure_ascii=False)}]',
             '',
             f'[mcp_servers.{NAME}.env]',
             'AIFACE_AGENT = "gpt"']
    _backup(path)
    _write(path, '\n'.join(keep + ([''] if keep else []) + block) + '\n')


def codex_remove():
    path = codex_config()
    if not path.exists():
        return
    keep, ours = _codex_split(path.read_text(), (NAME,) + OLD_NAMES)
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
        raise ValueError(T('알 수 없는 앱입니다.', 'Unknown app.'))
    install_server()
    TARGETS[target][1]()
    return status()


def remove(target):
    if target not in TARGETS:
        raise ValueError(T('알 수 없는 앱입니다.', 'Unknown app.'))
    TARGETS[target][2]()   # the server file stays: Claude Code or other apps may still use it
    return status()


def refresh():
    """Run when the app starts: keep the installed server file current, and move apps that
    were connected by an older version (other name or path) to the current registration."""
    connected = [t for t, (st, _, _) in TARGETS.items() if st() in ('on', 'other')]
    if connected or server_path().exists():
        install_server()
    else:
        remove_old_files()
    for target in connected:
        if TARGETS[target][0]() == 'other':
            TARGETS[target][1]()
