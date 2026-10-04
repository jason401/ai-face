"""The controller app's local web server: the page (web/controller.html), its API, and
/view for the menu bar face. Started by the macOS app (core/run_server.py)."""
import argparse
import base64
import json
import os
import secrets
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import library as photo_library
from . import moods as face_modes
from . import paths
from .board import Device, ports


def _page():
    root = paths.project_root()
    for path in ([root / 'web' / 'controller.html'] if root else []) + [paths.PACKAGE / 'controller.html']:
        if path.is_file():
            return path.read_text()
    return '<p>controller.html을 찾지 못했습니다.</p>'


PAGE = _page()
# Lets esp32_mcp.py (the AI chat bridge) reach this app while it owns the USB port.
# Kept outside ~/Documents so the MCP server (launched by the chat app) can read it.
DISCOVERY = paths.DISCOVERY


def write_discovery(port, token):
    DISCOVERY.parent.mkdir(parents=True, exist_ok=True)
    temp = DISCOVERY.with_suffix('.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(dict(port=port, token=token, pid=os.getpid()), f)
    temp.replace(DISCOVERY)


def remove_discovery(token):
    try:
        if json.loads(DISCOVERY.read_text()).get('token') == token:
            DISCOVERY.unlink()
    except (OSError, ValueError):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()
    device = Device()
    token = secrets.token_urlsafe(32)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, data, kind='application/json'):
            if isinstance(data, bytes):   # e.g. an original from the photo library
                body = data
                self.send_response(status)
                self.send_header('Content-Type', kind)
            else:
                body = (json.dumps(data, ensure_ascii=False) if kind == 'application/json' else data).encode()
                self.send_response(status)
                self.send_header('Content-Type', kind + '; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Frame-Options', 'DENY')
            self.end_headers()
            self.wfile.write(body)

        def allowed(self):
            return self.headers.get('Host') == '127.0.0.1:' + str(self.server.server_port)

        def do_GET(self):
            if not self.allowed():
                return self.reply(403, {'error': 'Invalid host'})
            if self.path == '/':
                return self.reply(200, PAGE.replace('__TOKEN__', token), 'text/html')
            if self.path == '/emotions':
                return self.reply(200, face_modes.emotions())
            if self.path == '/modes':
                try:
                    return self.reply(200, face_modes.load())
                except (OSError, ValueError) as exc:
                    return self.reply(400, {'error': str(exc)})
            if self.path.startswith('/photo/'):
                try:   # /photo/<id>?v=<n> (the query only defeats caching)
                    data = face_modes.local_photo(int(self.path[7:].split('?')[0]))
                except ValueError:
                    data = None
                if data is None:
                    return self.reply(404, {})
                return self.reply(200, base64.b64encode(data).decode(), 'text/plain')
            if self.path == '/library':
                return self.reply(200, photo_library.listing())
            if self.path.startswith('/library/'):
                try:
                    data, kind = photo_library.read(urllib.parse.unquote(self.path[9:].split('?')[0]))
                except (OSError, ValueError):
                    return self.reply(404, {})
                return self.reply(200, data, kind)
            if self.path == '/view':   # for the menu bar face; no lock (a flash can hold it for minutes)
                return self.reply(200, device.view())
            if self.path == '/state':
                with device.lock:
                    return self.reply(200, device.state())
            self.reply(404, {})

        def do_POST(self):
            if not self.allowed() or self.headers.get('X-ESP-Token') != token:
                return self.reply(403, {'error': 'Invalid token'})
            if self.path == '/library':
                # Raw image bytes; the original file name comes URL-encoded in X-File-Name.
                try:
                    length = int(self.headers.get('Content-Length', 0))
                    if not 0 < length <= photo_library.MAX_BYTES:
                        raise ValueError('사진 파일이 비어 있거나 너무 큽니다 (최대 60MB).')
                    name = urllib.parse.unquote(self.headers.get('X-File-Name', ''))
                    stored = photo_library.add(name, self.rfile.read(length))
                    return self.reply(200, {'name': stored, 'library': photo_library.listing()})
                except (OSError, ValueError) as exc:
                    return self.reply(400, {'message': str(exc)})
            if self.path != '/api':
                return self.reply(404, {})
            with device.lock:
                status = 200
                quitting = False
                try:
                    length = int(self.headers.get('Content-Length', 0))
                    if not 0 < length <= 262144:   # a photo is ~154 KB as base64
                        raise ValueError('잘못된 요청입니다.')
                    data = json.loads(self.rfile.read(length))
                    if not isinstance(data, dict):
                        raise ValueError('잘못된 요청입니다.')
                    action = data.get('action')
                    # A board that was plugged in after the app started is picked up here.
                    if action not in ('connect', 'disconnect', 'quit', 'firmware', 'save') and device.fd is None and ports():
                        try:
                            device.connect(ports()[0])
                        except (OSError, ValueError, TimeoutError):
                            device.close()
                    if action == 'connect':
                        device.connect(data.get('port'))
                    elif action == 'emotion':
                        preset = next((m for m in face_modes.emotions() if m['id'] == data.get('id')), None)
                        if preset is None:
                            raise ValueError('감정을 선택해 주세요.')
                        # 'agent' is set by esp32_mcp.py; buttons in this app leave it out (white ring).
                        device.show_emotion(preset, data.get('agent', 'user'))
                    elif action == 'disconnect':
                        device.close()
                        device.message = 'USB 연결 해제 · 이제 Arduino 업로드가 가능합니다.'
                    elif action == 'play':
                        slot = data.get('slot')
                        if type(slot) is not int or not 0 <= slot < face_modes.SLOTS:
                            raise ValueError('저장 위치는 1~9입니다.')
                        device.exchange(f'PLAY:{slot}', 'OK PLAY')
                        device.mode = str(slot + 1)
                        device.message = f'보드의 {slot + 1}번 모드를 재생합니다.'
                    elif action == 'save':
                        face_modes.save(data.get('preset'))
                        device.message = '모드를 맥에 저장했습니다.'
                    elif action == 'upload':
                        preset = face_modes.validate(data.get('preset'))
                        device.upload(preset)
                        face_modes.save(preset)
                    elif action == 'mode':
                        device.set_mode(data.get('mode'), data.get('time'))
                    elif action == 'timer':
                        # seconds = 0 cancels; 'agent' is ignored (the ring color is the timer color).
                        device.start_timer(data.get('seconds'), data.get('color', 'blue'))
                    elif action == 'photo':
                        data_id = data.get('id')   # replace this photo (fit changed), else add
                        data = data.get('data')
                        if not isinstance(data, str):
                            raise ValueError('사진 데이터가 없습니다.')
                        device.upload_photo(base64.b64decode(data, validate=True), data_id)
                    elif action == 'photo_show':
                        device.show_photo(data.get('id'))
                    elif action == 'photo_delete':
                        device.delete_photo(data.get('id'))
                    elif action == 'firmware':
                        device.flash_firmware(data.get('port') or None)
                    elif action == 'library_delete':
                        photo_library.delete(data.get('name'))
                        device.message = '보관함에서 사진을 지웠습니다.'
                    elif action == 'library_open':
                        photo_library.open_in_finder()
                        device.message = 'Finder에서 사진 보관함을 열었습니다.'
                    elif action == 'saver':
                        device.set_saver(data.get('saver'))
                    elif action == 'quit':
                        device.close()
                        device.message = '종료되었습니다.'
                        quitting = True
                    else:
                        raise ValueError('알 수 없는 요청입니다.')
                except (OSError, ValueError, TypeError) as exc:
                    status = 400
                    if isinstance(exc, OSError):
                        device.close()
                    device.message = str(exc)
                self.reply(status, device.state())
                if quitting:
                    threading.Thread(target=self.server.shutdown, daemon=True).start()

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    url = 'http://127.0.0.1:' + str(server.server_port)
    print(url, flush=True)
    write_discovery(server.server_port, token)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        device.close()
        server.server_close()
        remove_discovery(token)


if __name__ == '__main__':
    main()
