# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The directories the voice harness CLIs may read and write; anything else is rejected."""
import os
import tempfile
from pathlib import Path

ROOTS = tuple(
    Path(root).resolve()
    for root in (tempfile.gettempdir(), Path.home(), Path.cwd())
    if root
)
