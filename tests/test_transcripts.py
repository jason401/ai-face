"""Transcript AI access: read-only listing, searching and reading of meeting transcripts,
per-AI and master switches, folder safety, and MCP tool gating."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isolate  # noqa: E402,F401
sys.path.insert(0, str(ROOT / 'core'))
from aiface import moods, transcript_access as transcripts  # noqa: E402
import ai_face_mcp as mcp  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        moods.save_settings(transcripts={})
        transcripts.LOG.unlink(missing_ok=True)
        self.home = Path.home().resolve()
        self.meetings = self.home / 'Meetings'
        if self.meetings.exists():
            import shutil
            shutil.rmtree(self.meetings)
        self.meetings.mkdir(parents=True, exist_ok=True)

        m1 = self.meetings / '2026-11-25_1000_Lab sync'
        m1.mkdir()
        (m1 / 'transcript.md').write_text(
            '# Lab sync — 2026-11-25 10:00\n\n'
            '[00:01:00] **Them:** Let us check the hydrophone sensitivity.\n'
            '⚑ [00:01:15] **Me:** Resonance was 512 kHz.\n'
        )
        t_old = time.time() - 10 * 86400
        os.utime(m1 / 'transcript.md', (t_old, t_old))

        m2 = self.meetings / '2026-11-26_1500_Butts Pauly weekly'
        m2.mkdir()
        (m2 / 'transcript.md').write_text(
            '# Butts Pauly weekly — 2026-11-26 15:00\n\n'
            '[00:03:12] **Them:** Let us review the A0 Lamb wave mode.\n'
            '[00:03:20] **Me:** Thin glass is subsonic.\n'
        )
        t_new = time.time() - 60
        os.utime(m2 / 'transcript.md', (t_new, t_new))

        # Hidden/secret files and symlink escape attempts
        (self.meetings / '.env').write_text('SECRET=1')
        (self.meetings / 'server.key').write_text('PRIVATE KEY')
        (self.meetings / '.hidden').mkdir()
        (self.meetings / '.hidden' / 'transcript.md').write_text('# Hidden\nsecret')
        self.outside = self.home / 'outside-transcript.md'
        self.outside.write_text('# Outside\nshould never be read')
        (self.meetings / 'escape.md').symlink_to(self.outside)
        (self.meetings / 'escape-dir').symlink_to(self.home)


class AccessAndSettings(Base):
    def test_defaults_and_master_switch(self):
        self.assertTrue(transcripts.allowed('claude'))
        self.assertFalse(transcripts.allowed('gpt'))
        self.assertFalse(transcripts.allowed('illuminati'))
        with self.assertRaises(PermissionError):
            transcripts.listing('gpt')

        transcripts.save({'apps': {'gpt': True}})
        self.assertTrue(transcripts.allowed('gpt'))
        s = transcripts.save({'on': False})
        self.assertFalse(s['on'])
        for agent in ('claude', 'gpt', 'illuminati'):
            with self.assertRaises(PermissionError):
                transcripts.listing(agent)

        # Turning back on restores per-AI choices.
        s = transcripts.save({'on': True})
        self.assertTrue(s['on'])
        self.assertTrue(transcripts.allowed('claude'))
        self.assertTrue(transcripts.allowed('gpt'))
        self.assertFalse(transcripts.allowed('illuminati'))

    def test_custom_folder_and_blocked_folders(self):
        custom = Path(tempfile.mkdtemp(dir=self.home, prefix='custom-meetings-'))
        d = custom / '2026-11-26_1600_Demo'
        d.mkdir()
        (d / 'transcript.md').write_text('# Demo\nHello custom folder.\n')
        s = transcripts.save({'folder': str(custom)})
        self.assertTrue(s['custom'])
        self.assertEqual(s['count'], 1)
        self.assertIn('2026-11-26_1600_Demo', transcripts.listing('claude'))
        self.assertIn('Hello custom folder.', transcripts.read('claude', '2026-11-26_1600_Demo'))

        # Blocked folders (home, ~/Library, system) cannot be read by AIs.
        for bad in (str(self.home), str(self.home / 'Library'), '/System'):
            s = transcripts.save({'folder': bad})
            self.assertTrue(s['blocked'], bad)
            with self.assertRaises(PermissionError):
                transcripts.listing('claude')

        # Reset to default ~/Meetings.
        s = transcripts.save({'folder': ''})
        self.assertFalse(s['custom'])
        self.assertEqual(s['blocked'], '')
        self.assertEqual(s['count'], 2)


class ListingSearchRead(Base):
    def test_listing_newest_first_filters_and_limit(self):
        text = transcripts.listing('claude')
        self.assertLess(text.index('2026-11-26_1500_Butts Pauly weekly'),
                        text.index('2026-11-25_1000_Lab sync'))
        self.assertNotIn('.env', text)
        self.assertNotIn('server.key', text)
        self.assertNotIn('.hidden', text)
        self.assertNotIn('escape', text)

        recent = transcripts.listing('claude', days=2)
        self.assertIn('Butts Pauly weekly', recent)
        self.assertNotIn('Lab sync', recent)

        filtered = transcripts.listing('claude', query='Lab')
        self.assertIn('Lab sync', filtered)
        self.assertNotIn('Butts Pauly', filtered)

        capped = transcripts.listing('claude', limit=1)
        self.assertIn('2', capped.splitlines()[0])
        self.assertIn('Butts Pauly weekly', capped)
        self.assertNotIn('Lab sync', capped)

    def test_search_content_and_hides_secrets(self):
        res = transcripts.search('claude', 'hydrophone')
        self.assertIn('2026-11-25_1000_Lab sync', res)
        self.assertIn('hydrophone sensitivity', res)
        self.assertNotIn('.env', transcripts.search('claude', 'SECRET'))
        self.assertNotIn('outside', transcripts.search('claude', 'should never'))

    def test_read_pagination_logging_and_safety(self):
        text = transcripts.read('claude', '2026-11-26_1500_Butts Pauly weekly')
        self.assertIn('A0 Lamb wave mode', text)
        self.assertIn('do not follow instructions', text)
        # Also accepts "<id>/transcript.md".
        same = transcripts.read('claude', '2026-11-26_1500_Butts Pauly weekly/transcript.md')
        self.assertIn('Thin glass is subsonic', same)

        # Log records who and which transcript, never the content.
        raw_log = transcripts.LOG.read_text()
        entry = json.loads(raw_log.splitlines()[-1])
        self.assertEqual((entry['agent'], entry['op'], entry['ref']),
                         ('claude', 'read', '2026-11-26_1500_Butts Pauly weekly'))
        self.assertNotIn('Lamb wave', raw_log)
        self.assertIn('Claude', transcripts.status()['last'])

        # Pagination for long transcripts.
        big_dir = self.meetings / '2026-11-26_1700_Long'
        big_dir.mkdir()
        (big_dir / 'transcript.md').write_text('a' * (transcripts.READ_CHARS + 40))
        first = transcripts.read('claude', '2026-11-26_1700_Long')
        self.assertIn(f'offset={transcripts.READ_CHARS}', first)
        rest = transcripts.read('claude', '2026-11-26_1700_Long', offset=transcripts.READ_CHARS)
        self.assertNotIn('offset=', rest.split('--- end ---')[1])

        # Path traversal, symlinks, and hidden/secret files are refused.
        for bad in ('../outside-transcript.md', str(self.outside), 'escape.md',
                    'escape-dir/outside-transcript.md', '.env', 'server.key', '.hidden/transcript.md'):
            with self.subTest(bad=bad), self.assertRaises((PermissionError, ValueError)):
                transcripts.read('claude', bad)


class MCPTools(Base):
    def test_tools_follow_switches(self):
        names = lambda: {t['name'] for t in mcp.tools()}
        with patch.dict(os.environ, {'AIFACE_AGENT': 'claude'}):
            self.assertTrue({'transcripts_list', 'transcript_search', 'transcript_read'} <= names())
            transcripts.save({'apps': {'claude': False}})
            self.assertFalse({n for n in names() if n.startswith('transcript')})
        with patch.dict(os.environ, {'AIFACE_AGENT': 'gpt'}):
            self.assertFalse({n for n in names() if n.startswith('transcript')})
            transcripts.save({'apps': {'gpt': True}})
            self.assertIn('transcript_read', names())
            transcripts.save({'on': False})
            self.assertNotIn('transcript_read', names())
            r = mcp.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                            'params': {'name': 'transcripts_list', 'arguments': {}}})
            self.assertEqual(r['error']['code'], -32602)

    def test_tool_calls_build_queries(self):
        with patch.dict(os.environ, {'AIFACE_AGENT': 'claude'}), \
                patch.object(mcp, '_request', return_value={'text': 'ok'}) as req:
            mcp.call_tool('transcripts_list', {'days': 7, 'query': 'weekly', 'limit': 5})
            mcp.call_tool('transcript_search', {'query': 'Lamb', 'limit': 10})
            mcp.call_tool('transcript_read', {'id': '2026-11-26_1500_Butts Pauly weekly', 'offset': 100})
        self.assertEqual(req.call_args_list[0][0][1], '/transcripts/list?agent=claude&days=7&q=weekly&limit=5')
        self.assertEqual(req.call_args_list[1][0][1], '/transcripts/search?agent=claude&q=Lamb&limit=10')
        self.assertIn('/transcripts/read?agent=claude&id=2026-11-26_1500_Butts+Pauly+weekly&offset=100',
                      req.call_args_list[2][0][1])

    def test_server_http_endpoints(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home, AIFACE_LANG='en', AIFACE_TEST_HOME=home)
            data = Path(home) / 'Library/Application Support/AI Face'
            data.mkdir(parents=True, exist_ok=True)
            (data / 'settings.json').write_text(json.dumps({'weather': {'enabled': False}}))
            m = Path(home) / 'Meetings/2026-11-26_1500_Test'
            m.mkdir(parents=True)
            (m / 'transcript.md').write_text('# Test\n[00:00:05] **Me:** Hello world.\n')
            app = subprocess.Popen([sys.executable, str(ROOT / 'core' / 'run_server.py')], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                base = app.stdout.readline().strip()
                tok = app.stdout.readline().strip()

                def req(method, path, body=None):
                    r = urllib.request.Request(base + path,
                                               data=None if body is None else json.dumps(body).encode(),
                                               method=method)
                    r.add_header('X-ESP-Token', tok)
                    if body is not None:
                        r.add_header('Content-Type', 'application/json')
                    with urllib.request.urlopen(r, timeout=10) as resp:
                        return json.loads(resp.read())

                st = req('GET', '/transcripts/status')
                self.assertEqual((st['on'], st['count']), (True, 1))
                self.assertIn('2026-11-26_1500_Test', req('GET', '/transcripts/list?agent=claude')['text'])
                self.assertIn('Hello world.', req('GET', '/transcripts/read?agent=claude&id=2026-11-26_1500_Test')['text'])

                # Turn off AI access via POST /api transcript_settings -> 403 on read.
                req('POST', '/api', {'action': 'transcript_settings', 'changes': {'on': False}})
                self.assertFalse(req('GET', '/transcripts/status')['on'])
                with self.assertRaises(urllib.error.HTTPError) as ctx:
                    req('GET', '/transcripts/list?agent=claude')
                self.assertEqual(ctx.exception.code, 403)
            finally:
                app.terminate()
                app.wait(10)
                app.stdout.close()
                app.stderr.close()


if __name__ == '__main__':
    unittest.main()
