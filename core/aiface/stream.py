"""Streaming: whole pictures drawn on the Mac (240x240, RGB565 little-endian) sent to the
board as they change. Only the parts that differ from the last picture go over USB, each as
a rectangle in the smaller of two forms: raw pixels or runs of one color. The board command is
STREAM:<x>:<y>:<w>:<h>:<enc>:<n>:<adler32> followed by n bytes (see the firmware).

Other apps stream through the server (docs/STREAMING_API.md): one app at a time, each with a
session and a lease, so a crashed app cannot keep the board."""
import secrets
import sys
import zlib
from array import array
from itertools import groupby

SIZE = 240
FRAME_BYTES = SIZE * SIZE * 2
TILE = 16                  # changes are found in 16x16 tiles (240 = 15 tiles)
MAX_PIXELS = SIZE * 32     # largest rectangle the board unpacks at once
MAX_BYTES = 16384          # largest payload the board takes in one command
RAW, RUNS = 0, 1
PING_EVERY = 1.0           # seconds without a change before the Mac says it is still there
API = 1                    # version of the streaming API in docs/STREAMING_API.md
USER_APP = 'AI Face'       # AI Face's own streaming window: the user, who may always take over
LEASE = 5.0                # default seconds a stream lives after its app's last request
MAX_LEASE = 600.0          # e.g. one picture shown for a few minutes
MAX_NAME = 60


class StreamBusy(ValueError):
    """Another app is streaming (HTTP 409)."""

    def __init__(self, app):
        self.app = app
        super().__init__(f'{app} is streaming to the board.')


def app_name(name):
    """The name an app streams under (None or empty: AI Face itself)."""
    if name is None:
        return USER_APP
    if not isinstance(name, str) or not name.strip() or len(name.strip()) > MAX_NAME:
        raise ValueError(f'"app" must be a name of 1 to {MAX_NAME} characters.')
    return ' '.join(name.split())


def lease_seconds(lease):
    if lease is None:
        return LEASE
    if isinstance(lease, bool) or not isinstance(lease, (int, float)) or not 1 <= lease <= MAX_LEASE:
        raise ValueError(f'"lease" must be 1 to {MAX_LEASE:.0f} seconds.')
    return float(lease)


def new_session():
    return secrets.token_urlsafe(16)


def _visible(tx, ty):
    """Whether any pixel of the tile at (tx, ty) lies on the round screen (240 across)."""
    r = SIZE / 2
    nx, ny = min(max(r, tx), tx + TILE), min(max(r, ty), ty + TILE)
    return (nx - r) ** 2 + (ny - r) ** 2 < r * r


# Tiles wholly outside the circle are never sent: the board cannot show them.
VISIBLE = frozenset((tx, ty) for ty in range(0, SIZE, TILE) for tx in range(0, SIZE, TILE) if _visible(tx, ty))


def checksum(data):
    return zlib.adler32(data) & 0xFFFFFFFF


def runs(pixels):
    """RGB565 bytes -> <count-1><lo><hi> runs (up to 256 pixels each)."""
    a = array('H')
    a.frombytes(pixels)
    if sys.byteorder == 'big':
        a.byteswap()
    out = bytearray()
    for color, group in groupby(a):
        n = sum(1 for _ in group)
        while n:
            k = min(n, 256)
            out += bytes((k - 1, color & 255, color >> 8))
            n -= k
    return bytes(out)


def crop(frame, x, y, w, h):
    return b''.join(frame[((y + j) * SIZE + x) * 2:((y + j) * SIZE + x + w) * 2] for j in range(h))


def changed(old, new):
    """Rectangles (x, y, w, h) that cover every visible pixel where new differs from old (all
    of them when there is no old picture). Neighboring changed tiles in a row become one
    rectangle; rectangles of the same width stack downward while they stay small enough to send."""
    done, open_ = [], {}
    for ty in range(0, SIZE, TILE):
        band, tx = [], 0
        while tx < SIZE:
            start = tx
            while tx < SIZE and (tx, ty) in VISIBLE and (old is None or any(
                    old[((y * SIZE) + tx) * 2:((y * SIZE) + tx + TILE) * 2] !=
                    new[((y * SIZE) + tx) * 2:((y * SIZE) + tx + TILE) * 2] for y in range(ty, ty + TILE))):
                tx += TILE
            if tx > start:
                band.append((start, tx - start))
            else:
                tx += TILE
        still = {}
        for x, w in band:
            r = open_.pop((x, w), None)
            if r and (r[3] + TILE) * w <= MAX_PIXELS:
                still[(x, w)] = (x, r[1], w, r[3] + TILE)
            else:
                if r:
                    done.append(r)
                still[(x, w)] = (x, ty, w, TILE)
        done.extend(open_.values())
        open_ = still
    done.extend(open_.values())
    return sorted(done, key=lambda r: (r[1], r[0]))


def pieces(old, new):
    """(x, y, w, h, enc, payload) for each changed rectangle, in the smaller form."""
    if len(new) != FRAME_BYTES or (old is not None and len(old) != FRAME_BYTES):
        raise ValueError('A streamed picture must be 240x240 RGB565 (115200 bytes).')
    out = []
    for x, y, w, h in changed(old, new):
        raw = crop(new, x, y, w, h)
        packed = runs(raw)
        enc, data = (RUNS, packed) if len(packed) < len(raw) else (RAW, raw)
        out.append((x, y, w, h, enc, data))
    return out


def unpack(enc, data, count):
    """Pixels back from a payload, as the board does (for tests)."""
    if enc == RAW:
        return data
    out = bytearray()
    for i in range(0, len(data), 3):
        out += bytes(data[i + 1:i + 3]) * (data[i] + 1)
    if len(out) != count * 2:
        raise ValueError('wrong pixel count')
    return bytes(out)
