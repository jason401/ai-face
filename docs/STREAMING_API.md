# Streaming API (for other apps)

Other apps on this Mac can show their own pictures on the AI Face board: an animation from
a menu bar app, a status card from an AI app, a video. The app draws 240×240 pictures and
sends them to AI Face, which forwards only the changed parts over USB. One app streams at a
time. A working client: [`tools/stream_example.py`](../tools/stream_example.py).

API version 1 (`"api": 1` in `/stream/info`). Needs a board with the streaming firmware
(Settings → Board → Details → update the firmware once).

## Connecting

AI Face listens on `127.0.0.1` only, on a port that changes each time it starts. Read the
port and the token from

```
~/Library/Application Support/AI Face/controller.json   →  {"port": 53348, "token": "…", "pid": 123}
```

- Send requests to `http://127.0.0.1:<port>`. The `Host` header must be exactly
  `127.0.0.1:<port>`; `localhost` is refused (403).
- Every POST needs the header `X-ESP-Token: <token>`.
- Port and token are new after AI Face restarts: on 403 or a refused connection, read the
  file again.
- Sandboxed apps (Mac App Store) cannot read this file; this version is for apps without
  the sandbox.

## The flow

1. **Check**: `GET /stream/info` (no token). Is a board connected (`board`), does its
   firmware stream (`supported`: `true`, `false` or `null` = not asked yet), is someone else
   streaming (`busy_by`)?
2. **Start**: `POST /stream/start` with `{"app": "Cats in Menubar", "lease": 5}`. You get a
   `session`. If another app is streaming you get 409 with `busy_by`; try again later.
3. **Send pictures**: `POST /stream/frame` with the picture as the body and
   `X-Stream-Session: <session>`. Send the next one only after the reply (the reply comes
   when the board has drawn it). Send your newest picture, not a queue of old ones.
4. **Stay alive**: every request of yours renews your lease. With nothing new to show, call
   `POST /stream/keepalive` (or send nothing and let the lease run out).
5. **Stop**: `POST /stream/stop`. The board returns to the screen it showed before, and a
   face an AI chose meanwhile appears.

The stream also ends without you: a swipe on the board, another screen chosen in AI Face,
the board unplugged, or your lease running out. Then replies say `"streaming": false`;
start again if you want the board back.

## Endpoints

| Request | Body | Reply |
|---|---|---|
| `GET /stream/info` | – | `{api, board, supported, streaming, busy_by, lease_left, size: 240, format: "rgb565le", shape: "circle", frame_bytes: 115200}` |
| `POST /stream/start` | JSON `{"app": name, "lease": seconds}` | `{…info, session, app, lease, message}` |
| `POST /stream/frame` | 115200 bytes | `{streaming, bytes, pieces, lost?, message}` |
| `POST /stream/keepalive` | empty | `{streaming, message}` |
| `POST /stream/stop` | empty | `{streaming: false, message}` |

- `app`: 1 to 60 characters, shown to the user. `lease`: 1 to 600 seconds (default 5): how
  long the stream lives after your last request. Use a short lease for live content and a
  longer one to leave a single picture up (e.g. send one frame with `"lease": 30`).
- `bytes` / `pieces`: what went over USB for this picture (0 when nothing changed).
  `lost: true`: bytes were lost on the USB line; the next picture is sent whole.

Status codes: 200 OK; 400 bad request (wrong picture size, bad JSON, no board, old firmware;
a running stream is left alone, and `streaming` says whether it is still yours); 403 wrong
token or host; 409 another app streams (`busy_by`); 503 AI Face is installing an update.

## Pictures

- 240 × 240 pixels, rows top to bottom, each pixel RGB565 **little-endian** (2 bytes:
  `v = (r >> 3) << 11 | (g >> 2) << 5 | b >> 3`, low byte first). Exactly 115200 bytes.
- The screen is round (240 across): the corners are not shown, and the 16×16 tiles wholly
  outside the circle are never sent.
- Speed: only the changed 16×16 tiles go over USB, as raw pixels or color runs, whichever
  is smaller. Small changes (a moving sprite, a counter, text) run at the rate you send;
  pictures that change everywhere (video) are limited by USB and the board to a few frames
  per second. The Streaming test window (Settings → Board → Details) shows the real rate.
- ffmpeg writes this format directly:
  `ffmpeg -re -i in.mp4 -vf "scale=240:240:force_original_aspect_ratio=increase,crop=240:240" -pix_fmt rgb565le -f rawvideo - | python3 tools/stream_example.py --raw`

## Who gets the board

- One app at a time. A second app gets 409 until the first stops or its lease runs out (a
  crashed app loses the board after its lease).
- The same app name starting again takes over its own stream (e.g. after it restarted).
- AI Face's own Streaming test window is the user's and always takes over. Nobody takes the
  board from it.
- Faces an AI sets while an app streams show in the menu bar at once and on the board when
  it is back on the face screen.
- AI Face does not install an update while an app streams.

## Planned

- A token per app that only allows streaming, given after the user approves the app in AI
  Face (today the token in `controller.json` allows everything).
- Touch positions from the board, for apps that react to taps.
