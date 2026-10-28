"""App-owned stable checkout -> tests -> complete signed candidate -> transactional install.
Never changes the developer checkout. Runtime code is sealed in the installed bundle.
"""
import fcntl
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path
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

BRANCH = 'stable'
REPOSITORY = 'https://github.com/jason401/ai-face.git'
TARGET = Path('/Applications/AI Face.app')
EVERY = 3 * 3600          # seconds between checks
RETRY = 10 * 60           # when busy, try again this soon
FIRST = 60                # first check this long after the app starts
AI_QUIET = 10 * 60        # an AI changed the face this recently: the user is probably chatting

_lock = threading.Lock()   # one update at a time
_running = False
_gate = threading.RLock()
_active_requests = 0
_quiescing = False


def request_started():
    global _active_requests
    with _gate:
        if _quiescing:
            return False
        _active_requests += 1
        return True


def request_finished():
    global _active_requests
    with _gate:
        _active_requests -= 1


def prepare_installation(device):
    global _quiescing
    with _gate:
        # The preparation POST is the only permitted in-flight request.
        if _active_requests > 1:
            return T('요청을 처리하는 중', 'A request is still running')
        reason = busy(device, manual=True)
        if not reason:
            _quiescing = True
        return reason


def cancel_installation():
    global _quiescing
    with _gate:
        _quiescing = False


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
                       env={k: v for k, v in os.environ.items() if not k.startswith('AIFACE_')})
    return p.returncode == 0, (p.stdout + p.stderr)[-2000:]


def compile_app(root):
    """Builds the new app next to the running one (AIFace.new); the running app is not touched."""
    p = subprocess.run(['/bin/zsh', str(root / 'tools' / 'build_app.sh'), '--stage'], cwd=str(root),
                       capture_output=True, text=True, timeout=1200, stdin=subprocess.DEVNULL)
    return p.returncode == 0, (p.stdout + p.stderr)[-2000:]


def install_app(root):
    """Installer owns the transaction. Swift checks idle atomically before normal quit."""
    bundle = paths.app_bundle()
    if bundle is None:
        raise RuntimeError('AI Face must be running from a bundle')
    staged = root / 'AI Face.update.app' if root != bundle else bundle
    spec = importlib.util.spec_from_file_location('face_deploy', staged / 'Contents/Resources/deploy_app.py')
    deploy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(deploy)
    process = deploy.deploy(staged, bundle, paths.DATA)
    # Success terminates this server. If preparation/normal quit fails, report it here.
    code = process.wait(timeout=180)
    if code:
        raise RuntimeError('Installer failed; see updates/install.log')
    return process


def source_checkout():
    """Only this private checkout may ever be updated or reset."""
    root = paths.update_source()
    if root.is_symlink() or root.resolve() != root.absolute():
        raise RuntimeError('Update source must not be a symbolic link')
    if not root.exists():
        paths.DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = Path(tempfile.mkdtemp(prefix='source-clone-', dir=paths.DATA))
        try:
            p = subprocess.run(['git', 'clone', '--branch', BRANCH, '--single-branch',
                                REPOSITORY, str(temporary)], capture_output=True, text=True,
                               timeout=180, stdin=subprocess.DEVNULL,
                               env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
            if p.returncode:
                raise RuntimeError(p.stderr.strip()[-1000:])
            temporary.rename(root)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    if _out(root, 'remote', 'get-url', 'origin') != REPOSITORY:
        raise RuntimeError('Unexpected update repository')
    return root


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
    paths.DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    journal = paths.DATA / 'updates/transaction.json'
    if journal.exists():
        transaction = json.loads(journal.read_text())
        if transaction.get('phase') not in ('complete', 'failed'):
            return dict(result='waiting', detail='Installation in progress or interrupted; see updates/transaction.json')
    with (paths.DATA / 'source.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return dict(result='waiting', detail='Another updater is running')
        return _check_locked(device, manual)


def _check_locked(device, manual):
    bundle = paths.app_bundle()
    if bundle is not None and bundle != TARGET:
        reason = busy(device, manual=True)
        if reason:
            return dict(result='waiting', detail=reason)
        install_app(bundle)
        return dict(result='installing', detail='')
    root = source_checkout()
    if _out(root, 'rev-parse', '--abbrev-ref', 'HEAD') != BRANCH:
        return dict(result='skipped', detail=f'not on the {BRANCH} branch')
    if _out(root, 'status', '--porcelain', '--untracked-files=normal'):
        return dict(result='skipped', detail=T('업데이트 소스에 로컬 변경이 있음', 'Update source has local changes'))
    p = git(root, 'fetch', '--quiet', 'origin', BRANCH, timeout=120)
    if p.returncode != 0:
        return dict(result='error', detail=T('GitHub에 연결하지 못함', 'could not reach GitHub'))
    old, new = _out(root, 'rev-parse', 'HEAD'), _out(root, 'rev-parse', 'FETCH_HEAD')
    running = paths.running_revision()
    if running == new:
        return dict(result='latest', detail='', current=_short(running))
    if git(root, 'merge-base', '--is-ancestor', 'HEAD', new).returncode != 0:
        return dict(result='skipped', detail='Update source has local commits or stable was rewound')
    if running and git(root, 'cat-file', '-e', running + '^{commit}').returncode == 0:
        if git(root, 'merge-base', '--is-ancestor', running, new).returncode != 0:
            return dict(result='skipped', detail='Stable is older than the running app')
    if not manual and load_state().get('failed') == new:
        return dict(result='failed', detail=load_state().get('detail', ''))
    reason = busy(device, manual=manual)
    if reason:
        return dict(result='waiting', detail=reason)
    subjects = _out(root, 'log', '--format=%s', f'{running or old}..{new}').splitlines()[:10]
    _out(root, 'merge', '--ff-only', '--quiet', new)
    ok, log = run_tests(root)
    if ok:
        ok, log = compile_app(root)
    if not ok:
        git(root, 'reset', '--hard', '--quiet', old)
        return dict(result='failed', failed=new, current=_short(running or old),
                    detail='New version failed tests or build; keeping the running app', log=log)
    # Building can take minutes: do not interrupt work started since the first check.
    reason = busy(device, manual=manual)
    if reason:
        return dict(result='waiting', detail=reason)
    save_state(result='installing', previous=_short(running or old), current=_short(new),
               changes=subjects, failed=None, detail='')
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
    wait = 2 if paths.app_bundle() and paths.app_bundle() != TARGET else FIRST
    while not stop.wait(wait):
        if not enabled() and (paths.app_bundle() is None or paths.app_bundle() == TARGET):
            wait = RETRY
            continue
        result = check(device).get('result')
        wait = RETRY if result in ('waiting', 'error') else EVERY
