"""Automatic updates: the app checks GitHub (the project's `origin`, a public repository, so
no login) when it starts and every few hours, and installs a newer version by itself.

Safe order: fetch -> fast-forward -> tests -> compile the new app next to the running one.
Only when all of that passes is the app swapped and restarted (tools/build_app.sh --prebuilt,
run detached because it quits this server). Anything failing puts the folder back where it
was and the running app stays. Skipped when this Mac has its own changes or commits, and
postponed while the user or an AI is busy (timer, keep awake, a calendar question, a face
an AI set a few minutes ago).
"""
import json
import os
import subprocess
import sys
import threading
import time

from . import awake
from . import calendar_access
from . import moods as face_modes
from . import paths
from .i18n import T

BRANCH = 'main'
EVERY = 3 * 3600          # seconds between checks
RETRY = 10 * 60           # when busy, try again this soon
FIRST = 60                # first check this long after the app starts
AI_QUIET = 10 * 60        # an AI changed the face this recently: the user is probably chatting

_lock = threading.Lock()   # one update at a time
_running = False


def state_path():
    return paths.DATA / 'update.json'


def load_state():
    try:
        data = json.loads(state_path().read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(**changes):
    data = load_state()
    data.update(changes)
    state_path().parent.mkdir(parents=True, exist_ok=True)
    temp = state_path().with_name(state_path().name + f'.{os.getpid()}.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    temp.replace(state_path())
    return data


def enabled():
    return face_modes.load_settings().get('auto_update', True)


def set_enabled(on):
    if type(on) is not bool:
        raise ValueError(T('자동 업데이트 값이 올바르지 않습니다.', 'Invalid automatic update value.'))
    face_modes.save_settings(auto_update=on)


def git(root, *args, timeout=60):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', LC_ALL='C',
               PATH=os.pathsep.join(['/usr/bin', '/bin', '/opt/homebrew/bin', '/usr/local/bin']))
    return subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True,
                          timeout=timeout, stdin=subprocess.DEVNULL, env=env)


def _out(root, *args):
    p = git(root, *args)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[:300])
    return p.stdout.strip()


def run_tests(root):
    """The project's own tests (Python and the firmware simulator). Returns (ok, output)."""
    p = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests'], cwd=str(root),
                       capture_output=True, text=True, timeout=1200, stdin=subprocess.DEVNULL,
                       env={k: v for k, v in os.environ.items() if k != 'AIFACE_TEST_HOME'})
    return p.returncode == 0, (p.stdout + p.stderr)[-2000:]


def compile_app(root):
    """Builds the new app next to the running one (AIFace.new); the running app is not touched."""
    p = subprocess.run(['/bin/zsh', str(root / 'tools' / 'build_app.sh'), '--compile-only'], cwd=str(root),
                       capture_output=True, text=True, timeout=1200, stdin=subprocess.DEVNULL)
    return p.returncode == 0, (p.stdout + p.stderr)[-2000:]


def install_app(root):
    """Swaps in the compiled app and restarts it. Detached: it quits this server too."""
    subprocess.Popen(['/bin/zsh', str(root / 'tools' / 'build_app.sh'), '--prebuilt'], cwd=str(root),
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def busy(device, now=None, manual=False):
    """Why updating now would get in the way ('' when it would not)."""
    now = time.time() if now is None else now
    timer = face_modes.load_settings().get('timer')
    if timer and timer.get('end', 0) > now:
        return T('타이머가 도는 중', 'a timer is running')
    try:
        held = awake.status(now)
        if held.get('ours') or held.get('leases'):
            return T('깨어 있기가 켜져 있음', 'keep awake is on')   # a restart would turn it off
    except OSError:
        pass
    if calendar_access.pending():
        return T('캘린더 확인을 기다리는 중', 'a calendar question is waiting')
    if device is not None and device.flashing:
        return T('보드 펌웨어를 올리는 중', 'the board firmware is being updated')
    if not manual and device is not None and device.owner not in ('', 'user') and now - device.changed < AI_QUIET:
        return T('AI와 대화 중', 'an AI is chatting')
    return ''


def _short(rev):
    return rev[:7]


def check(device=None, manual=False):
    """One check, and the update when there is one. Returns the new state (also saved)."""
    global _running
    if not _lock.acquire(blocking=False):
        return status()
    _running = True
    try:
        return save_state(**_check(device, manual), checked=int(time.time()))
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        return save_state(result='error', detail=str(exc)[:300], checked=int(time.time()))
    finally:
        _running = False
        _lock.release()


def _check(device, manual):
    root = paths.project_root()
    if root is None or not (root / '.git').exists():
        return dict(result='unavailable', detail='')
    if _out(root, 'rev-parse', '--abbrev-ref', 'HEAD') != BRANCH:
        return dict(result='skipped', detail=T(f'{BRANCH} 브랜치가 아님', f'not on the {BRANCH} branch'))
    if _out(root, 'status', '--porcelain', '--untracked-files=no'):
        return dict(result='skipped', detail=T('이 Mac에 아직 커밋하지 않은 변경이 있음',
                                               'this Mac has changes that are not committed'))
    p = git(root, 'fetch', '--quiet', 'origin', BRANCH, timeout=120)
    if p.returncode != 0:
        return dict(result='error', detail=T('GitHub에 연결하지 못함', 'could not reach GitHub'))
    old, new = _out(root, 'rev-parse', 'HEAD'), _out(root, 'rev-parse', 'FETCH_HEAD')
    if old == new:
        return dict(result='latest', detail='', current=_short(old))
    if git(root, 'merge-base', '--is-ancestor', 'HEAD', 'FETCH_HEAD').returncode != 0:
        return dict(result='skipped', detail=T('이 Mac에만 있는 커밋이 있음', 'this Mac has commits GitHub does not'))
    if not manual and load_state().get('failed') == new:
        return dict(result='failed', detail=load_state().get('detail', ''))   # same broken version: wait for a fix
    reason = busy(device, manual=manual)
    if reason:
        return dict(result='waiting', detail=reason)
    subjects = _out(root, 'log', '--format=%s', f'{old}..{new}').splitlines()[:10]
    _out(root, 'merge', '--ff-only', '--quiet', new)
    ok, log = run_tests(root)
    step = T('테스트', 'tests')
    if ok:
        ok, log = compile_app(root)
        step = T('앱 빌드', 'building the app')
    if not ok:
        git(root, 'reset', '--hard', '--quiet', old)   # back to the version that runs now
        return dict(result='failed', failed=new, current=_short(old),
                    detail=T(f'새 버전({_short(new)})의 {step}가 실패해서 지금 버전을 그대로 씀',
                             f'{step} failed for the new version ({_short(new)}); keeping this one'),
                    log=log)
    save_state(result='installing', previous=_short(old), current=_short(new), changes=subjects,
               installed=int(time.time()), announce=True, failed=None, detail='')
    install_app(root)
    return dict(result='installing', detail='')


def status():
    s = load_state()
    return dict(enabled=enabled(), running=_running, result=s.get('result', ''), detail=s.get('detail', ''),
                checked=s.get('checked', 0), current=s.get('current', ''), previous=s.get('previous', ''),
                installed=s.get('installed', 0), changes=s.get('changes', []))


def announce(device):
    """After an update restarted the app: say so once (message and a happy face)."""
    s = load_state()
    if not s.get('announce'):
        return
    save_state(announce=False, result='updated')
    preset = next((m for m in face_modes.emotions() if m['id'] == 'happy'), None)
    with device.lock:
        if preset:
            try:
                device.show_emotion(preset, 'user', record=False)
            except (OSError, ValueError, TimeoutError):
                pass
        device.message = T('새 버전으로 업데이트했어요: ', 'Updated to the new version: ') + '; '.join(s.get('changes', [])[:3])


def watch(device, stop):
    """The background loop the server starts."""
    try:
        announce(device)
    except OSError:
        pass
    wait = FIRST
    while not stop.wait(wait):
        if not enabled():
            wait = RETRY
            continue
        result = check(device).get('result')
        wait = RETRY if result in ('waiting', 'error') else EVERY
