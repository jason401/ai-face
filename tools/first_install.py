#!/usr/bin/python3
"""Put a freshly built AI Face.update.app into Applications on this Mac (first installation).

- No AI Face in Applications: copy it there and open it.
- An AI Face signed by another identity (for example the ready-made v2.1.0 download, signed on
  the maintainer's Mac): quit it, move it to the Trash, then install this Mac's own build. From
  then on the app updates itself from the stable branch with this Mac's signing identity.
- An AI Face already signed by this Mac's identity: leave it alone. It updates itself
  (Settings → General → Check now, then Update now).

Settings, history and photos in ~/Library/Application Support/AI Face are never touched.
"""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import install_app  # noqa: E402  (app_pids, requirement, verify)


def same_signer(app, staged):
    try:
        install_app.verify(app, install_app.requirement(staged), resources=False)
        return True
    except (subprocess.CalledProcessError, ValueError, StopIteration, OSError):
        return False


def quit_app(app):
    """Ask a running copy to quit (its own helper, else SIGTERM), then wait for it."""
    for pid in install_app.app_pids(app):
        bridge = Path(app) / 'Contents/Helpers/InstallBridge'
        done = bridge.is_file() and subprocess.run([str(bridge), str(pid), str(app)],
                                                   capture_output=True).returncode == 0
        if not done:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 15
    while install_app.app_pids(app):
        if time.monotonic() > deadline:
            raise RuntimeError('AI Face did not quit. Quit it from its menu, then run the installer again.')
        time.sleep(0.2)


def to_trash(app, trash):
    trash.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime('%Y%m%d-%H%M%S')
    target = trash / f'AI Face (replaced {stamp}).app'
    shutil.move(str(app), str(target))
    return target


def install(staged, target, trash, open_app=True):
    staged, target = Path(staged), Path(target)
    if not (staged / 'Contents/Info.plist').is_file():
        raise RuntimeError(f'No built app at {staged}')
    install_app.verify(staged, install_app.requirement(staged))   # complete and signed
    if target.is_symlink():
        raise RuntimeError('Refusing a symbolic link in place of AI Face.app')
    if target.exists():
        if same_signer(target, staged):
            print('AI Face is already installed with this Mac\'s signing identity and was not changed.')
            print('It updates itself: Settings → General → Check now, then Update now.')
            return 'kept'
        print('Replacing the AI Face that was signed on another Mac (settings and history stay).')
        quit_app(target)
        moved = to_trash(target, trash)
        print(f'Previous app moved to the Trash: {moved.name}')
    work = target.parent / ('.ai-face-first-install-' + str(os.getpid()))
    shutil.rmtree(work, ignore_errors=True)
    try:
        subprocess.run(['/usr/bin/ditto', str(staged), str(work)], check=True)
        install_app.verify(work, install_app.requirement(staged))
        os.rename(work, target)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f'Installed {target}')
    if open_app:
        subprocess.run(['/usr/bin/open', str(target)], check=False)
    return 'installed'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument('--staged', type=Path, default=root / 'AI Face.update.app')
    parser.add_argument('--target', type=Path, default=Path('/Applications/AI Face.app'))
    parser.add_argument('--trash', type=Path, default=Path.home() / '.Trash')
    parser.add_argument('--no-open', action='store_true')
    args = parser.parse_args()
    try:
        install(args.staged, args.target, args.trash, open_app=not args.no_open)
    except Exception as exc:   # one clear line for the Terminal window
        print(f'Installation stopped: {exc}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
