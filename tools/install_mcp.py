#!/usr/bin/env python3
"""Register the AI Face MCP server ("esp32-face") with Claude desktop (and Codex, when it
is installed), or remove it with --remove. The app's 설정 → AI 연결 does the same."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'core'))
from aiface import integrations  # noqa: E402
from aiface.i18n import T  # noqa: E402


def main():
    try:
        if '--remove' in sys.argv:
            for target in integrations.TARGETS:
                integrations.TARGETS[target][2]()
            integrations.remove_runtime()
            print(T('제거 완료: esp32-face 등록과 서버 파일을 지웠습니다. 설정과 사진 보관함은 그대로입니다.',
                    'Removed: the esp32-face registrations and server files. Settings and photos are kept.'))
            print(T('Claude 데스크톱을 완전히 종료(Cmd+Q)한 뒤 다시 실행하세요.', 'Quit Claude desktop (Cmd+Q) and open it again.'))
            print(T('\n[Claude Code에 등록했었다면 터미널에서]', '\n[If you added it to Claude Code, in a terminal]') + '  claude mcp remove esp32-face')
            return 0
        integrations.copy_runtime(ROOT)
        integrations.claude_install()
        print(T('Claude 데스크톱 등록 완료:', 'Connected to Claude desktop:'), integrations.server_path())
        if integrations.codex_available():
            integrations.codex_install()
            print(T('Codex 등록 완료 (테두리 초록색)', 'Connected to Codex (green ring)'))
    except (OSError, ValueError) as exc:
        print(T('실패:', 'Failed:'), exc)
        return 1
    server = integrations.server_path()
    print(T('\nClaude 데스크톱(과 Codex)을 완전히 종료(Cmd+Q)한 뒤 다시 실행하세요.', '\nQuit Claude desktop (and Codex) with Cmd+Q and open them again.'))
    print(T('\n[Claude Code에서도 쓰려면 터미널에서]', '\n[For Claude Code, in a terminal]'))
    print(f"  claude mcp add esp32-face -e ESP32_AGENT=claude -- {integrations.PYTHON} '{server}'")
    return 0


if __name__ == '__main__':
    code = main()
    if sys.stdin.isatty():
        input(T('\n엔터를 누르면 창이 닫힙니다.', '\nPress Return to close.'))
    sys.exit(code)
