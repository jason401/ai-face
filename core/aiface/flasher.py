"""Compile ESP32_Display.ino and upload it to the board without opening the Arduino IDE.

Uses the arduino-cli that ships inside Arduino IDE 2 (or one on PATH), with the IDE's own
configuration, so the installed ESP32 core and libraries are the same ones the IDE uses.
Python standard library only.
"""
import os
import shutil
import subprocess
import time
from pathlib import Path

# Board: Seeed XIAO ESP32S3 with the default options (USB CDC, default partition scheme
# with a "spiffs" data partition for the photos). Override with ESP32_FQBN if needed.
FQBN = os.environ.get('ESP32_FQBN', 'esp32:esp32:XIAO_ESP32S3')
from . import paths

RUNTIME = paths.DATA
BUILD = RUNTIME / 'build'          # kept between runs: later builds only recompile the sketch
CLI_CANDIDATES = [
    Path('/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'),
    Path.home() / 'Applications' / 'Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli',
]
IDE_CONFIG = Path.home() / '.arduinoIDE' / 'arduino-cli.yaml'


class FlashError(Exception):
    pass


def find_cli():
    for path in [os.environ.get('ARDUINO_CLI')] + CLI_CANDIDATES + [shutil.which('arduino-cli')]:
        if path and Path(path).is_file() and os.access(path, os.X_OK):
            return str(path)
    raise FlashError('arduino-cli를 찾지 못했습니다. Arduino IDE 2가 /Applications에 설치되어 있는지 확인해 주세요.')


def sketch_dir():
    """firmware/ESP32_Display in the AI Face project folder."""
    root = paths.project_root()
    if root is None:
        raise FlashError('펌웨어 폴더 위치를 모릅니다. AI Face 앱을 한 번 실행하거나 설정 → AI 연결에서 다시 연결해 주세요.')
    sketch = root / 'firmware' / 'ESP32_Display'
    try:
        if (sketch / 'ESP32_Display.ino').is_file():
            return sketch
    except PermissionError:
        pass
    raise FlashError(f'{sketch}/ESP32_Display.ino를 읽을 수 없습니다. '
                     'macOS가 Documents 폴더 접근을 물으면 허용해 주세요.')


def _summary(output, limit=30):
    """Compiler errors (what needs fixing) plus the end of the log, where tool and
    permission problems show up."""
    lines = [l for l in output.splitlines() if l.strip()]
    errors = [l for l in lines if 'error' in l.lower() or 'fatal' in l.lower()][:limit]
    tail = [l for l in lines[-limit:] if l not in errors]
    return '\n'.join(errors + (['--- 로그 끝부분 ---'] + tail if tail else []))


def _save_log(sketch, text):
    """Full output next to the sketch folder (firmware-build.log) and in the runtime folder."""
    for path in (sketch.parent / 'firmware-build.log', RUNTIME / 'firmware-build.log'):
        try:
            path.write_text(text)
        except OSError:
            pass


def _run(args, timeout):
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise FlashError(f'{args[1]} 시간이 초과되었습니다 ({timeout}초).')
    return done.returncode, (done.stdout or '') + (done.stderr or '')


def flash(port, progress=None):
    """Compile and upload. Returns a short report; raises FlashError with the log on failure.
    The serial port must not be open in another program (controller app, Serial Monitor)."""
    say = progress or (lambda text: None)
    cli = find_cli()
    sketch = sketch_dir()
    base = [cli, '--no-color'] + (['--config-file', str(IDE_CONFIG)] if IDE_CONFIG.is_file() else [])
    BUILD.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    say('컴파일 중… (처음에는 1~2분 걸려요)')
    args = base + ['compile', '--fqbn', FQBN, '--build-path', str(BUILD), str(sketch)]
    code, out = _run(args, 900)
    _save_log(sketch, '$ ' + ' '.join(args) + '\n' + out)
    if code != 0:
        raise FlashError('컴파일 실패:\n' + _summary(out))
    size = next((l.strip() for l in out.splitlines() if l.startswith('Sketch uses')), '')
    say('보드에 업로드 중…')
    args = base + ['upload', '-p', port, '--fqbn', FQBN, '--input-dir', str(BUILD), str(sketch)]
    code, up = _run(args, 300)
    _save_log(sketch, '$ ' + ' '.join(args) + '\n' + up)
    out = up
    if code != 0:
        hint = ''
        if 'busy' in out.lower() or 'could not open' in out.lower() or 'resource' in out.lower():
            hint = '\n(Arduino IDE의 Serial Monitor 등 다른 프로그램이 USB 포트를 쓰고 있지 않은지 확인해 주세요.)'
        raise FlashError('업로드 실패:\n' + _summary(out) + hint)
    return f'펌웨어 업로드 완료 ({time.monotonic() - started:.0f}초). {size}'.strip()
