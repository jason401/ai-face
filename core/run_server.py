#!/usr/bin/env python3
"""Entry point the macOS app runs: the controller server (aiface.server)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from aiface.server import main  # noqa: E402

if __name__ == '__main__':
    main()
