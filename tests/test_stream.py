import os
import pty
import random
import select
import sys
import tempfile
import threading
import tty
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isolate  # noqa: E402,F401  (temporary HOME for the whole test run)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core'))
from aiface import moods as face_modes  # noqa: E402
from aiface import stream  # noqa: E402
from aiface.board import Device  # noqa: E402

N = stream.SIZE


def picture(fill=0x0000, dots=()):
    """A 240x240 frame of one color with a few colored squares (x, y, size, color)."""
    px = bytearray(fill.to_bytes(2, 'little') * N * N)
    for x, y, s, c in dots:
        for j in range(y, min(N, y + s)):
            for i in range(x, min(N, x + s)):
                px[(j * N + i) * 2:(j * N + i) * 2 + 2] = c.to_bytes(2, 'little')
    return bytes(px)


def apply(screen, pieces):
    for x, y, w, h, enc, data in pieces:
        px = stream.unpack(enc, data, w * h)
        for j in range(h):
            screen[((y + j) * N + x) * 2:((y + j) * N + x + w) * 2] = px[j * w * 2:(j + 1) * w * 2]


class EncodeTests(unittest.TestCase):
    def test_first_picture_is_whole_and_small_when_flat(self):
        frame = picture(0x1234)
        out = stream.pieces(None, frame)
        screen = bytearray(stream.FRAME_BYTES)
        apply(screen, out)
        self.assertEqual(bytes(screen), frame)
        self.assertTrue(all(enc == stream.RUNS for *_, enc, _ in out))
        self.assertLess(sum(len(p[5]) for p in out), 3000)   # vs 115200 raw

    def test_only_changes_are_sent(self):
        old = picture(0, [(100, 100, 10, 0xFFFF)])
        new = picture(0, [(104, 100, 10, 0xFFFF)])
        self.assertEqual(stream.pieces(old, old), [])
        out = stream.pieces(old, new)
        self.assertEqual([(x, y, w, h) for x, y, w, h, *_ in out], [(96, 96, 32, 16)])
        screen = bytearray(old)
        apply(screen, out)
        self.assertEqual(bytes(screen), new)

    def test_noise_uses_raw_and_fits_the_board(self):
        rng = random.Random(4)
        old = bytes(stream.FRAME_BYTES)
        new = bytes(rng.randrange(256) for _ in range(stream.FRAME_BYTES))
        out = stream.pieces(old, new)
        for x, y, w, h, enc, data in out:
            self.assertLessEqual(w * h, stream.MAX_PIXELS)
            self.assertLessEqual(len(data), stream.MAX_BYTES)
            self.assertTrue(0 <= x and x + w <= N and 0 <= y and y + h <= N)
        self.assertTrue(any(enc == stream.RAW for *_, enc, _ in out))
        screen = bytearray(old)
        apply(screen, out)
        self.assertEqual(bytes(screen), new)

    def test_random_edits_rebuild_exactly(self):
        rng = random.Random(7)
        frame = picture(0x0841)
        screen = bytearray(frame)
        for _ in range(20):
            dots = [(rng.randrange(N), rng.randrange(N), rng.randrange(1, 40), rng.randrange(65536)) for _ in range(5)]
            new = picture(0x0841, dots)
            apply(screen, stream.pieces(frame, new))
            self.assertEqual(bytes(screen), new)
            frame = new

    def test_runs_split_at_256(self):
        data = stream.runs((0xABCD).to_bytes(2, 'little') * 600)
        self.assertEqual(data, bytes((255, 0xCD, 0xAB, 255, 0xCD, 0xAB, 87, 0xCD, 0xAB)))
        with self.assertRaises(ValueError):
            stream.pieces(None, b'short')


class FakeBoard:
    """The board side of streaming over a pseudo terminal, like the firmware."""

    def __init__(self, master, old_firmware=False):
        self.master, self.old = master, old_firmware
        self.screen = bytearray(stream.FRAME_BYTES)
        self.on = False
        self.lines, self.leave_after = [], None
        self.worker = threading.Thread(target=self.run, daemon=True)
        self.worker.start()

    def read(self, n, buf):
        while len(buf) < n:
            if not select.select([self.master], [], [], 2)[0]:
                break
            buf += os.read(self.master, 65536)
        return buf

    def run(self):
        buf = b''
        while True:
            try:
                while b'\n' not in buf:
                    if not select.select([self.master], [], [], 2)[0]:
                        return
                    chunk = os.read(self.master, 65536)
                    if not chunk:
                        return
                    buf += chunk
            except OSError:
                return
            line, buf = buf.split(b'\n', 1)
            text = line.decode()
            self.lines.append(text)
            reply = 'ERR COMMAND'
            if self.old and text.startswith('STREAM'):
                reply = 'ERR COMMAND'
            elif text == 'STREAM:ON':
                self.on, reply = True, 'OK STREAM'
            elif text == 'STREAM:OFF':
                self.on, reply = False, 'OK STREAM'
            elif text == 'STREAM:PING':
                reply = 'OK STREAM' if self.on else 'ERR STREAM'
            elif text.startswith('STREAM:'):
                x, y, w, h, enc, n, s = map(int, text[7:].split(':'))
                buf = self.read(n, buf)
                data, buf = buf[:n], buf[n:]
                if stream.checksum(data) != s:
                    reply = 'ERR DATA'
                elif not self.on:
                    reply = 'ERR STREAM'
                else:
                    apply(self.screen, [(x, y, w, h, enc, data)])
                    reply = 'OK STREAM'
                    if self.leave_after is not None:
                        self.leave_after -= 1
                        if self.leave_after == 0:
                            self.on = False   # e.g. a swipe on the board
            elif text.startswith(('BEGIN:', 'FRAME:', 'COMMIT', 'PLAY:', 'OWNER:')):
                reply = {'BEGIN': 'OK BEGIN', 'FRAME': 'OK FRAME', 'COMMIT': 'OK COMMIT',
                         'PLAY': 'OK PLAY', 'OWNER': 'OK OWNER'}[text.split(':')[0]]
            os.write(self.master, (reply + '\r\n').encode())


class StreamDeviceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.patches = [patch.object(face_modes, 'SETTINGS', Path(self.tmp.name) / 's.json'),
                        patch('aiface.history.record')]
        for p in self.patches:
            p.start()
        self.master, slave = pty.openpty()
        tty.setraw(slave)
        self.device = Device()
        self.device.fd = slave

    def tearDown(self):
        self.device.close()
        os.close(self.master)
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def test_frames_reach_the_board_and_faces_wait(self):
        board = FakeBoard(self.master)
        d = self.device
        d.stream_start()
        self.assertTrue(d.streaming and d.status()['streaming'])
        first = picture(0x0010, [(20, 20, 30, 0xF800)])
        r = d.stream_frame(first)
        self.assertTrue(r['streaming'])
        self.assertEqual(bytes(board.screen), first)
        second = picture(0x0010, [(25, 20, 30, 0xF800)])
        r = d.stream_frame(second)
        self.assertEqual(bytes(board.screen), second)
        self.assertLess(r['bytes'], 2000)
        # Nothing changed: nothing sent (a ping only after a quiet second).
        board.lines.clear()
        self.assertEqual(d.stream_frame(second)['pieces'], 0)
        d.stream_sent -= 2
        d.stream_frame(second)
        self.assertEqual(board.lines, ['STREAM:PING'])
        # A face from an AI does not interrupt the stream; it shows when streaming ends.
        happy = next(m for m in face_modes.emotions() if m['id'] == 'happy')
        board.lines.clear()
        d.show_emotion(happy, 'claude')
        self.assertFalse(any(line.startswith('PLAY') for line in board.lines))
        self.assertEqual(d.view()['emotion'], 'happy')   # the menu bar shows it right away
        d.stream_stop()
        self.assertFalse(d.streaming or board.on)
        self.assertTrue(any(line.startswith('PLAY') for line in board.lines))

    def test_board_leaving_stops_the_stream(self):
        board = FakeBoard(self.master)
        board.leave_after = 1
        d = self.device
        d.stream_start()
        d.stream_frame(picture(0))
        r = d.stream_frame(picture(0, [(0, 0, 8, 0xFFFF)]))
        self.assertFalse(r['streaming'] or d.streaming)
        self.assertEqual(d.stream_frame(picture(0))['streaming'], False)
        # A swipe reported by the board ends it too.
        board.on, d.streaming = True, True
        d.event('EVT SCREEN:fire')
        self.assertFalse(d.streaming)
        self.assertEqual(d.screen, 'fire')

    def test_old_firmware_is_explained(self):
        FakeBoard(self.master, old_firmware=True)
        with self.assertRaises(ValueError) as ctx:
            self.device.stream_start()
        self.assertIn('펌웨어', str(ctx.exception))
        self.assertFalse(self.device.streaming)

    def test_needs_a_board(self):
        self.device.close()
        with self.assertRaises(ValueError):
            self.device.stream_start()
        self.assertEqual(self.device.stream_frame(picture(0))['streaming'], False)


if __name__ == '__main__':
    unittest.main()
