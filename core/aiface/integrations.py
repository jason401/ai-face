"""Connect AI apps to the AI Face MCP server ("ai-face"): Claude desktop and Codex.

The MCP server is one small file (core/ai_face_mcp.py) that only forwards requests to the
running app. It is copied to ~/Library/Application Support/AI Face, because macOS does not
let the chat apps start a program stored in ~/Documents. Only AI Face's own entry in each
app's settings is touched (plus the "esp32-face" entry of older versions, which is
replaced), and the settings file is backed up first. Python standard library only.
"""
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

from . import paths
from .i18n import T

NAME = 'ai-face'
OLD_NAMES = ('esp32-face',)   # earlier versions registered under this name
PYTHON = '/usr/bin/python3'
SERVER_FILE = 'ai_face_mcp.py'
HELPER_FILE = 'ai_face_awake.py'   # keep awake: Claude Code hooks and the `awake` command
# Files of earlier versions in the data folder (the server used to be a copy of the package).
OLD_FILES = ['esp32_mcp.py', 'source.json', 'face_modes.py', 'esp_display.py', 'flasher.py',
             'photo_library.py', 'controller.html']


def runtime():
    return paths.DATA


def server_path():
    return runtime() / SERVER_FILE


def helper_path():
    return runtime() / HELPER_FILE


def claude_code_settings():
    return Path.home() / '.claude' / 'settings.json'


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
    """Copy the MCP server and the keep-awake helper next to the app's data (chat apps and
    hooks may not run programs from ~/Documents), and remove older server files."""
    runtime().mkdir(parents=True, exist_ok=True)
    for name in (SERVER_FILE, HELPER_FILE):
        source = paths.PACKAGE.parent / name
        if not source.is_file():
            raise ValueError(T(f'{name} 파일을 찾지 못했습니다.', f'{name} is missing.'))
        temp = runtime() / (name + '.tmp')
        shutil.copyfile(source, temp)
        temp.replace(runtime() / name)
    remove_old_files()


def install_helper():
    """The keep-awake helper (used by the `awake` command and the Claude Code hooks) is kept
    current on every start, whether or not an AI app is connected."""
    runtime().mkdir(parents=True, exist_ok=True)
    temp = runtime() / (HELPER_FILE + '.tmp')
    shutil.copyfile(paths.PACKAGE.parent / HELPER_FILE, temp)
    temp.replace(helper_path())


def remove_old_files():
    shutil.rmtree(runtime() / 'aiface', ignore_errors=True)
    for name in OLD_FILES:
        (runtime() / name).unlink(missing_ok=True)


def remove_server():
    """Server files only: settings, photos and history in the same folder are kept."""
    server_path().unlink(missing_ok=True)
    if hooks_status() == 'off':   # the hooks still use the helper otherwise
        helper_path().unlink(missing_ok=True)
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
# Claude Code (the terminal app): its own MCP list, changed with its official command
# `claude mcp add|remove -s user` (user scope: every folder). Its list lives in ~/.claude.json,
# which Claude Code rewrites itself, so AI Face only reads that file.
# ---------------------------------------------------------------------------
CLAUDE_CODE_DIRS = ['~/.local/bin', '~/.claude/local', '/opt/homebrew/bin', '/usr/local/bin',
                    '~/.npm-global/bin', '~/.bun/bin', '~/.volta/bin']


def _bundled_claude_code():
    """The copy of Claude Code inside the Claude app (its Code tab), newest version first.

    It lives in ~/Library/Application Support/Claude/claude-code/<version>/<id>/claude.app and
    is the same `claude` command, so people who only use the Code tab can be connected too."""
    def version(path):
        return tuple(int(n) if n.isdigit() else 0 for n in path.parents[4].name.split('.'))
    root = Path.home() / 'Library' / 'Application Support' / 'Claude' / 'claude-code'
    found = [p for p in root.glob('*/*/claude.app/Contents/MacOS/claude') if os.access(p, os.X_OK)]
    return str(max(found, key=version)) if found else None


def claude_code_cli():
    """The `claude` command, or None when Claude Code is not installed."""
    dirs = [os.path.expanduser(d) for d in CLAUDE_CODE_DIRS]
    return (shutil.which('claude', path=os.pathsep.join(dirs + os.environ.get('PATH', '').split(os.pathsep)))
            or _bundled_claude_code())


def claude_code_config():
    return Path.home() / '.claude.json'


def claude_code_status():
    try:
        text = claude_code_config().read_text() if claude_code_config().exists() else '{}'
        servers = (json.loads(text or '{}') or {}).get('mcpServers') or {}
    except (OSError, ValueError, AttributeError):
        return 'error'
    if not isinstance(servers, dict):
        return 'error'
    entry = servers.get(NAME)
    if isinstance(entry, dict):
        args = entry.get('args') or []
        return 'on' if args and args[0] == str(server_path()) else 'other'
    return 'other' if any(isinstance(servers.get(n), dict) for n in OLD_NAMES) else 'off'


def _claude_code(*args):
    cli = claude_code_cli()
    if cli is None:
        raise ValueError(T('Claude Code가 설치되어 있지 않습니다.', 'Claude Code is not installed.'))
    env = dict(os.environ, PATH=os.pathsep.join([os.path.dirname(cli), '/opt/homebrew/bin', '/usr/local/bin',
                                                  '/usr/bin', '/bin']))
    try:
        return subprocess.run([cli, 'mcp', *args], capture_output=True, text=True, timeout=15,
                              stdin=subprocess.DEVNULL, env=env, cwd=str(Path.home()))
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValueError(T(f'Claude Code 명령을 실행하지 못했습니다: {exc}', f'Could not run Claude Code: {exc}'))


def claude_code_install():
    for name in (NAME,) + OLD_NAMES:   # replace an older registration (fine if there is none)
        _claude_code('remove', '-s', 'user', name)
    p = _claude_code('add', '-s', 'user', '-e', 'AIFACE_AGENT=claude', NAME, '--', PYTHON, str(server_path()))
    if p.returncode != 0 or claude_code_status() != 'on':
        raise ValueError(T('Claude Code에 등록하지 못했습니다: ', 'Could not register with Claude Code: ')
                         + (p.stderr or p.stdout).strip()[:300])


def claude_code_remove():
    for name in (NAME,) + OLD_NAMES:
        _claude_code('remove', '-s', 'user', name)


# ---------------------------------------------------------------------------
# Claude Code hooks (~/.claude/settings.json): keep the Mac awake while Claude Code works
# ---------------------------------------------------------------------------
HOOK_EVENTS = {'UserPromptSubmit': 'on', 'PreToolUse': 'on', 'Stop': 'off', 'SessionEnd': 'off'}


def _hook_command(mode):
    return f"{PYTHON} '{helper_path()}' hook {mode}"


def _ours(group):
    return isinstance(group, dict) and any(isinstance(h, dict) and HELPER_FILE in str(h.get('command', ''))
                                           for h in group.get('hooks') or [])


def _code_load():
    path = claude_code_settings()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text() or '{}')
    except ValueError:
        raise ValueError(T(f'Claude Code 설정 파일 형식이 올바르지 않아 고치지 않았습니다: {path}',
                           f'The Claude Code settings file is not valid JSON, so it was left alone: {path}'))
    if not isinstance(data, dict) or not isinstance(data.get('hooks', {}), dict):
        raise ValueError(T(f'Claude Code 설정 파일 형식이 올바르지 않습니다: {path}',
                           f'The Claude Code settings file has an unexpected format: {path}'))
    return data


def hooks_status():
    """'on' (all our hooks, current path), 'other' (ours, but incomplete or another path), 'off', 'error'."""
    try:
        hooks = _code_load().get('hooks') or {}
    except (OSError, ValueError):
        return 'error'
    found = {e: [g for g in (hooks.get(e) or []) if _ours(g)] for e in HOOK_EVENTS}
    if not any(found.values()):
        return 'off'
    exact = all(any(h.get('command') == _hook_command(m) for g in found[e] for h in g['hooks'])
                for e, m in HOOK_EVENTS.items())
    return 'on' if exact else 'other'


def _hooks_without_ours(data):
    hooks = data.setdefault('hooks', {})
    for event in list(hooks):
        if isinstance(hooks[event], list):
            hooks[event] = [g for g in hooks[event] if not _ours(g)]
            if not hooks[event]:
                del hooks[event]
    return hooks


def hooks_install():
    data = _code_load()
    _backup(claude_code_settings())
    hooks = _hooks_without_ours(data)
    for event, mode in HOOK_EVENTS.items():
        group = {'hooks': [{'type': 'command', 'command': _hook_command(mode), 'timeout': 5}]}
        if event == 'PreToolUse':
            group['matcher'] = '*'
        hooks.setdefault(event, []).append(group)
    _write(claude_code_settings(), json.dumps(data, indent=2, ensure_ascii=False))


def hooks_remove():
    if hooks_status() == 'off' or not claude_code_settings().exists():
        return
    data = _code_load()
    _backup(claude_code_settings())
    hooks = _hooks_without_ours(data)
    if not hooks:
        del data['hooks']
    _write(claude_code_settings(), json.dumps(data, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------------------
TARGETS = {'claude': (claude_status, claude_install, claude_remove),
           'codex': (codex_status, codex_install, codex_remove),
           'claude_code': (claude_code_status, claude_code_install, claude_code_remove),
           'claude_code_awake': (hooks_status, hooks_install, hooks_remove)}


def status():
    return dict(claude=claude_status(), codex=codex_status(), codex_available=codex_available(),
                claude_code=claude_code_status(), claude_code_available=claude_code_cli() is not None,
                claude_code_awake=hooks_status(), server=str(server_path()), helper=str(helper_path()),
                python=PYTHON)


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
    install_helper()
    connected = [t for t, (st, _, _) in TARGETS.items() if st() in ('on', 'other')]
    if connected or server_path().exists():
        install_server()
    else:
        remove_old_files()
    for target in connected:
        try:   # one app failing (e.g. Claude Code's command missing) must not stop the others
            if TARGETS[target][0]() == 'other':
                TARGETS[target][1]()
        except Exception:
            pass
