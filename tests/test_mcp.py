"""The MCP server (core/ai_face_mcp.py): a thin bridge that only forwards to the running app."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)
sys.path.insert(0, str(ROOT / 'core'))
import ai_face_mcp as mcp  # noqa: E402
from aiface import history, server  # noqa: E402

CATALOG = [{'id': 'happy', 'name_en': 'Happy', 'name_ko': '행복', 'group_en': 'Joy', 'hint': ''},
           {'id': 'greeting', 'name_en': 'Hello', 'name_ko': '반가움', 'group_en': 'Joy', 'hint': 'hello'},
           {'id': 'thinking', 'name_en': 'Thinking', 'name_ko': '생각', 'group_en': 'Thinking & talking', 'hint': ''}]


def call(method, params=None, rid=1):
    return mcp.handle({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params or {}})


def tool(name, **args):
    return call('tools/call', {'name': name, 'arguments': args})['result']


class FakeApp:
    """Mimics the app's POST /api and GET /expression."""
    def __init__(self):
        self.calls = []
        app = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_): pass

            def send(self, code, data):
                body = json.dumps(data).encode()
                self.send_response(code); self.send_header('Content-Length', str(len(body))); self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                app.calls.append(('GET', self.path))
                self.send(200, {'text': 'Now showing: Happy'})

            def do_POST(self):
                if self.headers.get('X-ESP-Token') != 'secret':
                    return self.send(403, {'message': 'token'})
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                app.calls.append(data)
                if data['action'] == 'firmware':
                    return self.send(400, {'message': 'compile error: line 3'})
                self.send(200, {'message': 'ok'})

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown(); self.server.server_close()


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        for name in ('DISCOVERY', 'CATALOG'):
            p = patch.object(mcp, name, self.dir / (name.lower() + '.json')); p.start(); self.addCleanup(p.stop)
        mcp.CATALOG.write_text(json.dumps(CATALOG))
        p = patch.object(mcp, 'CLIENT_NAME', ''); p.start(); self.addCleanup(p.stop)

    def run_app(self):
        app = FakeApp()
        self.addCleanup(app.close)
        mcp.DISCOVERY.write_text(json.dumps({'port': app.server.server_port, 'token': 'secret'}))
        return app


class ProtocolTests(Base):
    def test_initialize_and_tools(self):
        r = call('initialize', {'protocolVersion': '2025-03-26', 'clientInfo': {'name': 't'}})['result']
        self.assertEqual(r['protocolVersion'], '2025-03-26')
        self.assertEqual(r['serverInfo']['name'], 'ai-face')
        self.assertIn('app_not_running', r['instructions'])
        self.assertEqual(call('initialize', {'protocolVersion': '1999'})['result']['protocolVersion'], mcp.PROTOCOLS[0])
        tools = {t['name']: t for t in call('tools/list')['result']['tools']}
        self.assertEqual(set(tools), {'set_expression', 'get_expression', 'show_clock', 'start_timer',
                                      'cancel_timer', 'show_photo', 'update_firmware'})
        desc = tools['set_expression']['description']
        self.assertTrue(desc.startswith('Call once per reply. Match the tone of YOUR reply'))
        self.assertTrue(desc.endswith('Notes: greeting = hello'))
        self.assertNotIn('thinking', desc)   # the ids are in the enum only
        self.assertEqual(tools['set_expression']['inputSchema']['properties']['emotion']['enum'],
                         ['happy', 'greeting', 'thinking'])
        self.assertEqual(call('ping')['result'], {})

    def test_without_catalog_any_mood_is_passed_on(self):
        mcp.CATALOG.unlink()
        schema = call('tools/list')['result']['tools'][0]
        self.assertNotIn('enum', schema['inputSchema']['properties']['emotion'])
        self.assertIn('Start the AI Face app', schema['description'])

    def test_notifications_and_errors(self):
        self.assertIsNone(mcp.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}))
        self.assertEqual(call('nope')['error']['code'], -32601)
        self.assertEqual(call('tools/call', {'name': 'set_expression', 'arguments': {}})['error']['code'], -32602)
        self.assertEqual(call('tools/call', {'name': 'zap'})['error']['code'], -32602)
        self.assertEqual(mcp.handle(['bad'])['error']['code'], -32600)
        self.run_app()
        self.assertTrue(tool('set_expression', emotion='not-a-mood')['isError'])
        self.assertTrue(tool('start_timer', minutes=0)['isError'])
        self.assertTrue(tool('start_timer', minutes=5, color='beige')['isError'])


class NotRunningTests(Base):
    def test_no_app_is_quiet_not_an_error(self):
        for name, args in [('set_expression', {'emotion': 'happy'}), ('get_expression', {}),
                           ('show_clock', {}), ('update_firmware', {})]:
            r = tool(name, **args)
            self.assertFalse(r['isError'], name)
            self.assertEqual(r['content'][0]['text'], 'app_not_running')

    def test_stale_discovery_file_too(self):
        mcp.DISCOVERY.write_text(json.dumps({'port': 1, 'token': 'x'}))   # nothing listens there
        r = tool('set_expression', emotion='happy')
        self.assertFalse(r['isError'])
        self.assertEqual(r['content'][0]['text'], 'app_not_running')


class ForwardingTests(Base):
    def test_every_tool_goes_to_the_app(self):
        app = self.run_app()
        self.assertEqual(tool('set_expression', emotion='happy')['content'][0]['text'], 'ok')
        for name, args in [('start_timer', {'minutes': 0.5, 'color': 'red'}), ('cancel_timer', {}),
                           ('show_clock', {}), ('show_photo', {})]:
            self.assertEqual(tool(name, **args)['content'][0]['text'], 'ok')
        self.assertEqual(tool('get_expression', limit=3)['content'][0]['text'], 'Now showing: Happy')
        self.assertEqual(app.calls, [
            {'action': 'emotion', 'id': 'happy', 'agent': 'gpt'},
            {'action': 'timer', 'seconds': 30, 'color': 'red'},
            {'action': 'timer', 'seconds': 0},
            {'action': 'mode', 'mode': 'CLOCK'},
            {'action': 'photo_show'},
            ('GET', '/expression?limit=3')])

    def test_app_error_is_reported(self):
        self.run_app()
        r = tool('update_firmware')
        self.assertTrue(r['isError'])
        self.assertEqual(r['content'][0]['text'], 'error: compile error: line 3')
        r = tool('set_expression', emotion='not-a-mood')
        self.assertEqual((r['isError'], r['content'][0]['text']), (True, 'error: unknown mood not-a-mood'))


class AgentTests(unittest.TestCase):
    def agent(self, env, client=''):
        with patch.dict(os.environ, env, clear=False), patch.object(mcp, 'CLIENT_NAME', client):
            for k in ('AIFACE_AGENT', 'ESP32_AGENT'):
                if k not in env:
                    os.environ.pop(k, None)
            return mcp.agent()

    def test_environment_variable_wins(self):
        self.assertEqual(self.agent({'AIFACE_AGENT': 'claude'}, 'codex-mcp-client'), 'claude')
        self.assertEqual(self.agent({'AIFACE_AGENT': 'Codex'}, 'claude-ai'), 'gpt')
        self.assertEqual(self.agent({'ESP32_AGENT': 'claude'}), 'claude')   # older registrations

    def test_client_name_fallback(self):
        self.assertEqual(self.agent({}, 'claude-ai'), 'claude')
        self.assertEqual(self.agent({}, 'codex-mcp-client'), 'gpt')


class ExpressionTextTests(unittest.TestCase):
    def test_text_has_now_recent_and_today(self):
        history.clear()
        now = time.time()
        history.record('claude', 'happy', now - 60)
        history.record('gpt', 'thinking', now - 30)
        text = server.expression_text({'name': '생각', 'owner': 'gpt', 'board': False}, 5, now)
        self.assertIn('지금 얼굴: 생각 (고른 쪽: GPT, 보드 없음)', text)
        self.assertIn('최근 2번의 변화', text)
        self.assertIn('GPT: 생각 중 (thinking)', text)
        self.assertIn('오늘 합계 2번', text)


class EndToEndTests(unittest.TestCase):
    def test_real_app_and_server_file(self):
        """The app server and the MCP server file as separate processes, in a throwaway home."""
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home, AIFACE_LANG='en', AIFACE_TEST_HOME=home)
            shim = [sys.executable, str(ROOT / 'core' / 'ai_face_mcp.py')]
            hello = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'claude-ai'}}},
                     {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
                      'params': {'name': 'set_expression', 'arguments': {'emotion': 'happy'}}}]
            stdin = ''.join(json.dumps(m) + '\n' for m in hello)

            off = subprocess.run(shim, input=stdin, env=env, capture_output=True, text=True, timeout=20)
            replies = [json.loads(line) for line in off.stdout.splitlines()]
            self.assertEqual(replies[1]['result']['content'][0]['text'], 'app_not_running')

            app = subprocess.Popen([sys.executable, str(ROOT / 'core' / 'run_server.py')], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                base = app.stdout.readline().strip()
                app.stdout.readline()
                self.assertTrue(base.startswith('http://127.0.0.1:'))
                data = Path(home) / 'Library' / 'Application Support' / 'AI Face'
                self.assertTrue((data / 'moods.json').is_file())
                on = subprocess.run(shim, input=stdin, env=env, capture_output=True, text=True, timeout=20)
                replies = [json.loads(line) for line in on.stdout.splitlines()]
                self.assertEqual(replies[1]['result']['content'][0]['text'], 'ok')
                import urllib.request
                view = json.loads(urllib.request.urlopen(base + '/view', timeout=5).read())
                self.assertEqual((view['emotion'], view['owner']), ('happy', 'claude'))
                text = json.loads(urllib.request.urlopen(base + '/expression?limit=2', timeout=5).read())['text']
                self.assertIn('Now showing: Happy (chosen by Claude', text)
            finally:
                app.terminate()
                app.wait(10)
                app.stdout.close(); app.stderr.close()


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
