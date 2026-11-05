#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Nightly backup, restore drill and status file; the `backup` compose profile runs this.

The logic lives in scripts/lib/backup_nightly.py; this is only the entry point.

    python3 scripts/backup-nightly.py --backup-root /backup --status-dir /status
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from backup_nightly import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
