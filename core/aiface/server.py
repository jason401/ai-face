"""AI Face's local server: the API behind the menu bar app (face, menu, settings window)
and the MCP server. Started by the macOS app (core/run_server.py); listens on 127.0.0.1
only, and changes need the token printed on the second line of output."""
import argparse
import base64
import json
import os
import secrets
import threading
import urllib.parse
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import VERSION
from . import history
from . import i18n
from .i18n import T
from . import integrations
from . import library as photo_library
from . import moods as face_modes
from . import paths
from .board import Device, ports

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


def auto_connect(device, stop, interval=3, retry=30):
    """Connect a board as soon as it is plugged in. A board that fails (old firmware, port
    busy) is tried again only every `retry` seconds: opening the port can restart it."""
    failed = {}
    while not stop.wait(interval):
        if device.fd is not None or device.paused:
            continue
        found = ports()
        port = next((p for p in found if time.monotonic() - failed.get(p, -1e9) >= retry), None)
        if not port or not device.lock.acquire(blocking=False):
            continue   # busy (e.g. a firmware upload holds the lock)
        try:
            if device.fd is None and not device.paused:
                device.connect(port)
                failed.pop(port, None)
        except (OSError, ValueError, TimeoutError) as exc:
            device.close()
            failed[port] = time.monotonic()
            device.message = str(exc)
        finally:
            device.lock.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-browser', action='store_true')   # accepted for old launchers
    parser.parse_args()
    device = Device()
    token = secrets.token_urlsafe(32)
    history.prune()
    face_modes.save_settings(language=i18n.lang())   # the MCP server speaks the app's language
    try:
        integrations.refresh_runtime()   # an installed MCP server runs this version of the code
    except (OSError, ValueError):
        pass

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
                return self.reply(200, 'AI Face ' + VERSION, 'text/plain')
            if self.path == '/emotions':
                return self.reply(200, face_modes.emotions())
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
            if self.path == '/status':   # for the settings window; no lock either
                return self.reply(200, dict(device.status(), version=VERSION))
            if self.path.startswith('/history'):
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                day = (query.get('day') or [time.strftime('%Y-%m-%d')])[0]
                if self.path.startswith('/history/week'):
                    return self.reply(200, history.week(day))
                return self.reply(200, history.summary(day, face_modes.emotions()))
            if self.path == '/mcp':
                return self.reply(200, integrations.status())
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
                        raise ValueError(T('사진 파일이 비어 있거나 너무 큽니다 (최대 60MB).', 'The photo file is empty or too big (max 60 MB).'))
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
                        raise ValueError(T('잘못된 요청입니다.', 'Bad request.'))
                    data = json.loads(self.rfile.read(length))
                    if not isinstance(data, dict):
                        raise ValueError(T('잘못된 요청입니다.', 'Bad request.'))
                    action = data.get('action')
                    # A board that was plugged in after the app started is picked up here.
                    if action not in ('connect', 'disconnect', 'quit', 'firmware', 'mcp_install', 'mcp_remove') \
                            and device.fd is None and not device.paused and ports():
                        try:
                            device.connect(ports()[0])
                        except (OSError, ValueError, TimeoutError):
                            device.close()
                    if action == 'connect':
                        device.paused = False
                        device.connect(data.get('port') or (ports()[0] if ports() else None))
                    elif action == 'emotion':
                        preset = next((m for m in face_modes.emotions() if m['id'] == data.get('id')), None)
                        if preset is None:
                            raise ValueError(T('감정을 선택해 주세요.', 'Choose a mood.'))
                        # 'agent' is set by esp32_mcp.py; buttons in this app leave it out (white ring).
                        device.show_emotion(preset, data.get('agent', 'user'))
                    elif action == 'disconnect':
                        device.close()
                        device.paused = True   # until 'connect': lets Arduino IDE use the port
                        device.message = T('USB 연결 해제 · 이제 Arduino 업로드가 가능합니다.', 'USB released. You can upload with Arduino now.')
                    elif action == 'mode':
                        device.set_mode(data.get('mode'), data.get('time'))
                    elif action == 'timer':
                        # seconds = 0 cancels; 'agent' is ignored (the ring color is the timer color).
                        device.start_timer(data.get('seconds'), data.get('color', 'blue'))
                    elif action == 'photo':
                        data_id = data.get('id')   # replace this photo (fit changed), else add
                        data = data.get('data')
                        if not isinstance(data, str):
                            raise ValueError(T('사진 데이터가 없습니다.', 'No photo data.'))
                        device.upload_photo(base64.b64decode(data, validate=True), data_id)
                    elif action == 'photo_show':
                        device.show_photo(data.get('id'))
                    elif action == 'photo_delete':
                        device.delete_photo(data.get('id'))
                    elif action == 'firmware':
                        device.flash_firmware(data.get('port') or None)
                    elif action == 'history_clear':
                        n = history.clear()
                        device.message = T(f'기록 {n}개를 지웠습니다.', f'Deleted {n} history entries.')
                    elif action == 'library_delete':
                        photo_library.delete(data.get('name'))
                        device.message = T('보관함에서 사진을 지웠습니다.', 'Removed from the photo library.')
                    elif action == 'library_open':
                        photo_library.open_in_finder()
                        device.message = T('Finder에서 사진 보관함을 열었습니다.', 'Opened the photo library in Finder.')
                    elif action == 'saver':
                        device.set_saver(data.get('saver'))
                    elif action == 'style':
                        device.set_style(data.get('mono'))
                    elif action == 'mcp_install':
                        integrations.install(data.get('target'))
                        device.message = T('연결했습니다. 그 앱을 완전히 종료(Cmd+Q)한 뒤 다시 실행하세요.', 'Connected. Quit that app completely (Cmd+Q) and open it again.')
                    elif action == 'mcp_remove':
                        integrations.remove(data.get('target'))
                        device.message = T('연결을 해제했습니다. 그 앱을 다시 실행하면 반영됩니다.', 'Disconnected. It takes effect when that app restarts.')
                    elif action == 'quit':
                        device.close()
                        device.message = T('종료되었습니다.', 'Stopped.')
                        quitting = True
                    else:
                        raise ValueError(T('알 수 없는 요청입니다.', 'Unknown request.'))
                except (OSError, ValueError, TypeError) as exc:
                    status = 400
                    if isinstance(exc, OSError):
                        device.close()
                    device.message = str(exc)
                self.reply(status, device.state())
                if quitting:
                    threading.Thread(target=self.server.shutdown, daemon=True).start()

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print('http://127.0.0.1:' + str(server.server_port), flush=True)
    print(token, flush=True)   # read by the menu bar app (POST requests need it)
    write_discovery(server.server_port, token)
    stop = threading.Event()
    threading.Thread(target=auto_connect, args=(device, stop), daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        with device.lock:
            device.close()
        server.server_close()
        remove_discovery(token)


if __name__ == '__main__':
    main()
