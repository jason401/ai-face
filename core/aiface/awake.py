"""Keep awake with the lid closed, turned on by hand for a set time.

macOS only lets a closed MacBook stay awake through `pmset -a disablesleep 1`, which needs
root. "Set up Keep Awake.command" (tools/) installs one sudoers rule that allows exactly
`/usr/bin/pmset -a disablesleep 0` and `... 1` without a password; nothing else.

Rules (from the design guide):
- Off is the default. On only lasts until a deadline; every way out turns it off:
  the app's own check (deadline, low battery, heat), quitting the app, and a small
  detached "turn off at the deadline" process that survives a crash of the app.
  A restart of the Mac resets it too.
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
STATE = paths.DATA / 'awake.json'        # {until, started, failsafe}: only while it is on
CHOICES = (60, 120, 240)                 # minutes offered in the menu
MAX_MINUTES = 480
BATTERY_FLOOR = 20                       # % on battery power: turn off at or below

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
        return data if isinstance(data, dict) and isinstance(data.get('until'), (int, float)) else None
    except (OSError, ValueError):
        return None


def _save(data):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temp = STATE.with_suffix('.tmp')
    temp.write_text(json.dumps(data))
    temp.replace(STATE)


def _kill_failsafe(state):
    pid = (state or {}).get('failsafe')
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


def start(minutes, now=None):
    """Stay awake for `minutes` (replaces a running period)."""
    global last_reason
    now = time.time() if now is None else now
    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not 1 <= minutes <= MAX_MINUTES:
        raise ValueError(T(f'1~{MAX_MINUTES}분 사이로 정해 주세요.', f'Choose 1 to {MAX_MINUTES} minutes.'))
    if not supported():
        raise ValueError(T('이 Mac에서는 쓸 수 없습니다.', 'Not available on this Mac.'))
    if not ready():
        raise ValueError(T('먼저 설정 → 일반에서 "깨어 있기 설정"을 한 번 해 주세요.',
                           'Set it up once first: Settings → General → Set up keep awake.'))
    reason = veto()
    if reason:
        raise ValueError(T(f'켜지 않았습니다: {reason}', f'Not turned on: {reason}'))
    seconds = int(round(minutes * 60))
    with _lock:
        old = _load()
        _kill_failsafe(old)
        if not set_state(True):
            set_state(False)
            raise ValueError(T('pmset 설정에 실패했습니다.', 'pmset did not accept the change.'))
        _save(dict(until=now + seconds, started=(old or {}).get('started', now), failsafe=_start_failsafe(seconds)))
        last_reason = ''
        _cache.update(on=True, checked=now)
    return status(now)


def stop(reason='', force=False):
    """Turn off what this app turned on. force (the user's "Turn off"): also when something
    else (another keep-awake app, a manual pmset) turned it on."""
    global last_reason
    with _lock:
        state = _load()
        if state is None and not (force and actual()):
            return False
        _kill_failsafe(state)
        try:
            STATE.unlink()
        except OSError:
            pass
        set_state(False)
        _cache.update(on=False, checked=time.time())
        last_reason = reason
        return True


def check(now=None):
    """Run every few seconds by the app: deadline and battery. Returns the reason it turned
    off, or ''."""
    now = time.time() if now is None else now
    state = _load()
    if state is None:
        return ''
    if now >= state['until']:
        reason = T('시간이 다 됐어요', 'time is up')
    else:
        reason = veto()
    if reason:
        stop(reason)
    return reason


def startup(now=None):
    """When the app starts: forget a period the Mac no longer has (it restarted, which resets
    the setting), and end one that ran out while the app was not running."""
    now = time.time() if now is None else now
    state = _load()
    if state is None:
        return
    if not actual():
        _kill_failsafe(state)
        try:
            STATE.unlink()
        except OSError:
            pass
    else:
        check(now)


def status(now=None):
    """For the menu and the settings window (cheap: pmset is read at most every 5 s)."""
    now = time.time() if now is None else now
    state = _load()
    with _lock:
        if now - _cache['checked'] > 5:
            value = actual()
            _cache.update(on=bool(value), checked=now)
        if _cache['ready'] is None or now - _cache.get('ready_checked', 0) > (30 if _cache['ready'] else 5):
            _cache.update(ready=ready(), ready_checked=now)
    left = max(0, int(state['until'] - now)) if state else 0
    return dict(supported=supported(), ready=bool(_cache['ready']), on=bool(_cache['on']),
                ours=state is not None, left=left, reason=last_reason)
