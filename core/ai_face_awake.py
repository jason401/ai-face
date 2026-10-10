#!/usr/bin/env python3
"""Ask AI Face to keep the Mac awake (lid closed) while something works.

    ai_face_awake.py hook on|off      Claude Code hooks: hold a lease for this session while it
                                      works (on: prompt submitted / before a tool; off: the
                                      reply is done or the session ended). Reads the hook's
                                      JSON on stdin. Never fails and never blocks Claude Code.
    ai_face_awake.py run CMD ARGS...  Run a command and keep the Mac awake until it ends (the
                                      lease lives with its process). Exit code = the command's.
    ai_face_awake.py status           One line: is keep awake on, and for whom.

Like the MCP server, this only messages the running app (port and token from controller.json)
and does nothing when AI Face is not running. Installed next to it in
~/Library/Application Support/AI Face. Python standard library only.
"""
import json
import os
import subprocess
import sys
import threading
import urllib.request
from pathlib import Path

DATA = Path.home() / 'Library' / 'Application Support' / 'AI Face'
DISCOVERY = DATA / 'controller.json'
HOOK_MINUTES = 20      # a Claude Code lease; renewed before every tool, given back at the end
JOB_MINUTES = 30       # a job lease, renewed every 10 min while the job runs


def call(payload, timeout=3):
    """POST to the app; returns its reply, or None when AI Face is not running or says no."""
    try:
        info = json.loads(DISCOVERY.read_text())
        req = urllib.request.Request(f"http://127.0.0.1:{int(info['port'])}/api",
                                     data=json.dumps(payload).encode(), method='POST')
        req.add_header('Content-Type', 'application/json')
        req.add_header('X-ESP-Token', str(info['token']))
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except Exception:   # not running, refused, or a bad reply: nothing to do
        return None


def hook(mode):
    try:
        data = json.loads(sys.stdin.read() or '{}')
        session = str(data.get('session_id') or 'unknown')[:40]
    except Exception:
        session = 'unknown'
    lid = 'claude-code:' + session
    if mode == 'on':
        call({'action': 'awake_acquire', 'id': lid, 'label': 'Claude Code', 'minutes': HOOK_MINUTES, 'auto': True})
    else:
        call({'action': 'awake_release', 'id': lid})
    return 0   # hooks must never disturb Claude Code


def run(args):
    if not args:
        print('usage: awake COMMAND [ARGS...]', file=sys.stderr)
        return 2
    try:
        job = subprocess.Popen(args)
    except OSError as exc:
        print(f'awake: {exc}', file=sys.stderr)
        return 127
    lid = f'job:{job.pid}'
    label = os.path.basename(args[0])[:30]
    lease = {'action': 'awake_acquire', 'id': lid, 'label': label, 'minutes': JOB_MINUTES, 'pid': job.pid}
    if call(lease) is None:
        print('awake: AI Face is not running or keep awake is not set up; running anyway.', file=sys.stderr)
    done = threading.Event()

    def renew():
        while not done.wait(600):
            call(lease)
    threading.Thread(target=renew, daemon=True).start()
    try:
        code = job.wait()
    except KeyboardInterrupt:
        job.terminate()
        code = job.wait()
    done.set()
    call({'action': 'awake_release', 'id': lid})
    return code


def status():
    try:
        info = json.loads(DISCOVERY.read_text())
        with urllib.request.urlopen(f"http://127.0.0.1:{int(info['port'])}/awake", timeout=3) as r:
            print(json.loads(r.read())['text'])
    except Exception:
        print('AI Face is not running.')
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == 'hook' and argv[1] in ('on', 'off'):
        return hook(argv[1])
    if argv and argv[0] == 'run':
        return run(argv[1:])
    if argv and argv[0] == 'status':
        return status()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
