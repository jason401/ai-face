import os
import pty
import random
import select
import sys
import tempfile
import threading
import time
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


def seen(frame):
    """What the round screen shows of a frame: tiles wholly outside the circle are never sent."""
    out = bytearray(frame)
    for ty in range(0, N, stream.TILE):
        for tx in range(0, N, stream.TILE):
            if (tx, ty) not in stream.VISIBLE:
                for j in range(ty, ty + stream.TILE):
                    out[(j * N + tx) * 2:(j * N + tx + stream.TILE) * 2] = bytes(stream.TILE * 2)
    return bytes(out)


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
        self.assertEqual(seen(screen), seen(frame))
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
        self.assertEqual(seen(screen), seen(new))

    def test_random_edits_rebuild_exactly(self):
        rng = random.Random(7)
        frame = picture(0x0841)
        screen = bytearray(frame)
        for _ in range(20):
            dots = [(rng.randrange(N), rng.randrange(N), rng.randrange(1, 40), rng.randrange(65536)) for _ in range(5)]
            new = picture(0x0841, dots)
            apply(screen, stream.pieces(frame, new))
            self.assertEqual(seen(screen), seen(new))
            frame = new

    def test_runs_split_at_256(self):
        data = stream.runs((0xABCD).to_bytes(2, 'little') * 600)
        self.assertEqual(data, bytes((255, 0xCD, 0xAB, 255, 0xCD, 0xAB, 87, 0xCD, 0xAB)))
        with self.assertRaises(ValueError):
            stream.pieces(None, b'short')

    def test_corners_off_the_circle_are_not_sent(self):
        self.assertEqual(N * N // stream.TILE ** 2 - len(stream.VISIBLE), 24)
        self.assertNotIn((0, 0), stream.VISIBLE)
        self.assertIn((112, 0), stream.VISIBLE)   # the top of the circle
        corner = picture(0, [(0, 0, 16, 0xFFFF), (224, 224, 16, 0xFFFF)])
        self.assertEqual(stream.pieces(picture(0), corner), [])
        for x, y, w, h, *_ in stream.pieces(None, picture(0x1234)):
            for ty in range(y, y + h, stream.TILE):
                for tx in range(x, x + w, stream.TILE):
                    self.assertIn((tx, ty), stream.VISIBLE)

    def test_names_and_leases(self):
        self.assertEqual(stream.app_name(None), stream.USER_APP)
        self.assertEqual(stream.app_name('  Cats  in Menubar '), 'Cats in Menubar')
        for bad in ('', '   ', 'x' * 61, 3):
            with self.assertRaises(ValueError):
                stream.app_name(bad)
        self.assertEqual(stream.lease_seconds(None), stream.LEASE)
        self.assertEqual(stream.lease_seconds(30), 30.0)
        for bad in (0, 601, True, '5'):
            with self.assertRaises(ValueError):
                stream.lease_seconds(bad)


class FakeBoard:
    """The board side of streaming over a pseudo terminal, like the firmware."""

    def __init__(self, master, old_firmware=False):
        self.master, self.old = master, old_firmware
        self.screen = bytearray(stream.FRAME_BYTES)
        self.on = False
        self.lines, self.leave_after = [], None
        self.sent, self.rest = threading.Lock(), b''
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
            with self.sent:   # one writer at a time (swipe() writes from the test thread)
                self.handle(text, buf)
                buf = self.rest

    def swipe(self, screen):
        """A touch swipe on the board: it leaves the stream screen and says so."""
        with self.sent:
            self.on = False
            os.write(self.master, f'EVT SCREEN:{screen}\r\n'.encode())

    def handle(self, text, buf):
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
        self.rest = buf


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
        self.assertEqual(seen(board.screen), seen(first))
        second = picture(0x0010, [(25, 20, 30, 0xF800)])
        r = d.stream_frame(second)
        self.assertEqual(seen(board.screen), seen(second))
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
        r = d.stream_frame(picture(0, [(100, 100, 8, 0xFFFF)]))
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


    def test_one_app_at_a_time_and_ai_face_takes_over(self):
        board = FakeBoard(self.master)
        d = self.device
        cats = d.stream_start('Cats in Menubar')
        self.assertEqual((cats['app'], cats['streaming'], cats['busy_by']), ('Cats in Menubar', True, 'Cats in Menubar'))
        self.assertTrue(cats['session'])
        with self.assertRaises(stream.StreamBusy) as ctx:
            d.stream_start('Other app')
        self.assertEqual(ctx.exception.app, 'Cats in Menubar')
        with self.assertRaises(stream.StreamBusy):
            d.stream_frame(picture(0), 'not-the-session')
        with self.assertRaises(stream.StreamBusy):
            d.stream_frame(picture(0))   # no session: AI Face's own window, which did not start it
        self.assertTrue(d.stream_frame(picture(0, [(100, 100, 20, 0xF800)]), cats['session'])['streaming'])
        info = d.stream_info()
        self.assertEqual((info['busy_by'], info['size'], info['format']), ('Cats in Menubar', 240, 'rgb565le'))
        self.assertNotIn('session', info)   # never handed to others
        # AI Face's own window takes the board without a black flash (no second STREAM:ON).
        board.lines.clear()
        mine = d.stream_start()
        self.assertEqual(mine['app'], stream.USER_APP)
        self.assertEqual(board.lines, ['STREAM:PING'])
        with self.assertRaises(stream.StreamBusy):
            d.stream_frame(picture(0), cats['session'])
        with self.assertRaises(stream.StreamBusy):
            d.stream_start('Cats in Menubar')   # nobody takes it from the user
        self.assertTrue(d.stream_frame(picture(0x0010))['streaming'])
        # Only the owner stops it.
        with self.assertRaises(stream.StreamBusy):
            d.stream_stop(cats['session'])
        self.assertTrue(d.streaming and board.on)
        d.stream_stop()
        self.assertFalse(d.streaming or board.on)
        self.assertTrue(d.stream_start('Other app')['streaming'])
        # The same app starting again (e.g. after a crash) takes over its own stream.
        again = d.stream_start('Other app')
        self.assertTrue(again['streaming'])
        self.assertEqual(d.stream_frame(picture(0), again['session'])['streaming'], True)

    def test_lease_keeps_the_screen_then_ends_it(self):
        board = FakeBoard(self.master)
        d = self.device
        s = d.stream_start('Clock app', lease=3)['session']
        d.stream_frame(picture(0x0841, [(60, 60, 40, 0xFFFF)]), s)
        board.lines.clear()
        start = d.stream_sent
        d.stream_tick(start + 0.5)
        self.assertEqual(board.lines, [])
        d.stream_tick(start + 1.2)   # the server keeps the board's 3 s timer from firing
        self.assertEqual(board.lines, ['STREAM:PING'])
        d.stream_keepalive(s)   # renewed: lives 3 s from now
        self.assertGreater(d.stream_until, start + 2.9)
        d.stream_tick(d.stream_until + 0.1)
        self.assertFalse(d.streaming or board.on)
        self.assertEqual(board.lines[-1], 'STREAM:OFF')
        self.assertEqual(d.stream_keepalive(s), {'streaming': False})

    def test_a_quiet_app_does_not_keep_the_board(self):
        FakeBoard(self.master)
        d = self.device
        d.stream_start('Crashed app')
        with self.assertRaises(stream.StreamBusy):
            d.stream_start('Next app')
        d.stream_until = time.monotonic() - 0.1   # its lease ran out before the next tick
        self.assertEqual(d.stream_start('Next app')['app'], 'Next app')

    def test_bad_picture_leaves_the_stream_running(self):
        board = FakeBoard(self.master)
        d = self.device
        s = d.stream_start('Buggy app')['session']
        with self.assertRaises(ValueError):
            d.stream_frame(b'short', s)
        self.assertTrue(d.streaming and board.on)
        self.assertTrue(d.stream_frame(picture(0), s)['streaming'])

    def test_face_from_an_ai_follows_a_swipe_back_to_the_face(self):
        happy = next(m for m in face_modes.emotions() if m['id'] == 'happy')
        for screen, shown in (('face', True), ('fire', False)):
            with self.subTest(screen=screen):
                board = FakeBoard(self.master)
                d = self.device
                d.screen = 'face'
                d.stream_start()
                d.show_emotion(happy, 'claude')
                board.lines.clear()
                board.swipe(screen)
                deadline = time.monotonic() + 2
                while d.streaming and time.monotonic() < deadline:
                    d.poll_events()
                    time.sleep(0.01)
                self.assertFalse(d.streaming)
                d.catch_up()
                self.assertEqual(any(line.startswith('PLAY') for line in board.lines), shown)
                self.assertFalse(d.face_due)
                # The board thread exits when the line goes quiet; start the next one fresh.
                board.worker.join(3)

if __name__ == '__main__':
    unittest.main()
