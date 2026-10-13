import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)
sys.path.insert(0, str(ROOT / 'core'))
from aiface import integrations, paths, server  # noqa: E402


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        home = Path(self.tmp.name)
        data = home / 'Library' / 'Application Support' / 'AI Face'
        for p in [patch.object(Path, 'home', return_value=home), patch.object(paths, 'DATA', data),
                  patch.object(paths, 'LEGACY_DATA', home / 'Library' / 'Application Support' / 'ESP32Face')]:
            p.start()
            self.addCleanup(p.stop)
        self.home = home

    def tearDown(self):
        self.tmp.cleanup()

    def test_claude_keeps_other_servers(self):
        cfg = integrations.claude_config()
        cfg.parent.mkdir(parents=True)
        cfg.write_text(json.dumps({'mcpServers': {'other': {'command': 'x'}}, 'theme': 'dark'}))
        self.assertEqual(integrations.claude_status(), 'off')
        integrations.install('claude')
        data = json.loads(cfg.read_text())
        self.assertEqual(data['theme'], 'dark')
        self.assertIn('other', data['mcpServers'])
        entry = data['mcpServers']['ai-face']
        self.assertEqual(entry['env'], {'AIFACE_AGENT': 'claude'})
        self.assertEqual(entry['args'], [str(paths.DATA / 'ai_face_mcp.py')])
        self.assertEqual(integrations.claude_status(), 'on')
        # One standalone file: the same as core/ai_face_mcp.py, no copy of the package.
        self.assertEqual(integrations.server_path().read_text(), (ROOT / 'core' / 'ai_face_mcp.py').read_text())
        self.assertFalse((paths.DATA / 'aiface').exists())
        self.assertTrue(list(cfg.parent.glob('claude_desktop_config.json.backup-*')))
        integrations.remove('claude')
        self.assertEqual(json.loads(cfg.read_text())['mcpServers'], {'other': {'command': 'x'}})
        self.assertEqual(integrations.claude_status(), 'off')

    def test_claude_old_name_is_replaced(self):
        cfg = integrations.claude_config()
        cfg.parent.mkdir(parents=True)
        cfg.write_text(json.dumps({'mcpServers': {'esp32-face': {'command': 'p', 'args': ['/old/esp32_mcp.py']},
                                                  'other': {'command': 'x'}}}))
        self.assertEqual(integrations.claude_status(), 'other')
        integrations.refresh()
        servers = json.loads(cfg.read_text())['mcpServers']
        self.assertEqual(sorted(servers), ['ai-face', 'other'])
        self.assertEqual(integrations.claude_status(), 'on')

    def test_claude_bad_file(self):
        cfg = integrations.claude_config()
        cfg.parent.mkdir(parents=True)
        cfg.write_text('{broken')
        self.assertEqual(integrations.claude_status(), 'error')
        with self.assertRaises(ValueError):
            integrations.install('claude')
        self.assertEqual(cfg.read_text(), '{broken')

    def test_codex_toml(self):
        cfg = integrations.codex_config()
        cfg.parent.mkdir(parents=True)
        cfg.write_text('model = "gpt-5"\n\n[mcp_servers.esp32-face]\ncommand = "/old"\nargs = ["/old.py"]\n\n'
                       '[mcp_servers.esp32-face.env]\nESP32_AGENT = "gpt"\n\n[mcp_servers.notion]\ncommand = "n"\n')
        self.assertTrue(integrations.codex_available())
        self.assertEqual(integrations.codex_status(), 'other')
        integrations.install('codex')
        text = cfg.read_text()
        self.assertEqual(integrations.codex_status(), 'on')
        self.assertEqual(text.count('[mcp_servers.ai-face]'), 1)
        self.assertIn('[mcp_servers.ai-face.env]\nAIFACE_AGENT = "gpt"', text)
        self.assertNotIn('esp32-face', text)
        self.assertNotIn('/old', text)
        self.assertIn('model = "gpt-5"', text)
        self.assertIn('[mcp_servers.notion]\ncommand = "n"', text)
        integrations.remove('codex')
        text = cfg.read_text()
        self.assertNotIn('ai-face', text)
        self.assertIn('[mcp_servers.notion]', text)
        self.assertEqual(integrations.codex_status(), 'off')

    def test_claude_code_hooks_keep_other_hooks(self):
        cfg = integrations.claude_code_settings()
        cfg.parent.mkdir(parents=True)
        mine = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo mine'}]}
        cfg.write_text(json.dumps({'model': 'opus', 'hooks': {'PreToolUse': [mine]}}))
        self.assertEqual(integrations.hooks_status(), 'off')
        integrations.install('claude_code_awake')
        data = json.loads(cfg.read_text())
        self.assertEqual(data['model'], 'opus')
        self.assertEqual(data['hooks']['PreToolUse'][0], mine)
        self.assertEqual(set(data['hooks']), {'UserPromptSubmit', 'PreToolUse', 'Stop', 'SessionEnd'})
        self.assertIn("ai_face_awake.py' hook off", data['hooks']['Stop'][0]['hooks'][0]['command'])
        self.assertEqual(integrations.hooks_status(), 'on')
        self.assertTrue(integrations.helper_path().is_file())
        integrations.install('claude_code_awake')          # again: no duplicates
        self.assertEqual(len(json.loads(cfg.read_text())['hooks']['Stop']), 1)
        integrations.remove('claude_code_awake')
        self.assertEqual(json.loads(cfg.read_text()), {'model': 'opus', 'hooks': {'PreToolUse': [mine]}})
        self.assertEqual(integrations.hooks_status(), 'off')

    def test_status_and_unknown(self):
        s = integrations.status()
        self.assertEqual((s['claude'], s['codex'], s['codex_available']), ('off', 'off', False))
        with self.assertRaises(ValueError):
            integrations.install('word')

    def test_data_folder_migrates_and_old_files_go(self):
        old = paths.LEGACY_DATA
        (old / 'aiface').mkdir(parents=True)
        (old / 'aiface' / 'mcp_server.py').write_text('old')
        (old / 'esp32_mcp.py').write_text('old')
        (old / 'settings.json').write_text('{"saver": "clock"}')
        (old / 'Photo Library').mkdir()
        (old / 'Photo Library' / 'a.jpg').write_bytes(b'jpg')
        self.assertTrue(paths.migrate_data())
        self.assertFalse(old.exists())
        self.assertFalse(paths.migrate_data())   # only once
        integrations.refresh()   # nothing registered: old server files are still cleaned up
        self.assertEqual((paths.DATA / 'settings.json').read_text(), '{"saver": "clock"}')
        self.assertTrue((paths.DATA / 'Photo Library' / 'a.jpg').is_file())
        self.assertFalse((paths.DATA / 'aiface').exists())
        self.assertFalse((paths.DATA / 'esp32_mcp.py').exists())
        self.assertFalse(integrations.server_path().exists())

    def test_existing_new_folder_is_not_replaced(self):
        paths.LEGACY_DATA.mkdir(parents=True)
        paths.DATA.mkdir(parents=True)
        self.assertFalse(paths.migrate_data())
        self.assertTrue(paths.LEGACY_DATA.exists())


FAKE_CLAUDE = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
cfg = Path(os.environ['FAKE_HOME']) / '.claude.json'
data = json.loads(cfg.read_text()) if cfg.exists() else {}
servers = data.setdefault('mcpServers', {})
a = sys.argv[1:]
with open(Path(os.environ['FAKE_HOME']) / 'calls.log', 'a') as log:
    log.write(' '.join(a) + '\n')
if a[:2] == ['mcp', 'remove']:
    if a[-1] not in servers:
        sys.exit(1)
    del servers[a[-1]]
elif a[:2] == ['mcp', 'add-json']:
    servers[a[-2]] = json.loads(a[-1])
else:   # e.g. `mcp add -e KEY=value name ...`: the real -e takes every word after it
    sys.exit(1)
cfg.write_text(json.dumps(data))
"""


class ClaudeCodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        home = Path(self.tmp.name)
        data = home / 'Library' / 'Application Support' / 'AI Face'
        self.bin = home / 'bin'
        self.bin.mkdir()
        for p in [patch.object(Path, 'home', return_value=home), patch.object(paths, 'DATA', data),
                  patch.object(paths, 'LEGACY_DATA', home / 'Library' / 'Application Support' / 'ESP32Face'),
                  patch.object(integrations, 'CLAUDE_CODE_DIRS', [str(self.bin)]),
                  patch.dict('os.environ', {'FAKE_HOME': str(home), 'PATH': '/usr/bin:/bin'})]:
            p.start()
            self.addCleanup(p.stop)
        self.home = home

    def tearDown(self):
        self.tmp.cleanup()

    def fake_cli(self):
        cli = self.bin / 'claude'
        cli.write_text(FAKE_CLAUDE)
        cli.chmod(0o755)

    def test_not_installed(self):
        st = integrations.status()
        self.assertFalse(st['claude_code_available'])
        self.assertEqual(st['claude_code'], 'off')
        with self.assertRaises(ValueError):
            integrations.install('claude_code')

    def test_connect_and_disconnect(self):
        self.fake_cli()
        cfg = self.home / '.claude.json'
        cfg.write_text(json.dumps({'mcpServers': {'esp32-face': {'command': 'x', 'args': ['/old.py']},
                                                  'keep': {'command': 'y'}}, 'theme': 'dark'}))
        self.assertTrue(integrations.status()['claude_code_available'])
        self.assertEqual(integrations.claude_code_status(), 'other')
        integrations.install('claude_code')
        data = json.loads(cfg.read_text())
        self.assertEqual(integrations.claude_code_status(), 'on')
        self.assertNotIn('esp32-face', data['mcpServers'])
        self.assertIn('keep', data['mcpServers'])
        self.assertEqual(data['theme'], 'dark')
        entry = data['mcpServers']['ai-face']
        self.assertEqual(entry['args'], [str(integrations.server_path())])
        self.assertEqual(entry['env'], {'AIFACE_AGENT': 'claude'})
        self.assertIn('-s user', (self.home / 'calls.log').read_text())
        integrations.remove('claude_code')
        self.assertEqual(integrations.claude_code_status(), 'off')
        self.assertIn('keep', json.loads(cfg.read_text())['mcpServers'])

    def test_uses_copy_inside_claude_app(self):
        # only the Claude app's Code tab: its own copy of `claude` is used, newest version
        root = self.home / 'Library' / 'Application Support' / 'Claude' / 'claude-code'
        for ver in ('2.1.9', '2.1.295'):
            cli = root / ver / 'abc' / 'claude.app' / 'Contents' / 'MacOS' / 'claude'
            cli.parent.mkdir(parents=True)
            cli.write_text(FAKE_CLAUDE)
            cli.chmod(0o755)
        self.assertIn('/2.1.295/', integrations.claude_code_cli())
        self.assertTrue(integrations.status()['claude_code_available'])
        integrations.install('claude_code')
        self.assertEqual(integrations.claude_code_status(), 'on')

    def test_refresh_survives_missing_cli(self):
        # an old Claude Code registration but no `claude` command: other apps still get updated
        (self.home / '.claude.json').write_text(json.dumps({'mcpServers': {'esp32-face': {'args': ['/x']}}}))
        integrations.refresh()
        self.assertTrue(integrations.server_path().exists())


class AutoConnectTests(unittest.TestCase):
    def test_connects_and_backs_off(self):
        class Fake:
            fd, paused, message = None, False, ''
            lock = threading.RLock()
            tries = []

            def connect(self, port):
                self.tries.append(port)
                if len(self.tries) == 1:
                    raise ValueError('old firmware')
                self.fd = 3

            def close(self):
                self.fd = None
        dev, stop = Fake(), threading.Event()
        with patch.object(server, 'ports', return_value=['/dev/cu.usbmodem1']):
            t = threading.Thread(target=server.auto_connect, args=(dev, stop, 0.01, 0.2))
            t.start()
            time.sleep(0.1)
            self.assertEqual(len(dev.tries), 1)      # waits before trying the failed port again
            self.assertEqual(dev.message, 'old firmware')
            time.sleep(0.4)
            stop.set(); t.join()
        self.assertEqual(dev.fd, 3)
        self.assertEqual(len(dev.tries), 2)


if __name__ == '__main__':
    unittest.main()
