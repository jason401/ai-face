"""core/ai_face_awake.py: the hook / `awake` helper only messages the running app."""
import io
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isolate  # noqa: E402,F401
sys.path.insert(0, str(ROOT / 'core'))
import ai_face_awake as helper  # noqa: E402


class HelperTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        p = patch.object(helper, 'DISCOVERY', Path(tmp.name) / 'controller.json'); p.start(); self.addCleanup(p.stop)
        self.calls = []
        calls = self.calls

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_): pass

            def do_POST(self):
                calls.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                body = b'{"message": "ok"}'
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
                self.wfile.write(body)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (self.server.shutdown(), self.server.server_close()))

    def app_on(self):
        helper.DISCOVERY.write_text(json.dumps({'port': self.server.server_port, 'token': 't'}))

    def test_hooks_hold_and_release_per_session(self):
        self.app_on()
        with patch('sys.stdin', io.StringIO('{"session_id": "abc", "hook_event_name": "PreToolUse"}')):
            self.assertEqual(helper.main(['hook', 'on']), 0)
        with patch('sys.stdin', io.StringIO('not json')):
            self.assertEqual(helper.main(['hook', 'off']), 0)
        self.assertEqual(self.calls, [
            {'action': 'awake_acquire', 'id': 'claude-code:abc', 'label': 'Claude Code', 'minutes': 20, 'auto': True},
            {'action': 'awake_release', 'id': 'claude-code:unknown'}])

    def test_hook_without_the_app_is_silent(self):
        with patch('sys.stdin', io.StringIO('{}')):
            self.assertEqual(helper.main(['hook', 'on']), 0)
        self.assertEqual(self.calls, [])

    def test_run_holds_a_lease_for_the_job(self):
        self.app_on()
        code = helper.main(['run', sys.executable, '-c', 'import sys; sys.exit(3)'])
        self.assertEqual(code, 3)
        acquire, release = self.calls
        self.assertEqual((acquire['action'], acquire['minutes'], release['action']), ('awake_acquire', 30, 'awake_release'))
        self.assertEqual(acquire['id'], release['id'])
        self.assertEqual(acquire['id'], f"job:{acquire['pid']}")


if __name__ == '__main__':
    unittest.main()
