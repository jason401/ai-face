#!/usr/bin/python3
"""Launch the transactional installer; the running app checks idle again before quitting."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import uuid


def deploy(staged, current, support, restore_login=False):
    helper = staged / 'Contents/Resources/install_app.py'
    updates = support / 'updates'
    updates.mkdir(parents=True, exist_ok=True, mode=0o700)
    command = ['/usr/bin/python3', '-B', str(helper), '--staged', str(staged),
               '--current', str(current), '--target', '/Applications/AI Face.app',
               '--support', str(support), '--token', str(uuid.uuid4()), '--legacy']
    if restore_login:
        command.append('--restore-login')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PYTHON', 'AIFACE_'))}
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    with (updates / 'install.log').open('ab') as log:
        return subprocess.Popen(command, cwd='/', env=env, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=log, start_new_session=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy', action='store_true')
    parser.add_argument('--restore-login', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    staged = root / 'AI Face.update.app'
    spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install_app.py'))
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    for current in [Path('/Applications/AI Face.app'), root / 'AI Face.app']:
        if installer.app_pids(current):
            # First migration from a legacy server must also respect its busy state.
            import json
            import time
            import urllib.request
            support = Path.home() / 'Library/Application Support/AI Face'
            discovery = json.loads((support / 'controller.json').read_text())
            request = urllib.request.Request(f"http://127.0.0.1:{int(discovery['port'])}/status",
                                             headers={'X-ESP-Token': discovery['token']})
            with urllib.request.urlopen(request, timeout=10) as response:
                state = json.load(response)
            held = state.get('awake', {})
            timer = json.loads((support / 'settings.json').read_text()).get('timer') or {}
            if held.get('on') or held.get('leases') or state.get('flashing') or timer.get('end', 0) > time.time():
                raise RuntimeError('Installation postponed: timer, keep awake, or firmware operation is active')
            view_request = urllib.request.Request(f"http://127.0.0.1:{int(discovery['port'])}/view",
                                                   headers={'X-ESP-Token': discovery['token']})
            with urllib.request.urlopen(view_request, timeout=10) as response:
                view = json.load(response)
            if view.get('calendar_pending'):
                raise RuntimeError('Installation postponed: Calendar approval is pending')
            # New apps perform a stronger atomic check through /install/prepare on quit.
            process = deploy(staged, current, support, args.restore_login)
            print('Installer started:', process.pid)
            return
    subprocess.run(['/usr/bin/open', '-n', str(staged)], check=True)


if __name__ == '__main__':
    main()
