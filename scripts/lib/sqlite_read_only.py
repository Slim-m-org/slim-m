# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Opens a SQLite database read-only through a URI built from a quoted path."""

import sqlite3
from pathlib import Path
from urllib.parse import quote


def read_only_uri(path):
    """The `file:` URI for [path] with `mode=ro`; a `?` or `#` in the path stays part of the name."""
    return f"file:{quote(str(Path(path).resolve()), safe='/')}?mode=ro"


def connect(path):
    return sqlite3.connect(read_only_uri(path), uri=True)
