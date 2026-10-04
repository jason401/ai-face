#!/usr/bin/env python3
"""Register the AI Face MCP server ("esp32-face") with Claude desktop, or remove it with
--remove. Only that entry is touched; every other setting is kept."""
import json
import shutil
import sys
import time
from pathlib import Path

PYTHON = '/usr/bin/python3'
SOURCE = Path(__file__).resolve().parents[1]          # the AI Face project folder
# macOS blocks apps from reading ~/Documents without permission, so the chat app
# could not start a server stored there. The package is copied here instead.
RUNTIME = Path.home() / 'Library' / 'Application Support' / 'ESP32Face'
PACKAGE = RUNTIME / 'aiface'
# Same file name as before the project was reorganized, so existing Claude/Codex
# registrations keep working.
SERVER = str(RUNTIME / 'esp32_mcp.py')
SHIM = """#!/usr/bin/env python3
# AI Face MCP server (installed by tools/install_mcp.py).
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from aiface.mcp_server import main
main()
"""
# Files of the ESP32-era layout, removed so they cannot shadow the package.
OLD_FILES = ['face_modes.py', 'esp_display.py', 'flasher.py', 'photo_library.py', 'controller.html']
CONFIG = Path.home() / 'Library' / 'Application Support' / 'Claude' / 'claude_desktop_config.json'
# ESP32_AGENT tells the server which AI it serves, so the LCD ring shows Claude orange.
ENTRY = {'command': PYTHON, 'args': [SERVER], 'env': {'ESP32_AGENT': 'claude'}}


def remove():
    # Only the server files: settings and the photo library in the same folder are kept.
    if PACKAGE.exists():
        shutil.rmtree(PACKAGE)
    for name in ['esp32_mcp.py', 'source.json'] + OLD_FILES:
        (RUNTIME / name).unlink(missing_ok=True)
    print('서버 파일 삭제:', RUNTIME)
    if not CONFIG.exists():
        print('Claude 설정 파일이 없습니다.')
        return 0
    try:
        data = json.loads(CONFIG.read_text() or '{}')
    except ValueError:
        print('설정 파일 형식이 올바르지 않아 수정하지 않았습니다:', CONFIG)
        return 1
    servers = data.get('mcpServers') if isinstance(data, dict) else None
    if not isinstance(servers, dict) or 'esp32-face' not in servers:
        print('esp32-face가 등록되어 있지 않습니다.')
        return 0
    backup = CONFIG.with_name(CONFIG.name + time.strftime('.backup-%Y%m%d-%H%M%S'))
    shutil.copy2(CONFIG, backup)
    del servers['esp32-face']
    temp = CONFIG.with_suffix('.tmp')
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    temp.replace(CONFIG)
    print('기존 설정 백업:', backup)
    print('\n제거 완료: esp32-face 등록을 지웠습니다. 다른 설정은 그대로입니다.')
    print('Claude 데스크톱을 완전히 종료(Cmd+Q)한 뒤 다시 실행하세요.')
    print('\n[Claude Code에 등록했었다면 터미널에서]  claude mcp remove esp32-face')
    return 0


def copy_runtime():
    RUNTIME.mkdir(parents=True, exist_ok=True)
    if PACKAGE.exists():
        shutil.rmtree(PACKAGE)
    shutil.copytree(SOURCE / 'core' / 'aiface', PACKAGE, ignore=shutil.ignore_patterns('__pycache__'))
    (RUNTIME / 'esp32_mcp.py').write_text(SHIM)
    for name in OLD_FILES:
        (RUNTIME / name).unlink(missing_ok=True)
    # Where the project lives, for the update_firmware tool (the firmware is not copied,
    # so edits in the project folder are uploaded as they are).
    (RUNTIME / 'source.json').write_text(json.dumps({'source': str(SOURCE)}, ensure_ascii=False))
    print('서버 파일 복사:', RUNTIME)


def main():
    if '--remove' in sys.argv:
        return remove()
    copy_runtime()
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    data = {}
    if CONFIG.exists():
        try:
            data = json.loads(CONFIG.read_text() or '{}')
        except ValueError:
            print('설정 파일 형식이 올바르지 않아 수정하지 않았습니다:', CONFIG)
            print('아래 내용을 mcpServers 항목에 직접 추가해 주세요.')
            print(json.dumps({'esp32-face': ENTRY}, indent=2))
            return 1
        backup = CONFIG.with_name(CONFIG.name + time.strftime('.backup-%Y%m%d-%H%M%S'))
        shutil.copy2(CONFIG, backup)
        print('기존 설정 백업:', backup)
    if not isinstance(data, dict):
        print('설정 파일 형식이 올바르지 않습니다:', CONFIG)
        return 1
    data.setdefault('mcpServers', {})['esp32-face'] = ENTRY
    temp = CONFIG.with_suffix('.tmp')
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    temp.replace(CONFIG)
    print('\n등록 완료: esp32-face →', SERVER)
    print('Claude 데스크톱을 완전히 종료(Cmd+Q)한 뒤 다시 실행하세요.')
    print('core/aiface 파이썬 코드를 수정했다면 이 설치를 다시 실행해야 반영됩니다.\n')
    print('[Claude Code에서도 쓰려면 터미널에서]')
    print(f"  claude mcp add esp32-face -e ESP32_AGENT=claude -- {PYTHON} '{SERVER}'\n")
    print('[Codex(GPT)에 등록할 때 — 테두리 초록색]')
    print(f"  codex mcp add esp32-face --env ESP32_AGENT=gpt -- {PYTHON} '{SERVER}'\n")
    print('[다른 앱(로컬 stdio MCP 지원)에 등록할 때]')
    print(f'  명령: {PYTHON}')
    print(f'  인자: {SERVER}')
    print('  환경변수: ESP32_AGENT=claude 또는 gpt (테두리 색)')
    return 0


if __name__ == '__main__':
    code = main()
    if sys.stdin.isatty():
        input('\n엔터를 누르면 창이 닫힙니다.')
    sys.exit(code)
