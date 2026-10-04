# AI Face

Claude나 GPT와 대화하면 AI가 고른 표정이 **맥 메뉴바의 동그란 얼굴**에 나타나는 앱입니다.
ESP32 + 원형 LCD를 연결하면 같은 얼굴이 실물 화면에도 나옵니다(선택).

- 63가지 감정 표정, 누가 바꿨는지 테두리 색(Claude 주황 / GPT 초록 / 직접 흰색)
- 대기 화면: 졸림→잠, 시계, 사진, 슬라이드쇼, 픽셀 모닥불
- 타이머 링, 사진 보관함, 보드 펌웨어 자동 업데이트(Arduino IDE 창 없이)

## 설치

1. `앱 빌드.command` 더블클릭 → `AI Face.app`이 빌드되고 실행됩니다(메뉴바에 얼굴).
2. `MCP 설치.command` 더블클릭 → Claude 데스크톱 / Codex에 MCP 서버 `esp32-face` 등록.
3. Claude 데스크톱을 Cmd+Q로 종료 후 다시 실행.

자세한 사용법은 [docs/사용방법.md](docs/사용방법.md).

## 구조

```
app/macos/main.m        메뉴바 앱 (Objective-C, 서버 실행 + 메뉴바 얼굴)
core/aiface/            파이썬 코어 (표준 라이브러리만 사용)
  server.py             로컬 컨트롤러 서버 (127.0.0.1 임의 포트 + 토큰)
  mcp_server.py         MCP stdio 서버 (set_expression, start_timer, ...)
  board.py              ESP32 USB 시리얼 통신
  moods.py              표정 데이터 / 대기 설정
  library.py            사진 보관함
  flasher.py            arduino-cli로 펌웨어 컴파일·업로드
  paths.py              데이터 폴더 위치
core/run_server.py      앱이 실행하는 진입점
web/controller.html     컨트롤러 화면
firmware/ESP32_Display/ ESP32 펌웨어 (XIAO ESP32S3 + GC9A01, 프로토콜 FACE7)
hardware/housing/       3D 프린트 케이스
tools/                  앱 빌드, MCP 설치, 펌웨어 시뮬레이터
tests/                  테스트
```

데이터: `~/Library/Application Support/ESP32Face/` (설정, 사진 보관함, MCP 런타임 사본, 빌드 캐시)

## 개발

```
python3 -m unittest discover -s tests     # 파이썬 + 펌웨어 시뮬레이터 테스트
bash tools/firmware_sim/run.sh             # 펌웨어 시뮬레이터만
```

- 코드를 고친 뒤: 앱 쪽은 `앱 빌드.command`, MCP 쪽은 `MCP 설치.command`를 다시 실행.
- 펌웨어(.ino)에서 함수 시그니처에 쓰는 struct는 `RingColorFn` typedef보다 위에 선언해야 합니다(Arduino 프로토타입 삽입 위치). 시뮬레이터가 같은 규칙을 따릅니다.
