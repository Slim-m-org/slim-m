#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Restores a scripts/backup.py backup into a server data directory.

The logic and its documentation live in scripts/lib/restore_lib.py, which
scripts/lib/test_restore_lib.py exercises directly; this file is only the
command-line entry point.

    python3 scripts/restore.py --backup-root /path/to/backups --data-dir /data
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from restore_lib import parse_args, run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(parse_args(sys.argv[1:])))
