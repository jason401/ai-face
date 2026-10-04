#!/bin/zsh
# Claude 데스크톱에서 AI Face MCP 등록(esp32-face)만 지웁니다. 설정과 사진은 그대로입니다.
cd "${0:A:h}" || exit 1
exec /usr/bin/python3 tools/install_mcp.py --remove
