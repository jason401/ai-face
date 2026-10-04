import json
import os
import pty
import subprocess
import sys
import tempfile
import threading
import tty
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'core'))
from aiface import mcp_server as esp32_mcp  # noqa: E402
from aiface import board as esp_display  # noqa: E402
from aiface import server  # noqa: E402


def call(method, params=None, rid=1):
    return esp32_mcp.handle({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params or {}})


class ProtocolTests(unittest.TestCase):
    def test_initialize_and_tools(self):
        r = call('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 't'}})['result']
        self.assertEqual(r['protocolVersion'], '2025-03-26')
        self.assertIn('tools', r['capabilities'])
        self.assertIn('set_expression', r['instructions'])
        unknown = call('initialize', {'protocolVersion': '1999-01-01'})['result']
        self.assertEqual(unknown['protocolVersion'], esp32_mcp.PROTOCOLS[0])
        tools = {t['name']: t for t in call('tools/list')['result']['tools']}
        self.assertEqual(set(tools), {'set_expression', 'show_clock', 'start_timer', 'cancel_timer', 'show_photo',
                                      'update_firmware'})
        self.assertIn('red', tools['start_timer']['inputSchema']['properties']['color']['enum'])
        enum = tools['set_expression']['inputSchema']['properties']['emotion']['enum']
        self.assertEqual(len(enum), 64)
        self.assertIn('triumph', enum)
        self.assertEqual(call('ping')['result'], {})

    def test_notifications_and_errors(self):
        self.assertIsNone(esp32_mcp.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}))
        self.assertEqual(call('nope')['error']['code'], -32601)
        self.assertEqual(call('tools/call', {'name': 'set_expression', 'arguments': {}})['error']['code'], -32602)
        self.assertEqual(esp32_mcp.handle(['bad'])['error']['code'], -32600)
        r = call('tools/call', {'name': 'set_expression', 'arguments': {'emotion': 'not-a-mood'}})['result']
        self.assertTrue(r['isError'])

    def test_stdio_end_to_end_without_board(self):
        lines = [
            {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
            {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'set_expression', 'arguments': {'emotion': 'happy'}}},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            # Install into a throwaway home (no running app, no Claude config) and run the
            # installed server exactly as Claude would.
            env = dict(os.environ, HOME=tmp)
            install = subprocess.run([sys.executable, str(ROOT / 'tools' / 'install_mcp.py')], env=env,
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(install.returncode, 0, install.stdout + install.stderr)
            runtime = Path(tmp) / 'Library' / 'Application Support' / 'ESP32Face'
            config = json.loads((Path(tmp) / 'Library' / 'Application Support' / 'Claude' / 'claude_desktop_config.json').read_text())
            self.assertEqual(config['mcpServers']['esp32-face']['args'], [str(runtime / 'esp32_mcp.py')])
            self.assertTrue((runtime / 'aiface' / 'mcp_server.py').is_file())
            self.assertEqual(json.loads((runtime / 'source.json').read_text())['source'], str(ROOT))
            proc = subprocess.run([sys.executable, str(runtime / 'esp32_mcp.py')], env=env,
                                  input='\n'.join(json.dumps(l) for l in lines) + '\nnot json\n',
                                  capture_output=True, text=True, timeout=30)
            # Removing the server keeps settings and photos in the same folder.
            (runtime / 'settings.json').write_text('{}')
            subprocess.run([sys.executable, str(ROOT / 'tools' / 'install_mcp.py'), '--remove'], env=env,
                           capture_output=True, text=True, timeout=30)
            self.assertFalse((runtime / 'aiface').exists())
            self.assertTrue((runtime / 'settings.json').exists())
        out = [json.loads(l) for l in proc.stdout.splitlines()]
        self.assertEqual([o.get('id') for o in out], [1, 2, 3, None])
        self.assertTrue(out[2]['result']['isError'])  # no ESP32 attached in the test environment
        self.assertEqual(out[3]['error']['code'], -32700)


class FakeApp:
    """Mimics the controller app's /state and /api endpoints."""
    def __init__(self, connected=True):
        self.calls = []
        self.state = dict(ports=['/dev/cu.usbmodem1'], connected=connected, port='', mode='', emotion='', message='')
        app = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_): pass

            def send(self, code, data):
                body = json.dumps(data).encode()
                self.send_response(code); self.send_header('Content-Length', str(len(body))); self.end_headers()
                self.wfile.write(body)

            def ok(self):
                return (self.headers.get('Host') == f'127.0.0.1:{self.server.server_port}'
                        and self.headers.get('X-ESP-Token') == 'secret')

            def do_GET(self):
                self.send(200 if self.ok() else 403, app.state)

            def do_POST(self):
                if not self.ok():
                    return self.send(403, {'message': 'token'})
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                app.calls.append(data)
                if data['action'] == 'connect':
                    app.state['connected'] = True
                elif data['action'] == 'emotion':
                    app.state['emotion'] = data['id']   # works without a board (menu bar)
                elif data['action'] == 'mode' and not app.state['ports']:
                    return self.send(400, dict(app.state, message='보드 오류'))
                self.send(200, dict(app.state, message='ok'))

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown(); self.server.server_close()


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.discovery = Path(self.tmp.name) / '.controller.json'
        p = patch.object(esp32_mcp, 'DISCOVERY', self.discovery); p.start(); self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def test_forwards_to_running_app(self):
        app = FakeApp(connected=False); self.addCleanup(app.close)
        self.discovery.write_text(json.dumps({'port': app.server.server_port, 'token': 'secret'}))
        with patch.object(esp32_mcp, '_direct', side_effect=AssertionError('should not open USB')):
            r = call('tools/call', {'name': 'set_expression', 'arguments': {'emotion': 'love'}})['result']
        self.assertFalse(r['isError'], r)
        self.assertEqual([c['action'] for c in app.calls], ['emotion'])   # the app connects by itself
        self.assertIn(app.calls[0]['agent'], ('claude', 'gpt'))
        self.assertEqual(app.state['emotion'], 'love')

    def test_app_error_is_reported(self):
        app = FakeApp(); self.addCleanup(app.close)
        app.state['ports'] = []; app.state['connected'] = False
        self.discovery.write_text(json.dumps({'port': app.server.server_port, 'token': 'secret'}))
        r = call('tools/call', {'name': 'show_clock', 'arguments': {}})['result']
        self.assertTrue(r['isError'])
        self.assertIn('보드 오류', r['content'][0]['text'])   # the app's own error is passed on

    def test_stale_discovery_falls_back_to_usb(self):
        app = FakeApp(); port = app.server.server_port; app.close()   # app no longer running
        self.discovery.write_text(json.dumps({'port': port, 'token': 'secret'}))
        used = []
        with patch.object(esp32_mcp, '_direct', side_effect=lambda action: used.append(action) or 'ok'):
            r = call('tools/call', {'name': 'set_expression', 'arguments': {'emotion': 'happy'}})['result']
        self.assertFalse(r['isError'])
        self.assertEqual(len(used), 1)

    def test_direct_usb_upload_and_release(self):
        master, slave = pty.openpty(); tty.setraw(slave)
        name = os.ttyname(slave)
        from aiface import moods as face_modes
        sleepy, sleeping = face_modes.idle_moods()
        replies = {'HELLO': 'OK FACE7', 'BEGIN': 'OK BEGIN', 'FRAME': 'OK FRAME', 'COMMIT': 'OK COMMIT',
                   'PLAY': 'OK PLAY', 'OWNER': 'OK OWNER', 'TIME': 'OK TIME', 'SAVER': 'OK SAVER', 'PHOTO:LIST': 'OK LIST:0:-1',
                   # sleepy already on the board, sleeping not yet
                   'SUM:3': f'OK SUM:{face_modes.checksum(sleepy)}', 'SUM:8': 'OK SUM:0'}
        seen = []

        def board():
            buf = b''
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
                while b'\n' in buf:
                    line, buf = buf.split(b'\n', 1)
                    text = line.decode(); seen.append(text)
                    key = text if text.startswith('SUM:') or text.startswith('PHOTO:') else text.split(':')[0]
                    os.write(master, (replies[key] + '\r\n').encode())
                    if key == 'OWNER':
                        return

        worker = threading.Thread(target=board, daemon=True); worker.start()
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        with patch.object(esp_display, 'ports', return_value=[name]), patch.object(esp_display.time, 'sleep'), \
                patch.dict(os.environ, {'ESP32_AGENT': 'gpt'}), \
                patch.object(face_modes, 'SETTINGS', Path(tmp.name) / 'settings.json'):
            r = call('tools/call', {'name': 'set_expression', 'arguments': {'emotion': 'thinking'}})['result']
        worker.join(2); os.close(master); os.close(slave)
        self.assertFalse(r['isError'], r)
        self.assertEqual(seen[0], 'HELLO')
        self.assertEqual(seen[-2], 'PLAY:7')
        self.assertEqual(seen[-1], 'OWNER:2')  # GPT ring, sent after the face starts
        frames = esp32_mcp.BY_ID['thinking']['frames']
        self.assertEqual(sum(s.startswith('FRAME:') for s in seen), len(frames) + len(sleeping['frames']))
        self.assertIn('SAVER:600:0:0:60', seen)
        self.assertEqual([s for s in seen if s.startswith('BEGIN')][0], f"BEGIN:8:{len(sleeping['frames'])}")


class AgentTests(unittest.TestCase):
    def setUp(self):
        p = patch.object(esp32_mcp, 'CLIENT_NAME', ''); p.start(); self.addCleanup(p.stop)

    def detect(self, client, env=None):
        environ = {k: v for k, v in os.environ.items() if k != 'ESP32_AGENT'}
        if env is not None:
            environ['ESP32_AGENT'] = env
        with patch.dict(os.environ, environ, clear=True):
            call('initialize', {'protocolVersion': '2025-06-18', 'clientInfo': {'name': client}})
            return esp32_mcp.agent()

    def test_environment_variable_wins(self):
        self.assertEqual(self.detect('claude-ai', 'gpt'), 'gpt')
        self.assertEqual(self.detect('codex-mcp-client', 'Claude'), 'claude')
        self.assertEqual(self.detect('whatever', 'codex'), 'gpt')

    def test_client_name_fallback(self):
        self.assertEqual(self.detect('claude-ai'), 'claude')
        self.assertEqual(self.detect('claude-code'), 'claude')
        self.assertEqual(self.detect('codex-mcp-client'), 'gpt')
        self.assertEqual(self.detect('openai-mcp'), 'gpt')

    def test_agent_is_forwarded_to_app(self):
        app = FakeApp(); self.addCleanup(app.close)
        with tempfile.TemporaryDirectory() as tmp:
            discovery = Path(tmp) / 'c.json'
            discovery.write_text(json.dumps({'port': app.server.server_port, 'token': 'secret'}))
            with patch.object(esp32_mcp, 'DISCOVERY', discovery), patch.dict(os.environ, {'ESP32_AGENT': 'claude'}):
                r = call('tools/call', {'name': 'set_expression', 'arguments': {'emotion': 'happy'}})['result']
        self.assertFalse(r['isError'], r)
        self.assertEqual(app.calls[-1], {'action': 'emotion', 'id': 'happy', 'agent': 'claude'})


class TimerToolTests(unittest.TestCase):
    def test_timer_tools_are_forwarded_to_app(self):
        app = FakeApp(); self.addCleanup(app.close)
        with tempfile.TemporaryDirectory() as tmp:
            discovery = Path(tmp) / 'c.json'
            discovery.write_text(json.dumps({'port': app.server.server_port, 'token': 'secret'}))
            with patch.object(esp32_mcp, 'DISCOVERY', discovery):
                r = call('tools/call', {'name': 'start_timer', 'arguments': {'minutes': 25, 'color': 'red'}})['result']
                self.assertFalse(r['isError'], r); self.assertIn('25분', r['content'][0]['text'])
                r = call('tools/call', {'name': 'start_timer', 'arguments': {'minutes': 0.5}})['result']
                self.assertFalse(r['isError'], r)
                r = call('tools/call', {'name': 'cancel_timer', 'arguments': {}})['result']
                self.assertFalse(r['isError'], r)
        self.assertEqual(app.calls, [{'action': 'timer', 'seconds': 1500, 'color': 'red'},
                                     {'action': 'timer', 'seconds': 30, 'color': 'blue'},
                                     {'action': 'timer', 'seconds': 0}])

    def test_show_photo_is_forwarded(self):
        app = FakeApp(); self.addCleanup(app.close)
        with tempfile.TemporaryDirectory() as tmp:
            discovery = Path(tmp) / 'c.json'
            discovery.write_text(json.dumps({'port': app.server.server_port, 'token': 'secret'}))
            with patch.object(esp32_mcp, 'DISCOVERY', discovery):
                r = call('tools/call', {'name': 'show_photo', 'arguments': {}})['result']
        self.assertFalse(r['isError'], r)
        self.assertEqual(app.calls[-1], {'action': 'photo_show'})

    def test_update_firmware_goes_through_app(self):
        app = FakeApp(); self.addCleanup(app.close)
        with tempfile.TemporaryDirectory() as tmp:
            discovery = Path(tmp) / 'c.json'
            discovery.write_text(json.dumps({'port': app.server.server_port, 'token': 'secret'}))
            with patch.object(esp32_mcp, 'DISCOVERY', discovery):
                r = call('tools/call', {'name': 'update_firmware', 'arguments': {}})['result']
        self.assertFalse(r['isError'], r)
        self.assertEqual(app.calls[-1], {'action': 'firmware'})

    def test_bad_timer_arguments(self):
        for args in ({'minutes': 0}, {'minutes': 2000}, {'minutes': '5'}, {'minutes': True}, {'minutes': 5, 'color': 'navy'}):
            with self.subTest(args=args), patch.object(esp32_mcp, 'deliver', side_effect=AssertionError('not sent')):
                r = call('tools/call', {'name': 'start_timer', 'arguments': args})['result']
                self.assertTrue(r['isError'])


class DiscoveryFileTests(unittest.TestCase):
    def test_write_and_remove_only_own_file(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(server, 'DISCOVERY', Path(tmp) / '.controller.json'):
            server.write_discovery(1234, 'abc')
            self.assertEqual(json.loads(server.DISCOVERY.read_text())['port'], 1234)
            self.assertEqual(server.DISCOVERY.stat().st_mode & 0o777, 0o600)
            server.remove_discovery('other')
            self.assertTrue(server.DISCOVERY.exists())
            server.remove_discovery('abc')
            self.assertFalse(server.DISCOVERY.exists())


if __name__ == '__main__':
    unittest.main()
