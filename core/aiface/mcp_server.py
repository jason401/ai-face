"""AI Face as an MCP server (stdio). Python standard library only.

An AI chat app (Claude desktop, Claude Code, or any client that supports local
stdio MCP servers) launches this file and can then call:

  set_expression(emotion)        show one of the 64 moods on the round LCD
  show_clock()                   switch the LCD back to the clock
  start_timer(minutes, color)    countdown ring on the LCD (pomodoro, meetings, ...)
  cancel_timer()                 remove the countdown ring
  show_photo()                   show the current photo (photos are added in the controller app)
  update_firmware()              compile ESP32_Display.ino and upload it to the board

When nobody changes the face for a while the board shows a screen saver chosen in
the controller app (sleepy/asleep face, clock, photo or slideshow).

Each face gets a border ring showing which AI chose it: Claude orange or GPT
green (faces picked by hand in the controller app get a white ring). The AI is
taken from the ESP32_AGENT environment variable set at registration
(claude / gpt), or else guessed from the client name sent in "initialize".

Delivery: if "ESP32 Controller" is running it owns the USB port, so the request
is forwarded to it over localhost. Otherwise this server opens the USB port
itself, sends the animation, and closes the port again right away, so the
controller app can still be started at any time.
"""
import json
import os
import sys
import urllib.error
import urllib.request

from . import moods as face_modes
from . import paths

SERVER_NAME = 'esp32-face'
SERVER_VERSION = '1.5.0'
PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05']
# Written by esp_display.py while it runs (outside ~/Documents, see install_mcp.py).
DISCOVERY = paths.DISCOVERY

# Name the chat app reported in "initialize" (one server process per app).
CLIENT_NAME = ''
GPT_ALIASES = ('gpt', 'chatgpt', 'codex', 'openai')

MOODS = face_modes.emotions()
BY_ID = {m['id']: m for m in MOODS}

INSTRUCTIONS = (
    "This user has a small round LCD on an ESP32 that shows your face. "
    "In every reply, call set_expression exactly once, choosing the mood that best "
    "matches the emotional tone of YOUR reply (how you, the assistant, would look "
    "while saying it). Examples: good news or success -> happy/triumph/proud; "
    "thanks -> grateful; asking a question -> curious; explaining -> talking; "
    "careful reasoning -> thinking; long tool work -> processing; an error or "
    "mistake -> awkward/apologetic; sad topic -> sympathy/sad; greeting -> greeting. "
    "Vary moods naturally; do not mention the tool call in your reply unless asked. "
    "If the call fails, continue the conversation normally. "
    "start_timer / cancel_timer are only for when the user asks for a timer, a pomodoro, "
    "or a countdown (e.g. to their next meeting); still call set_expression as usual. "
    "show_photo is only for when the user asks to see their photo on the display; it stays "
    "until your next set_expression, so in that reply skip set_expression."
)


def _catalog_text():
    lines = []
    for m in MOODS:
        lines.append(f"{m['id']}: {m['name']} ({m['group']}) - {m['description']}")
    return '\n'.join(lines)


TOOLS = [
    {
        'name': 'set_expression',
        'title': 'ESP32 표정 바꾸기',
        'description': (
            "Show a facial expression on the user's ESP32 round display. Call once per "
            "reply with the mood matching the tone of your answer. Available moods "
            "(id: Korean name (group) - look):\n" + _catalog_text()
        ),
        'inputSchema': {
            'type': 'object',
            'properties': {
                'emotion': {
                    'type': 'string',
                    'enum': [m['id'] for m in MOODS],
                    'description': 'Mood id, e.g. happy, thinking, curious, apologetic.',
                },
            },
            'required': ['emotion'],
            'additionalProperties': False,
        },
        # Only changes the picture on the user's own display: no files, no network.
        'annotations': {'readOnlyHint': False, 'destructiveHint': False,
                        'idempotentHint': True, 'openWorldHint': False},
    },
    {
        'name': 'start_timer',
        'title': 'ESP32 타이머 시작',
        'description': (
            "Start a countdown on the user's ESP32 display: a colored ring empties clockwise "
            "from 12 o'clock and blinks when time is up (it also wakes a sleeping face). "
            "Use only when the user asks for a timer, pomodoro, or countdown "
            "(e.g. minutes until a meeting). Starting a new timer replaces the old one."),
        'inputSchema': {
            'type': 'object',
            'properties': {
                'minutes': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 1440,
                            'description': 'Length in minutes (decimals allowed, e.g. 0.5 = 30 s).'},
                'color': {'type': 'string', 'enum': list(face_modes.TIMER_COLORS),
                          'description': 'Ring color. Default blue. e.g. red = focus, green = break.'},
            },
            'required': ['minutes'],
            'additionalProperties': False,
        },
        'annotations': {'readOnlyHint': False, 'destructiveHint': False,
                        'idempotentHint': False, 'openWorldHint': False},
    },
    {
        'name': 'cancel_timer',
        'title': 'ESP32 타이머 취소',
        'description': "Remove the countdown ring from the user's ESP32 display. Use only when the user asks.",
        'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
        'annotations': {'readOnlyHint': False, 'destructiveHint': False,
                        'idempotentHint': True, 'openWorldHint': False},
    },
    {
        'name': 'show_photo',
        'title': 'ESP32 사진 띄우기',
        'description': ("Show the current photo on the user's ESP32 display (the user adds up to 10 photos "
                        "by dragging them into the controller app). Use only when the user asks to see it. "
                        "The next set_expression replaces it, so skip set_expression in that reply."),
        'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
        'annotations': {'readOnlyHint': False, 'destructiveHint': False,
                        'idempotentHint': True, 'openWorldHint': False},
    },
    {
        'name': 'update_firmware',
        'title': 'ESP32 펌웨어 업로드',
        'description': ("Compile ESP32_Display/ESP32_Display.ino in the user's ESP32 project folder and upload "
                        "it to the board over USB (uses the Arduino IDE's arduino-cli; takes up to a few "
                        "minutes). On failure the compiler or upload errors are returned so they can be fixed. "
                        "Use only when the user asks to upload/flash the firmware, or agreed to it after the "
                        "firmware was changed."),
        'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
        'annotations': {'readOnlyHint': False, 'destructiveHint': False,
                        'idempotentHint': True, 'openWorldHint': False},
    },
    {
        'name': 'show_clock',
        'title': 'ESP32 시계로 바꾸기',
        'description': "Switch the user's ESP32 display back to the analog clock (synced to the Mac's time). "
                       "Use only when the user asks for the clock.",
        'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
        # Only changes the picture on the user's own display: no files, no network.
        'annotations': {'readOnlyHint': False, 'destructiveHint': False,
                        'idempotentHint': True, 'openWorldHint': False},
    },
]


class DeliveryError(Exception):
    pass


def agent():
    """Which AI is using this server: 'claude' or 'gpt' (border ring color)."""
    configured = os.environ.get('ESP32_AGENT', '').strip().lower()
    if configured == 'claude':
        return 'claude'
    if configured in GPT_ALIASES:
        return 'gpt'
    # Claude desktop / Claude Code report names containing "claude"; the only other
    # AI app this server is used with is GPT (e.g. Codex reports "codex-mcp-client").
    return 'claude' if 'claude' in CLIENT_NAME.lower() else 'gpt'


# ----- delivery via the running controller app -----------------------------
def _controller():
    """Return (port, token) of a running controller app, or None."""
    try:
        info = json.loads(DISCOVERY.read_text())
        port, token = info['port'], info['token']
        if type(port) is int and isinstance(token, str):
            return port, token
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def _request(port, token, method, path, data=None, timeout=20):
    if isinstance(data, dict) and data.get('action') == 'firmware':
        timeout = 1200   # compiling the first time takes a while
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=body, method=method)
    req.add_header('Content-Type', 'application/json')
    req.add_header('X-ESP-Token', token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except ValueError:
            return e.code, {'message': f'HTTP {e.code}'}


def _via_app(port, token, payload):
    status, state = _request(port, token, 'GET', '/state')
    if status != 200:
        raise DeliveryError('컨트롤러 앱 상태를 읽지 못했습니다.')
    # The app connects to a board by itself when one is plugged in, and shows the face in
    # the menu bar either way, so no board is not an error any more.
    status, state = _request(port, token, 'POST', '/api', payload)
    if status != 200:
        raise DeliveryError(state.get('message', '전송 실패'))
    return state.get('message', '')


# ----- direct USB delivery -------------------------------------------------
def _direct(action):
    from . import board as esp_display  # only needed when the app is not running
    available = esp_display.ports()
    wanted = os.environ.get('ESP32_PORT')
    port = wanted if wanted in available else (available[0] if available else None)
    if port is None:
        raise DeliveryError('ESP32가 USB로 연결되어 있지 않습니다.')
    device = esp_display.Device()
    try:
        device.connect(port)
        action(device)
        return device.message
    except (OSError, ValueError, TimeoutError) as exc:
        raise DeliveryError(str(exc))
    finally:
        device.close()


def deliver(payload, direct_action):
    app = _controller()
    if app:
        try:
            return _via_app(app[0], app[1], payload)
        except (urllib.error.URLError, ConnectionError, OSError):
            pass  # stale discovery file: the app is not actually running
    return _direct(direct_action)


def set_expression(emotion):
    mood = BY_ID.get(emotion)
    if mood is None:
        raise DeliveryError(f'알 수 없는 감정입니다: {emotion}')
    who = agent()
    deliver({'action': 'emotion', 'id': emotion, 'agent': who}, lambda d: d.upload(mood, who))
    return f"ESP32 표정을 '{mood['name']}'({emotion})(으)로 바꿨습니다."


def show_clock():
    deliver({'action': 'mode', 'mode': 'CLOCK'}, lambda d: d.set_mode('CLOCK'))
    return 'ESP32 화면을 시계로 바꿨습니다.'


def start_timer(minutes, color='blue'):
    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not 0 < minutes <= 1440:
        raise DeliveryError('minutes는 0보다 크고 1440 이하인 숫자여야 합니다.')
    if color not in face_modes.TIMER_COLORS:
        raise DeliveryError('color: ' + ', '.join(face_modes.TIMER_COLORS))
    seconds = max(1, int(round(minutes * 60)))
    deliver({'action': 'timer', 'seconds': seconds, 'color': color}, lambda d: d.start_timer(seconds, color))
    return f'ESP32에 {face_modes.duration_text(seconds)} 타이머를 시작했습니다 ({color}).'


def update_firmware():
    app = _controller()
    if app:
        try:
            return _via_app(app[0], app[1], {'action': 'firmware'})
        except (urllib.error.URLError, ConnectionError, OSError):
            pass  # stale discovery file: the app is not actually running
    from . import board as esp_display  # the app is not running: the USB port is free
    available = esp_display.ports()
    wanted = os.environ.get('ESP32_PORT')
    port = wanted if wanted in available else (available[0] if available else None)
    if port is None:
        raise DeliveryError('ESP32가 USB로 연결되어 있지 않습니다.')
    device = esp_display.Device()
    try:
        return device.flash_firmware(port)
    except (OSError, ValueError, TimeoutError) as exc:
        raise DeliveryError(str(exc))
    finally:
        device.close()


def show_photo():
    deliver({'action': 'photo_show'}, lambda d: d.show_photo())
    return 'ESP32에 저장된 사진을 띄웠습니다.'


def cancel_timer():
    deliver({'action': 'timer', 'seconds': 0}, lambda d: d.start_timer(0))
    return 'ESP32 타이머를 취소했습니다.'


# ----- JSON-RPC / MCP ------------------------------------------------------
def _result(rid, result):
    return {'jsonrpc': '2.0', 'id': rid, 'result': result}


def _error(rid, code, message):
    return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': code, 'message': message}}


def handle(message):
    """Handle one JSON-RPC message; return a response dict or None for notifications."""
    if not isinstance(message, dict) or message.get('jsonrpc') != '2.0':
        return _error(None, -32600, 'Invalid Request')
    rid = message.get('id')
    method = message.get('method')
    params = message.get('params') or {}
    if 'id' not in message:
        return None  # notification (e.g. notifications/initialized)
    if method == 'initialize':
        global CLIENT_NAME
        info = params.get('clientInfo')
        if isinstance(info, dict) and isinstance(info.get('name'), str):
            CLIENT_NAME = info['name']
        # Shows up in the chat app's MCP log, handy for checking the ring color choice.
        print(f'esp32-face: client={CLIENT_NAME!r} agent={agent()}', file=sys.stderr, flush=True)
        requested = params.get('protocolVersion')
        return _result(rid, {
            'protocolVersion': requested if requested in PROTOCOLS else PROTOCOLS[0],
            'capabilities': {'tools': {'listChanged': False}},
            'serverInfo': {'name': SERVER_NAME, 'title': 'ESP32 Face', 'version': SERVER_VERSION},
            'instructions': INSTRUCTIONS,
        })
    if method == 'ping':
        return _result(rid, {})
    if method == 'tools/list':
        return _result(rid, {'tools': TOOLS})
    if method == 'tools/call':
        name = params.get('name')
        args = params.get('arguments') or {}
        try:
            if name == 'set_expression':
                if not isinstance(args.get('emotion'), str):
                    return _error(rid, -32602, 'emotion (string) is required')
                text = set_expression(args['emotion'])
            elif name == 'show_clock':
                text = show_clock()
            elif name == 'start_timer':
                text = start_timer(args.get('minutes'), args.get('color', 'blue'))
            elif name == 'cancel_timer':
                text = cancel_timer()
            elif name == 'show_photo':
                text = show_photo()
            elif name == 'update_firmware':
                text = update_firmware()
            else:
                return _error(rid, -32602, f'Unknown tool: {name}')
            return _result(rid, {'content': [{'type': 'text', 'text': text}], 'isError': False})
        except DeliveryError as exc:
            return _result(rid, {'content': [{'type': 'text', 'text': f'ESP32 전송 실패: {exc}'}], 'isError': True})
    return _error(rid, -32601, f'Method not found: {method}')


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            response = _error(None, -32700, 'Parse error')
        else:
            try:
                response = handle(message)
            except Exception as exc:  # never crash the server on one bad request
                response = _error(message.get('id') if isinstance(message, dict) else None, -32603, str(exc))
        if response is not None:
            out.write(json.dumps(response, ensure_ascii=False) + '\n')
            out.flush()


if __name__ == '__main__':
    main()
