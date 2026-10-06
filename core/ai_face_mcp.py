#!/usr/bin/env python3
"""AI Face MCP server (stdio): lets Claude, Codex and other MCP clients set the face.

This is only a messenger. Every tool call is forwarded to the running AI Face app over
localhost (the app owns the menu bar face, the optional ESP32 board and the history).
When the app is not running, the tools do nothing and say so quietly.

The chat app starts this file itself (one process per chat app), so it is installed as a
single file in ~/Library/Application Support/AI Face (macOS does not let the chat apps run
programs from ~/Documents). Python standard library only.

Tools:
  set_expression(emotion)        show one of the moods (the app writes the list to moods.json)
  get_expression(limit)          the current face and recent history (who, what, when)
  start_timer(minutes, color) / cancel_timer()
  show_clock() / show_photo()
  update_firmware()              compile and upload the board firmware (through the app)

The ring around the face shows which AI chose it: Claude orange, GPT green. The AI comes
from the AIFACE_AGENT environment variable set at registration (claude / gpt; the older
ESP32_AGENT is accepted too), or else from the client name sent in "initialize".
"""
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

SERVER_NAME = 'ai-face'
SERVER_VERSION = '2.0.0'
PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05']
DATA = Path.home() / 'Library' / 'Application Support' / 'AI Face'
DISCOVERY = DATA / 'controller.json'   # port and token of the running app
CATALOG = DATA / 'moods.json'          # the moods, written by the app when it starts
TIMER_COLORS = ['white', 'pink', 'blue', 'yellow', 'red', 'green', 'purple', 'orange']
GPT_ALIASES = ('gpt', 'chatgpt', 'codex', 'openai')
CLIENT_NAME = ''   # the chat app's name from "initialize"


def agent():
    """Which AI uses this server: 'claude' or 'gpt' (ring color)."""
    configured = (os.environ.get('AIFACE_AGENT') or os.environ.get('ESP32_AGENT') or '').strip().lower()
    if configured == 'claude':
        return 'claude'
    if configured in GPT_ALIASES:
        return 'gpt'
    # Claude desktop / Claude Code report names with "claude"; anything else is taken as GPT
    # (Codex reports "codex-mcp-client").
    return 'claude' if 'claude' in CLIENT_NAME.lower() else 'gpt'


def moods():
    try:
        data = json.loads(CATALOG.read_text())
        return [m for m in data if isinstance(m, dict) and isinstance(m.get('id'), str)]
    except (OSError, ValueError, TypeError):
        return []


INSTRUCTIONS = (
    "The user has AI Face: a small animated face in the macOS menu bar (and maybe a round LCD) "
    "that shows your expression. In every reply, call set_expression once with the mood that fits "
    "the tone of YOUR reply, e.g. success -> happy/triumph/proud, thanks -> grateful, a question "
    "-> curious, explaining -> talking, reasoning -> thinking, long tool work -> processing, a "
    "mistake -> awkward/apologetic, sad news -> sympathy. Vary moods naturally and don't mention "
    "the call. Replies: ok = shown; app_not_running = AI Face is closed and nothing was shown "
    "(carry on normally); error: ... = it failed."
)

NO_ARGS = {'type': 'object', 'properties': {}, 'additionalProperties': False}
SAFE = {'readOnlyHint': False, 'destructiveHint': False, 'idempotentHint': True, 'openWorldHint': False}


def mood_notes(catalog):
    """Meanings of the few moods whose id alone is ambiguous (the ids themselves are in the enum)."""
    return '; '.join(f"{m['id']} = {m['hint']}" for m in catalog if m.get('hint'))


def tools():
    catalog = moods()
    emotion = {'type': 'string'}
    rule = ("Call once per reply. Match the tone of YOUR reply, not the user's mood. Skip when "
            "showing a photo. Shows your expression on the user's AI Face.")
    if catalog:
        emotion['enum'] = [m['id'] for m in catalog]   # grouped order: similar moods sit together
        notes = mood_notes(catalog)
        description = rule + (' Notes: ' + notes if notes else '')
    else:
        description = rule + ' (Start the AI Face app once to load the list of moods.)'
    return [
        {'name': 'set_expression', 'title': 'Set AI Face expression',
         'description': description,
         'inputSchema': {'type': 'object', 'properties': {'emotion': emotion}, 'required': ['emotion'],
                         'additionalProperties': False},
         'annotations': SAFE},
        {'name': 'get_expression', 'title': 'Read AI Face expressions',
         'description': ("The face shown now and recent changes (mood, who chose it: claude, gpt or user, "
                         "when), plus today's counts. Use when the user asks about the face or the day's "
                         "moods, or to react to another AI's face."),
         'inputSchema': {'type': 'object', 'properties': {
             'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50, 'description': 'Recent changes (default 10).'}},
             'additionalProperties': False},
         'annotations': {'readOnlyHint': True, 'destructiveHint': False, 'idempotentHint': True,
                         'openWorldHint': False}},
        {'name': 'start_timer', 'title': 'Start a timer',
         'description': ("Countdown ring on the face; blinks when done. Only when the user asks for a "
                         "timer or pomodoro. Replaces any running timer."),
         'inputSchema': {'type': 'object', 'properties': {
             'minutes': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 1440},
             'color': {'type': 'string', 'enum': TIMER_COLORS, 'description': 'Default blue.'}},
             'required': ['minutes'], 'additionalProperties': False},
         'annotations': dict(SAFE, idempotentHint=False)},
        {'name': 'cancel_timer', 'title': 'Cancel the timer',
         'description': 'Remove the timer ring. Only when the user asks.',
         'inputSchema': NO_ARGS, 'annotations': SAFE},
        {'name': 'show_photo', 'title': 'Show a photo',
         'description': ("Show the user's photo on the face. Only when asked. It stays until the next "
                         "set_expression, so skip set_expression in that reply."),
         'inputSchema': NO_ARGS, 'annotations': SAFE},
        {'name': 'show_clock', 'title': 'Show the clock',
         'description': 'Show an analog clock on the face. Only when asked.',
         'inputSchema': NO_ARGS, 'annotations': SAFE},
        {'name': 'update_firmware', 'title': 'Update the board firmware',
         'description': ("Compile the round LCD board's firmware and upload it over USB (takes minutes); "
                         "returns compiler errors on failure. Only when the user asks to flash it."),
         'inputSchema': NO_ARGS, 'annotations': SAFE},
    ]


# ----- talking to the app --------------------------------------------------
class NotRunning(Exception):
    pass


class Failed(Exception):
    pass


def _app():
    try:
        info = json.loads(DISCOVERY.read_text())
        if type(info['port']) is int and isinstance(info['token'], str):
            return info['port'], info['token']
    except (OSError, ValueError, KeyError, TypeError):
        pass
    raise NotRunning()


def _request(method, path, data=None, timeout=20):
    port, token = _app()
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=body, method=method)
    req.add_header('Content-Type', 'application/json')
    req.add_header('X-ESP-Token', token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            try:
                return json.loads(r.read())
            except ValueError:
                raise Failed('bad reply from the app')
    except urllib.error.HTTPError as e:
        try:
            raise Failed(json.loads(e.read()).get('message') or f'HTTP {e.code}')
        except ValueError:
            raise Failed(f'HTTP {e.code}')
    except (urllib.error.URLError, ConnectionError, OSError):
        raise NotRunning()   # stale discovery file: the app is not actually running


def _api(payload, timeout=20):
    return _request('POST', '/api', payload, timeout).get('message', '')


# ----- tools ---------------------------------------------------------------
def set_expression(emotion):
    catalog = {m['id']: m for m in moods()}
    if catalog and emotion not in catalog:
        raise Failed(f'unknown mood {emotion}')
    _api({'action': 'emotion', 'id': emotion, 'agent': agent()})
    return 'ok'


def get_expression(limit=10):
    if type(limit) is not int or not 1 <= limit <= 50:
        limit = 10
    return _request('GET', f'/expression?limit={limit}', timeout=10).get('text', '')


def start_timer(minutes, color='blue'):
    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not 0 < minutes <= 1440:
        raise Failed('minutes must be above 0 and at most 1440')
    if color not in TIMER_COLORS:
        raise Failed('color: ' + ', '.join(TIMER_COLORS))
    _api({'action': 'timer', 'seconds': max(1, int(round(minutes * 60))), 'color': color})
    return 'ok'


def call_tool(name, args):
    if name == 'set_expression':
        if not isinstance(args.get('emotion'), str):
            raise ValueError('emotion (string) is required')
        return set_expression(args['emotion'])
    if name == 'get_expression':
        return get_expression(args.get('limit', 10))
    if name == 'start_timer':
        return start_timer(args.get('minutes'), args.get('color', 'blue'))
    if name == 'cancel_timer':
        _api({'action': 'timer', 'seconds': 0})
    elif name == 'show_clock':
        _api({'action': 'mode', 'mode': 'CLOCK'})
    elif name == 'show_photo':
        _api({'action': 'photo_show'})
    elif name == 'update_firmware':
        _api({'action': 'firmware'}, timeout=1200)   # the first compile takes a while
    else:
        raise KeyError(name)
    return 'ok'


# ----- JSON-RPC / MCP ------------------------------------------------------
def _result(rid, result):
    return {'jsonrpc': '2.0', 'id': rid, 'result': result}


def _error(rid, code, message):
    return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': code, 'message': message}}


def _text(rid, text, error=False):
    return _result(rid, {'content': [{'type': 'text', 'text': text}], 'isError': error})


def handle(message):
    """One JSON-RPC message in, a response dict out (None for notifications)."""
    if not isinstance(message, dict) or message.get('jsonrpc') != '2.0':
        return _error(None, -32600, 'Invalid Request')
    rid, method, params = message.get('id'), message.get('method'), message.get('params') or {}
    if 'id' not in message:
        return None
    if method == 'initialize':
        global CLIENT_NAME
        info = params.get('clientInfo')
        if isinstance(info, dict) and isinstance(info.get('name'), str):
            CLIENT_NAME = info['name']
        print(f'ai-face: client={CLIENT_NAME!r} agent={agent()}', file=sys.stderr, flush=True)
        requested = params.get('protocolVersion')
        return _result(rid, {
            'protocolVersion': requested if requested in PROTOCOLS else PROTOCOLS[0],
            'capabilities': {'tools': {'listChanged': False}},
            'serverInfo': {'name': SERVER_NAME, 'title': 'AI Face', 'version': SERVER_VERSION},
            'instructions': INSTRUCTIONS,
        })
    if method == 'ping':
        return _result(rid, {})
    if method == 'tools/list':
        return _result(rid, {'tools': tools()})
    if method == 'tools/call':
        name, args = params.get('name'), params.get('arguments') or {}
        try:
            return _text(rid, call_tool(name, args))
        except KeyError:
            return _error(rid, -32602, f'Unknown tool: {name}')
        except ValueError as exc:
            return _error(rid, -32602, str(exc))
        except NotRunning:
            # Not an error: the user simply has AI Face closed, and nothing was shown.
            return _text(rid, 'app_not_running')
        except Failed as exc:
            return _text(rid, 'error: ' + str(exc), error=True)
    return _error(rid, -32601, f'Method not found: {method}')


def main():
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
            except Exception as exc:   # never crash on one bad request
                response = _error(message.get('id') if isinstance(message, dict) else None, -32603, str(exc))
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + '\n')
            sys.stdout.flush()


if __name__ == '__main__':
    main()
