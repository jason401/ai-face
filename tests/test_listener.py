"""AI Face Listener (Transcribe): the Swift checks of its audio-free parts, and, with
AIFACE_LISTENER_E2E=1 and whisper.cpp + a model on this Mac, spoken Korean and English (macOS `say`)
through the real segmenter → whisper-server → transcript path (`--file`). No microphone or system
audio is used, and the end-to-end test checks that no audio file is left anywhere it writes."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import pwd

# The real models (read only, by symlink), found before isolate swaps HOME for a temporary one.
MODELS = Path(pwd.getpwuid(os.getuid()).pw_dir) / 'Library/Application Support/AI Face/Listener/models'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)

ROOT = Path(__file__).resolve().parents[1]
LISTENER = ROOT / 'app/listener'
ARCH = os.uname().machine


def swiftc(out, *sources):
    cmd = ['xcrun', 'swiftc', '-swift-version', '5', '-target', f'{ARCH}-apple-macos14.2', '-o', str(out),
           *[str(s) for s in sources]]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=600)


@unittest.skipUnless(shutil.which('xcrun'), 'needs Xcode command line tools')
class ListenerChecks(unittest.TestCase):
    def test_swift_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            built = swiftc(Path(tmp) / 'check', LISTENER / 'Segmenter.swift', LISTENER / 'Transcript.swift',
                           LISTENER / 'Capture.swift', LISTENER / 'Whisper.swift',
                           ROOT / 'tools/tests/listener_check/main.swift')
            self.assertEqual(built.returncode, 0, built.stderr[-2000:])
            run = subprocess.run([str(Path(tmp) / 'check')], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('listener checks: OK', run.stdout)

    def test_consent_checkbox_is_visible_and_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'check'
            built = swiftc(binary, ROOT / 'app/macos/Transcribe.swift',
                           ROOT / 'tools/tests/transcribe_check/main.swift')
            self.assertEqual(built.returncode, 0, built.stderr[-2000:])
            strings = ROOT / 'app/macos/Resources/ko.lproj/Localizable.strings'
            for args in ([], [str(strings)]):
                with self.subTest(korean=bool(args)):
                    run = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=30)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertIn('consent form: OK', run.stdout)

    def test_helper_plist_and_build_script(self):
        script = (ROOT / 'tools/build_app.sh').read_text()
        self.assertIn('Contents/Helpers/AI Face Listener.app', script)
        self.assertIn('NSMicrophoneUsageDescription', script)
        self.assertIn('NSAudioCaptureUsageDescription', script)
        self.assertIn('apple-macos14.2', script)
        self.assertIn('Set up Transcription.command', script)
        # macOS can look up the descriptions on the enclosing app even when the helper requests audio.
        for bundle in ('$CANDIDATE', '$LISTENER'):
            plist = script.split(f'cat > "{bundle}/Contents/Info.plist"')[1].split('\nPLIST\n')[0]
            for key in ('NSMicrophoneUsageDescription', 'NSAudioCaptureUsageDescription'):
                self.assertIn(f'<key>{key}</key><string>', plist)
        launcher = (ROOT / 'app/macos/Transcribe.swift').read_text()
        self.assertNotIn('requestAccess(for: .audio)', launcher)

    def test_no_audio_is_written(self):
        # The only file writes in the Listener are the transcript (Data(header) + FileHandle);
        # nothing builds an AVAudioFile for writing or writes the WAV it sends to Whisper.
        source = '\n'.join(p.read_text() for p in LISTENER.glob('*.swift'))
        for banned in ['AVAudioFile(forWriting', 'AVAudioRecorder', 'ExtAudioFileCreate', 'AudioFileCreate',
                       '"--convert"']:   # --convert: whisper-server would write ffmpeg temp files
            self.assertNotIn(banned, source, banned)
        self.assertEqual(source.count('FileHandle(forWritingTo'), 1)   # the transcript
        # AI Face passes the time everyone's agreement was confirmed; the Listener refuses without it.
        self.assertIn('"--agreed"', (ROOT / 'app/macos/Transcribe.swift').read_text())
        self.assertIn('options.agreed.isEmpty', (LISTENER / 'main.swift').read_text())


@unittest.skipUnless(os.environ.get('AIFACE_LISTENER_E2E') == '1', 'set AIFACE_LISTENER_E2E=1 (needs whisper.cpp + model)')
class ListenerEndToEnd(unittest.TestCase):
    def test_korean_and_english_file(self):
        server = shutil.which('whisper-server') or '/opt/homebrew/bin/whisper-server'
        models = sorted(MODELS.glob('ggml-large-v3-turbo*.bin'))
        if not Path(server).exists() or not models:
            self.skipTest('whisper.cpp or the model is not on this Mac')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            built = swiftc(tmp / 'AIFaceListener', *sorted(LISTENER.glob('*.swift')))
            self.assertEqual(built.returncode, 0, built.stderr[-2000:])
            audio = tmp / 'audio'
            audio.mkdir()
            parts = [('Yuna', '오늘 미팅에서 공진 주파수가 오백십이 킬로헤르츠로 측정됐다고 말씀드렸습니다.'),
                     ('Samantha', 'The pressure in the water drops quickly near the thin glass plate.'),
                     ('Yuna', '다음 주까지 hydrophone 측정을 다시 하고 결과를 공유할게요.')]
            wavs = []
            for i, (voice, text) in enumerate(parts):
                aiff = audio / f'{i}.aiff'
                subprocess.run(['say', '-v', voice, '-o', str(aiff), text], check=True, timeout=60)
                wav = audio / f'{i}.wav'
                subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)],
                               check=True, timeout=60)
                wavs.append(wav)
            # One file: each part's samples, then 1.5 s of quiet, under one WAV header.
            pcm = b''
            for w in wavs:
                data = w.read_bytes()
                pcm += data[data.index(b'data') + 8:] + b'\0' * (16000 * 2 * 3 // 2)
            joined = audio / 'all.wav'
            joined.write_bytes(wav_header(len(pcm)) + pcm)

            support = tmp / 'support'
            (support / 'models').mkdir(parents=True)
            for m in models[:1] + sorted(MODELS.glob('ggml-silero*.bin'))[:1]:
                (support / 'models' / m.name).symlink_to(m)
            (support / 'glossary.txt').write_text('# test\nhydrophone\n')
            out = tmp / 'out'
            env = dict(os.environ, AIFACE_LISTENER_SUPPORT=str(support), TMPDIR=str(tmp / 'whisper-tmp') + '/')
            (tmp / 'whisper-tmp').mkdir()
            run = subprocess.run([str(tmp / 'AIFaceListener'), '--file', str(joined), '--out', str(out)],
                                 capture_output=True, text=True, timeout=600, env=env)
            self.assertEqual(run.returncode, 0, run.stderr[-2000:])
            transcript = Path(run.stdout.strip())
            text = transcript.read_text()
            lines = [line for line in text.splitlines() if '**Them:**' in line]
            self.assertEqual(len(lines), 3, text)
            self.assertIn('512', lines[0])
            self.assertTrue(lines[0].startswith('⚑ '), lines[0])
            self.assertIn('측정', lines[0])
            self.assertIn('pressure', lines[1].lower())
            # The glossary helps but does not force a spelling: Whisper may still write it in Hangul.
            self.assertTrue('hydrophone' in lines[2].lower() or '하이드로폰' in lines[2], lines[2])
            self.assertIn('- Stopped', text)
            self.assertIn('Everyone agreed: not recorded', text)   # file mode: no agreement asked
            # Only the transcript was written, and whisper-server's own folder is gone.
            written = [p for p in out.rglob('*') if p.is_file()]
            self.assertEqual(written, [transcript])
            self.assertEqual(list((tmp / 'whisper-tmp').iterdir()), [])

            # Live without the agreement confirmed in AI Face: refused before anything opens.
            refused = subprocess.run([str(tmp / 'AIFaceListener'), '--start', '--out', str(tmp / 'live')],
                                     capture_output=True, text=True, timeout=30, env=env)
            self.assertEqual(refused.returncode, 2, refused.stderr)
            self.assertIn('everyone agreed', refused.stderr)
            self.assertFalse((tmp / 'live').exists())


def wav_header(n):
    import struct
    return (b'RIFF' + struct.pack('<I', 36 + n) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16)
            + b'data' + struct.pack('<I', n))


if __name__ == '__main__':
    unittest.main()
