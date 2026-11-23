#!/usr/bin/env python3
"""Stream to the AI Face board from another app: a small client for docs/STREAMING_API.md.
Python standard library only; copy the AIFaceStream class into your own app.

  python3 tools/stream_example.py                      # a ball bouncing around the round screen
  python3 tools/stream_example.py --hold 30            # one picture, kept for 30 s by the lease
  ffmpeg -re -i movie.mp4 -vf "scale=240:240:force_original_aspect_ratio=increase,crop=240:240" \\
         -pix_fmt rgb565le -f rawvideo - | python3 tools/stream_example.py --raw
"""
import argparse
import json
import math
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

DISCOVERY = Path.home() / 'Library' / 'Application Support' / 'AI Face' / 'controller.json'
SIZE, FRAME_BYTES = 240, 240 * 240 * 2


class Busy(Exception):
    """Another app is streaming (its name is in .app)."""

    def __init__(self, app):
        super().__init__(f'{app} is streaming to the board')
        self.app = app


class AIFaceStream:
    def __init__(self, app, lease=5):
        self.app, self.lease, self.session = app, lease, None
        self.base = self.token = None

    def _find(self):
        info = json.loads(DISCOVERY.read_text())   # rewritten each time AI Face starts
        self.base = f"http://127.0.0.1:{info['port']}"   # not "localhost": the Host must match
        self.token = info['token']

    def _call(self, method, path, body=None):
        if self.base is None:
            self._find()
        headers = {'X-ESP-Token': self.token, 'Content-Type': 'application/octet-stream'}
        if self.session:
            headers['X-Stream-Session'] = self.session
        req = urllib.request.Request(self.base + path, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            reply = json.loads(e.read() or b'{}')
            if e.code == 409:
                raise Busy(reply.get('busy_by'))
            if e.code == 403:
                self.base = None   # AI Face restarted: new port and token
            raise RuntimeError(reply.get('message') or f'HTTP {e.code}')
        except urllib.error.URLError:
            self.base = None       # AI Face not running (or restarting)
            raise

    def info(self):
        """Can I stream now? (board connected, who streams). Needs no session."""
        return self._call('GET', '/stream/info')

    def start(self):
        reply = self._call('POST', '/stream/start', json.dumps({'app': self.app, 'lease': self.lease}).encode())
        self.session = reply['session']
        return reply

    def frame(self, rgb565le):
        """Send one whole picture; returns False when the stream ended (swipe, timeout, ...)."""
        return bool(self._call('POST', '/stream/frame', rgb565le).get('streaming'))

    def keepalive(self):
        return bool(self._call('POST', '/stream/keepalive', b'').get('streaming'))

    def stop(self):
        if self.session:
            try:
                self._call('POST', '/stream/stop', b'')
            finally:
                self.session = None


def rgb565(r, g, b):
    v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
    return bytes((v & 255, v >> 8))


def ball_frame(t):
    """A dark screen with a ball moving on a circle (only the circle is visible on the board)."""
    bg, ball = rgb565(10, 14, 40), rgb565(255, 140, 40)
    px = bytearray(bg * SIZE * SIZE)
    cx, cy, r = 120 + 70 * math.cos(t), 120 + 70 * math.sin(1.3 * t), 22
    for y in range(max(0, int(cy - r)), min(SIZE, int(cy + r) + 1)):
        dx = math.sqrt(max(0.0, r * r - (y - cy) ** 2))
        x0, x1 = max(0, int(cx - dx)), min(SIZE, int(cx + dx) + 1)
        px[(y * SIZE + x0) * 2:(y * SIZE + x1) * 2] = ball * (x1 - x0)
    return bytes(px)


def latest_from_stdin(box, done):
    """Read raw frames from stdin, keeping only the newest (a slow board drops frames instead
    of slowing the video down)."""
    while True:
        data = sys.stdin.buffer.read(FRAME_BYTES)
        if len(data) < FRAME_BYTES:
            break
        box[0] = data
    done.set()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', default='Stream example')
    parser.add_argument('--hold', type=float, help='show one picture for this many seconds')
    parser.add_argument('--raw', action='store_true', help='240x240 rgb565le frames from stdin')
    parser.add_argument('--seconds', type=float, default=20, help='how long the demo runs')
    args = parser.parse_args()

    face = AIFaceStream(args.app, lease=args.hold or 5)
    info = face.info()
    if not info['board'] or info['supported'] is False:
        sys.exit('No board, or its firmware is too old for streaming.')
    try:
        face.start()
    except Busy as busy:
        sys.exit(f'{busy.app} is streaming now; try again later.')
    try:
        if args.hold:
            face.frame(ball_frame(0))
            return   # AI Face keeps it on screen until the lease runs out
        if args.raw:
            box, done = [None], threading.Event()
            threading.Thread(target=latest_from_stdin, args=(box, done), daemon=True).start()
            sent, last = None, time.monotonic()
            while not done.is_set() or box[0] is not sent:
                frame = box[0]
                if frame is None or frame is sent:   # nothing new: renew the lease now and then
                    time.sleep(0.005)
                    if time.monotonic() - last > 1:
                        if not face.keepalive():
                            break
                        last = time.monotonic()
                    continue
                sent, last = frame, time.monotonic()
                if not face.frame(frame):
                    break
            face.stop()
            return
        start = time.monotonic()
        while time.monotonic() - start < args.seconds:
            if not face.frame(ball_frame(time.monotonic() - start)):
                print('The board left the stream (swipe or another screen).')
                return
        face.stop()
    except BaseException:
        face.stop()
        raise


if __name__ == '__main__':
    main()
