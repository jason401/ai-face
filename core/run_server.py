#!/usr/bin/env python3
"""Entry point the macOS app runs: the controller server (aiface.server)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from aiface.server import main  # noqa: E402

if __name__ == '__main__':
    # If the GUI crashes, do not leave an orphan server holding USB or keep-awake leases.
    import os
    import signal
    import threading
    def watch_parent():
        parent = int(os.environ.get('AIFACE_APP_PID', '0'))
        if not parent:
            return
        while os.getppid() == parent:
            threading.Event().wait(2)
        os.kill(os.getpid(), signal.SIGTERM)
    threading.Thread(target=watch_parent, daemon=True).start()
    main()
