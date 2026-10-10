"""Keep awake with the lid closed, while someone asks for it (a "lease").

Leases: each asker holds one, with a label and a deadline: "manual" (the menu), a Claude Code
session (its hooks), a job run through `awake` (alive while its process is), an AI through
MCP. The Mac stays awake while at least one lease is active and nothing vetoes it.

macOS only lets a closed MacBook stay awake through `pmset -a disablesleep 1`, which needs
root. "Set up Keep Awake.command" (tools/) installs one sudoers rule that allows exactly
`/usr/bin/pmset -a disablesleep 0` and `... 1` without a password; nothing else.

Rules (from the design guide):
- Off is the default. Every lease has a deadline; every way out turns it off: the app's own
  check (deadlines, dead processes, low battery, heat), quitting the app, "Turn off all" in
  the menu (which also pauses automatic leases for an hour, so a hook cannot turn it right
  back on), and a small detached "turn off at the last deadline" process that survives a
  crash of the app. A restart of the Mac resets it too.
- pmset is only called through set_state(), and the value is read back afterwards.
- The password is never handled here: sudo always runs with -n (fails instead of asking).
Python standard library only.
"""
import json
import os
import re
import signal
import subprocess
import threading
import time

from . import paths
from .i18n import T

PMSET = '/usr/bin/pmset'
SUDO = '/usr/bin/sudo'
STATE = paths.DATA / 'awake.json'        # {leases, on, failsafe, failsafe_until, paused_until}
CHOICES = (60, 120, 240)                 # minutes offered in the menu
MAX_MINUTES = 480
BATTERY_FLOOR = 20                       # % on battery power: turn off at or below
PAUSE = 3600                             # "Turn off all" pauses automatic leases this long

_lock = threading.RLock()
_cache = dict(on=False, ready=None, checked=0.0)
last_reason = ''                         # why it last turned off (shown in the menu)
_sleepers = []                           # failsafe processes started here (reaped when done)


def _run(args, timeout=10):
    try:
        p = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.SubprocessError):
        return -1, ''


def supported():
    return os.path.exists(PMSET)


def actual():
    """SleepDisabled as macOS reports it: True / False (None when pmset is missing)."""
    if not supported():
        return None
    code, out = _run([PMSET, '-g'])
    m = re.search(r'SleepDisabled\s+(\d)', out)
    return bool(m and m.group(1) == '1') if code == 0 else None


def ready():
    """Is the sudoers rule installed (pmset allowed without a password)?"""
    if not supported():
        return False
    code, _ = _run([SUDO, '-n', '-l', PMSET, '-a', 'disablesleep', '0'])
    return code == 0


def set_state(on):
    """The only place that changes the setting. Returns True when macOS reports `on`."""
    _run([SUDO, '-n', PMSET, '-a', 'disablesleep', '1' if on else '0'])
    return actual() == on


SETUP = 'Set up Keep Awake.command'   # in tools/: installs or removes the sudoers rule


def open_setup():
    """Open the setup script in Terminal (it asks for the admin password there, not here)."""
    root = paths.project_root()
    script = root / 'tools' / SETUP if root else None
    if script is None or not script.is_file():
        raise ValueError(T('설정 스크립트를 찾지 못했습니다.', 'The setup script is missing.'))
    code, _ = _run(['/usr/bin/open', '-a', 'Terminal', str(script)])
    if code != 0:
        raise ValueError(T('터미널을 열지 못했습니다.', 'Could not open Terminal.'))
    _cache['ready'] = None   # check again soon


def battery():
    """(on_battery, percent or None)."""
    code, out = _run([PMSET, '-g', 'batt'])
    if code != 0:
        return False, None
    m = re.search(r'(\d+)%', out)
    return "'Battery Power'" in out, int(m.group(1)) if m else None


def _load():
    try:
        data = json.loads(STATE.read_text())
    except (OSError, ValueError):
        data = None
    if not isinstance(data, dict):
        data = {}
    leases = data.get('leases')
    data['leases'] = {k: v for k, v in leases.items() if isinstance(v, dict)
                      and isinstance(v.get('until'), (int, float))} if isinstance(leases, dict) else {}
    return data


def _save(data):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temp = STATE.with_suffix('.tmp')
    temp.write_text(json.dumps(data))
    temp.replace(STATE)


def _alive(pid):
    if type(pid) is not int or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def _kill_failsafe(state):
    pid = state.get('failsafe')
    state['failsafe'] = state['failsafe_until'] = None
    if type(pid) is not int or pid <= 1:
        return
    code, out = _run(['/bin/ps', '-p', str(pid), '-o', 'command='])
    if code == 0 and 'disablesleep 0' in out:   # still our sleeper, not a reused pid
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            pass
        for q in _sleepers:   # started by this run of the app: reap it
            if q.pid == pid:
                try:
                    q.wait(timeout=2)
                except subprocess.SubprocessError:
                    pass


def _start_failsafe(seconds):
    """A process outside the app that turns the setting off at the deadline, even if the app
    has crashed by then. Its own session, so it does not die with the app."""
    try:
        p = subprocess.Popen(['/bin/sh', '-c', f'sleep {int(seconds)}; {SUDO} -n {PMSET} -a disablesleep 0'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        _sleepers[:] = [q for q in _sleepers if q.poll() is None] + [p]
        return p.pid
    except OSError:
        return None


def veto():
    """A reason it must be off now, or ''."""
    on_battery, pct = battery()
    if on_battery and pct is not None and pct <= BATTERY_FLOOR:
        return T(f'배터리 {pct}%', f'battery at {pct}%')
    return ''


def _active(lease, now):
    return lease['until'] > now and (lease.get('pid') is None or _alive(lease['pid']))


def _reconcile(state, now, reason=''):
    """Drop finished leases, then make the setting match (on while one is left). Called with
    _lock held; saves the state."""
    global last_reason
    state['leases'] = {k: v for k, v in state['leases'].items() if _active(v, now)}
    want = bool(state['leases'])
    if want and not state.get('on'):
        if not set_state(True):
            set_state(False)
            state['leases'] = {}
            _save(state)
            raise ValueError(T('pmset 설정에 실패했습니다.', 'pmset did not accept the change.'))
        state['on'] = True
        last_reason = ''
    elif not want and state.get('on'):
        set_state(False)
        state['on'] = False
        last_reason = reason or T('모든 요청이 끝났어요', 'nothing needs it any more')
    if want:
        deadline = max(v['until'] for v in state['leases'].values())
        current = state.get('failsafe_until')
        if not isinstance(current, (int, float)) or deadline < current or deadline - current > 60:
            _kill_failsafe(state)
            state['failsafe'] = _start_failsafe(max(1, deadline - now))
            state['failsafe_until'] = deadline
    else:
        _kill_failsafe(state)
    _cache.update(on=bool(state.get('on')), checked=now)
    _save(state)


def acquire(lid, minutes, label='', pid=None, auto=False, now=None):
    """Hold (or renew) lease `lid` for `minutes`; with pid, only while that process lives.
    auto: asked by a hook or an AI, not the user. It is ignored while the user's "Turn off
    all" pause runs; a lease from the user ends that pause. Returns True when held."""
    now = time.time() if now is None else now
    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not 1 <= minutes <= MAX_MINUTES:
        raise ValueError(T(f'1~{MAX_MINUTES}분 사이로 정해 주세요.', f'Choose 1 to {MAX_MINUTES} minutes.'))
    if not isinstance(lid, str) or not 1 <= len(lid) <= 80:
        raise ValueError('lease id')
    if pid is not None and (type(pid) is not int or not _alive(pid)):
        raise ValueError(T('작업 프로세스를 찾지 못했습니다.', 'The job process is not running.'))
    if not supported():
        raise ValueError(T('이 Mac에서는 쓸 수 없습니다.', 'Not available on this Mac.'))
    if not ready():
        raise ValueError(T('먼저 설정 → 일반에서 "깨어 있기 설정"을 한 번 해 주세요.',
                           'Set it up once first: Settings → General → Set up keep awake.'))
    reason = veto()
    if reason:
        raise ValueError(T(f'켜지 않았습니다: {reason}', f'Not turned on: {reason}'))
    with _lock:
        state = _load()
        paused = state.get('paused_until') or 0
        if auto and paused > now:
            return False
        if not auto:
            state['paused_until'] = None
        state['leases'][lid] = dict(label=str(label or lid)[:40], until=now + int(round(minutes * 60)),
                                    pid=pid, since=state['leases'].get(lid, {}).get('since', now))
        _reconcile(state, now)
    return True


def release(lid, now=None):
    """Give lease `lid` back (fine if it is not held)."""
    now = time.time() if now is None else now
    with _lock:
        state = _load()
        if state['leases'].pop(lid, None) is None and not state.get('on'):
            return False
        _reconcile(state, now)
        return True


def start(minutes, now=None):
    """The menu's 1 h / 2 h / 4 h: the user's own lease."""
    acquire('manual', minutes, T('직접', 'You'), now=now)
    return status(now)


def off_all(reason='', pause=False, force=False, now=None):
    """End every lease. pause: also ignore automatic leases for a while (the user's "Turn off
    all"). force: turn the setting off even if something else turned it on."""
    now = time.time() if now is None else now
    global last_reason
    with _lock:
        state = _load()
        had = bool(state['leases']) or state.get('on')
        state['leases'] = {}
        if pause:
            state['paused_until'] = now + PAUSE
        if force and not state.get('on') and actual():
            set_state(False)
            had = True
        _reconcile(state, now, reason)
        if had:
            last_reason = reason
        return bool(had)


def stop(reason='', force=False):
    """Turn everything off (the app quits, or the user's Turn off)."""
    return off_all(reason, pause=False, force=force)


def resume_auto(now=None):
    with _lock:
        state = _load()
        state['paused_until'] = None
        _save(state)


def check(now=None):
    """Run every few seconds by the app: deadlines, finished jobs and the battery. Returns the
    reason it turned off, or ''."""
    now = time.time() if now is None else now
    with _lock:
        state = _load()
        if not state['leases'] and not state.get('on'):
            return ''
        reason = veto()
        if reason:
            state['leases'] = {}
        was_on = state.get('on')
        _reconcile(state, now, reason or T('시간이 다 됐어요', 'time is up'))
        return last_reason if was_on and not state.get('on') else ''


def startup(now=None):
    """When the app starts: forget leases the Mac no longer has (it restarted, which resets
    the setting), and end ones that ran out while the app was not running."""
    now = time.time() if now is None else now
    with _lock:
        state = _load()
        if not state['leases'] and not state.get('on'):
            return
        if not actual():
            state['leases'], state['on'] = {}, False
            _kill_failsafe(state)
            _save(state)
        else:
            check(now)


def status(now=None):
    """For the menu, the settings window and the AIs (pmset is read at most every 5 s)."""
    now = time.time() if now is None else now
    state = _load()
    with _lock:
        if now - _cache['checked'] > 5:
            value = actual()
            _cache.update(on=bool(value), checked=now)
        if _cache['ready'] is None or now - _cache.get('ready_checked', 0) > (30 if _cache['ready'] else 5):
            _cache.update(ready=ready(), ready_checked=now)
    leases = sorted((dict(id=k, label=v.get('label', k), left=max(0, int(v['until'] - now)),
                          job=v.get('pid') is not None)
                     for k, v in state['leases'].items() if _active(v, now)), key=lambda x: -x['left'])
    paused = max(0, int((state.get('paused_until') or 0) - now))
    return dict(supported=supported(), ready=bool(_cache['ready']), on=bool(_cache['on']),
                ours=bool(state.get('on')), left=max([x['left'] for x in leases], default=0),
                leases=leases, paused=paused, reason=last_reason)


def describe(now=None):
    """One line for the AIs (awake_status, get_expression)."""
    s = status(now)
    if not s['supported']:
        return 'Keep awake: not available on this Mac.'
    if not s['ready']:
        return 'Keep awake: not set up (Settings > General > Keep awake).'
    if not s['on']:
        line = 'Keep awake: off (the Mac sleeps normally when the lid closes).'
    else:
        held = ', '.join(f"{x['label']} {x['left'] // 60} min" for x in s['leases'])
        line = 'Keep awake: ON, the Mac stays awake with the lid closed' + (f' ({held}).' if held else
                                                                             ' (turned on outside AI Face).')
    if s['paused']:
        line += f" Automatic keep awake is paused for {s['paused'] // 60} more min (the user turned it off)."
    return line
