#!/bin/zsh
# AI Face MCP 서버를 Claude 데스크톱에 등록합니다. 끝나면 Claude를 재시작하세요.
cd "${0:A:h}" || exit 1
exec /usr/bin/python3 tools/install_mcp.py
