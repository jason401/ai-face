"""App-owned checkout of the update channel (stable, or main for beta) -> tests -> complete signed candidate -> transactional install.
Never changes the developer checkout. Runtime code is sealed in the installed bundle.
Like AI Illuminati: checks run by themselves, but a new version is installed only after the
user clicks "Update now" (install=True).
"""
import fcntl
import importlib.util
import json
import shutil
import signal
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

BRANCH = 'stable'         # the default update channel
CHANNELS = ('stable', 'main')   # main is the beta channel: what the AIs push before stable
REPOSITORY = 'https://github.com/jason401/ai-face.git'
TARGET = Path('/Applications/AI Face.app')
EVERY = 3 * 3600          # seconds between checks
RETRY = 10 * 60           # when busy, try again this soon
FIRST = 60                # first check this long after the app starts
AI_QUIET = 10 * 60        # an AI changed the face this recently: the user is probably chatting

_lock = threading.Lock()   # one update at a time
_running = False
_progress = None
_progress_lock = threading.RLock()
STEPS = ('fetch', 'test', 'build', 'install')
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


def channel():
    """The branch updates come from: 'stable' (default) or 'main' (beta, for testing)."""
    name = face_modes.load_settings().get('update_channel', BRANCH)
    return name if name in CHANNELS else BRANCH


def channel_label(name):
    return T('베타(main)', 'beta (main)') if name == 'main' else name


def set_channel(name):
    """Switches the channel. What the other channel found no longer applies."""
    if name not in CHANNELS:
        raise ValueError(T('업데이트 채널이 올바르지 않습니다.', 'Invalid update channel.'))
    if name == channel():
        return
    face_modes.save_settings(update_channel=name)
    save_state(result='', detail='', next='', changes=[], failed=None, want_install=False)


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



def progress_step(stage):
    """Live UI telemetry only; never controls the installation transaction."""
    global _progress
    now = time.time()
    with _progress_lock:
        if _progress is None:
            _progress = dict(stage=stage, started=now, durations={}, line='', output_at=now,
                             expected=load_state().get('step_times', {}))
        else:
            previous = _progress['stage']
            _progress['durations'][previous] = max(0, now - _progress['started'])
            _progress.update(stage=stage, started=now, line='', output_at=now)
            if stage == 'install':
                save_state(step_times=dict(_progress['durations']))


def progress_output(text):
    lines = text.strip().splitlines()
    if lines:
        with _progress_lock:
            if _progress is not None:
                _progress.update(line=lines[-1][-300:], output_at=time.time())


def progress_status():
    with _progress_lock:
        if _progress is None:
            return None
        return dict(_progress, durations=dict(_progress['durations']),
                    expected=dict(_progress['expected']))


def finish_progress(result):
    global _progress
    with _progress_lock:
        if _progress is None:
            return
        outcome = result.get('result')
        if outcome in ('failed', 'error', 'waiting'):
            _progress.update(failed=outcome in ('failed', 'error'), waiting=outcome == 'waiting',
                             stopped=time.time())
        elif outcome == 'installing':
            durations = dict(_progress['durations'])
            durations[_progress['stage']] = max(0, time.time() - _progress['started'])
            save_state(step_times=durations)
        else:
            _progress = None


def _run_logged(args, root, timeout=1200, env=None):
    """Keep bounded output and live last-line telemetry, including commands without newlines."""
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(args, cwd=str(root), stdout=output, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, env=env, start_new_session=True)
        deadline = time.monotonic() + timeout
        seen = 0
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, timeout)
                try:
                    process.wait(timeout=min(0.25, remaining))
                except subprocess.TimeoutExpired:
                    pass
                size = os.fstat(output.fileno()).st_size
                if size != seen:
                    tail = os.pread(output.fileno(), min(size, 4096), max(0, size - 4096))
                    progress_output(tail.decode('utf-8', errors='replace'))
                    seen = size
                if process.poll() is not None:
                    return process.returncode == 0, os.pread(
                        output.fileno(), min(size, 2000), max(0, size - 2000)).decode('utf-8', errors='replace')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


def run_tests(root):
    """The project's own tests (Python and the firmware simulator). Returns (ok, output)."""
    return _run_logged([sys.executable, '-u', '-m', 'unittest', 'discover', '-s', 'tests'], root,
                       env={k: v for k, v in os.environ.items() if not k.startswith('AIFACE_')})


def compile_app(root):
    """Stages a complete signed candidate; the running app is not touched."""
    return _run_logged(['/bin/zsh', str(root / 'tools' / 'build_app.sh'), '--stage'], root)


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
            p = subprocess.run(['git', 'clone', '--branch', channel(), '--single-branch',
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


def check(device=None, manual=False, install=False):
    """One check. With install (the user clicked "Update now"), also test, build and install
    the new version. Returns the new state (also saved)."""
    global _running, _progress
    if not _lock.acquire(blocking=False):
        return status()
    _running = True
    with _progress_lock:
        _progress = None
    if install:
        progress_step('fetch')
    try:
        picked = channel()
        result = _check(device, manual, install)
        if channel() != picked:
            # The channel changed while this ran: its result belongs to the other channel.
            # Look again; installing waits for a new "Update now" (set_channel cancelled it).
            install = False
            result = _check(device, manual, False)
        if install and result.get('result') != 'waiting':
            result['want_install'] = False   # done, failed or nothing to install: stop retrying
        finish_progress(result)
        return save_state(**result, checked=int(time.time()))
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        stop = dict(want_install=False) if install else {}   # do not repeat a broken install every RETRY
        finish_progress(dict(result='error'))
        return save_state(result='error', detail=str(exc)[:300], checked=int(time.time()), **stop)
    finally:
        _running = False
        _lock.release()


def request_install(device):
    """"Update now": remembered, so a busy Mac (timer, keep awake...) installs once it is free."""
    save_state(want_install=True)
    return check(device, manual=True, install=True)


def _check(device, manual, install):
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
        return _check_locked(device, manual, install)


def _check_locked(device, manual, install):
    bundle = paths.app_bundle()
    if bundle is not None and bundle != TARGET:
        reason = busy(device, manual=True)
        if reason:
            return dict(result='waiting', detail=reason)
        progress_step('install')
        install_app(bundle)
        return dict(result='installing', detail='')
    root = source_checkout()
    branch = channel()
    head = _out(root, 'rev-parse', '--abbrev-ref', 'HEAD')
    if head not in CHANNELS:
        return dict(result='skipped', detail=f'not on the {channel_label(branch)} branch')
    if _out(root, 'status', '--porcelain', '--untracked-files=normal'):
        return dict(result='skipped', detail=T('업데이트 소스에 로컬 변경이 있음', 'Update source has local changes'))
    p = git(root, 'fetch', '--quiet', 'origin', branch, timeout=120)
    if p.returncode != 0:
        return dict(result='error', detail=T('GitHub에 연결하지 못함', 'could not reach GitHub'))
    old, new = _out(root, 'rev-parse', 'HEAD'), _out(root, 'rev-parse', 'FETCH_HEAD')
    switching = head != branch   # the user picked the other channel: the checkout follows it
    running = paths.running_revision()
    if running == new:
        if switching:
            _out(root, 'checkout', '--quiet', '-B', branch, new)
        return dict(result='latest', detail='', current=_short(running))
    if not switching and git(root, 'merge-base', '--is-ancestor', 'HEAD', new).returncode != 0:
        return dict(result='skipped', detail=f'Update source has local commits or {branch} was rewound')
    if running:
        # A build from the other channel (or a local build) may be ahead of this one: never go back.
        def known():
            return git(root, 'cat-file', '-e', running + '^{commit}').returncode == 0
        for other in CHANNELS:
            if not known() and other != branch:
                git(root, 'fetch', '--quiet', 'origin', other, timeout=120)
        if not known():
            return dict(result='skipped', current=_short(running),
                        detail=T('이 맥의 앱은 GitHub에 없는 로컬 빌드예요', 'this Mac runs a local build that is not on GitHub'))
        if git(root, 'merge-base', '--is-ancestor', running, new).returncode != 0:
            label = channel_label(branch)
            return dict(result='skipped', current=_short(running),
                        detail=T(f'이 맥의 앱이 {label}보다 새 버전이에요. {label}이 따라잡으면 업데이트돼요',
                                 f'this Mac already runs a newer version than {label}; it updates once {label} catches up'))
    if not manual and load_state().get('failed') == new:
        return dict(result='failed', detail=load_state().get('detail', ''))
    subjects = _out(root, 'log', '--format=%s', f'{running or old}..{new}').splitlines()[:10]
    if not install:
        return dict(result='available', current=_short(running or old), next=_short(new),
                    changes=subjects, detail='')
    reason = busy(device, manual=manual)
    if reason:
        return dict(result='waiting', detail=reason)
    if switching:
        _out(root, 'checkout', '--quiet', '-B', branch, new)
    else:
        _out(root, 'merge', '--ff-only', '--quiet', new)
    try:
        progress_step('test')
        ok, log = run_tests(root)
        progress_output(log)
        if ok:
            progress_step('build')
            ok, log = compile_app(root)
            progress_output(log)
    except (OSError, subprocess.SubprocessError) as exc:   # timed out or could not start
        ok, log = False, str(exc)[-2000:]
    if not ok:
        if switching:   # back to the branch and commit the running app came from
            git(root, 'checkout', '--quiet', '--force', '-B', head, old)
        else:
            git(root, 'reset', '--hard', '--quiet', old)
        return dict(result='failed', failed=new, current=_short(running or old),
                    detail='New version failed tests or build; keeping the running app', log=log)
    # Building can take minutes: do not interrupt work started since the first check.
    reason = busy(device, manual=manual)
    if reason:
        return dict(result='waiting', detail=reason)
    save_state(result='installing', previous=_short(running or old), current=_short(new),
               changes=subjects, failed=None, detail='')
    progress_step('install')
    install_app(root)
    return dict(result='installing', detail='')


def status():
    s = load_state()
    return dict(progress=progress_status(), enabled=enabled(), channel=channel(), running=_running, result=s.get('result', ''), detail=s.get('detail', ''),
                checked=s.get('checked', 0), current=s.get('current', ''), previous=s.get('previous', ''),
                next=s.get('next', ''), installed=s.get('installed', 0), changes=s.get('changes', []),
                want_install=bool(s.get('want_install')))


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
        if not enabled() and not load_state().get('want_install') \
                and (paths.app_bundle() is None or paths.app_bundle() == TARGET):
            wait = RETRY
            continue
        # A new version is only looked for; it is installed when the user asked ("Update now").
        install = bool(load_state().get('want_install'))
        result = check(device, manual=install, install=install).get('result')
        wait = RETRY if result in ('waiting', 'error') else EVERY
