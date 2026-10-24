# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Backs up and checks the per-module data files (`<modules_dir>/<id>.db`).

Each module keeps its structured data in its own small SQLite file (decision
0091), so none of it is in the main database snapshot. Every file is copied
with `VACUUM INTO`, like the main database, so a module writing in WAL mode
never leaves a torn copy. The mirror keeps the latest copy of each file under
`<backup-root>/modules/`; it is taken moments after the main snapshot, not in
the same transaction.
"""
import json
import re
import sqlite3
from pathlib import Path
from urllib.parse import quote

# The same charset the server accepts as a module id, so a stray file is never mirrored.
_FILE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}\.db$")


def module_files(modules_dir):
    directory = Path(modules_dir)
    if not directory.is_dir():
        return []
    return sorted(
        path for path in directory.iterdir() if path.is_file() and _FILE_NAME.match(path.name)
    )


def _vacuum_into(source, dest):
    uri = f"file:{quote(str(source.resolve()), safe='/')}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        conn.execute("VACUUM INTO ?", (str(dest),))
    finally:
        conn.close()


def backup_modules(modules_dir, backup_root):
    dest_dir = Path(backup_root, "modules")
    sources = module_files(modules_dir)
    copied, failed = [], []
    if sources:
        dest_dir.mkdir(parents=True, exist_ok=True)
    for source in sources:
        dest = dest_dir / source.name
        partial = dest_dir / f".{source.name}.partial"
        try:
            partial.unlink(missing_ok=True)
            _vacuum_into(source, partial)
            partial.replace(dest)
            copied.append(source.name)
        except sqlite3.Error as error:
            failed.append(f"{source.name}: {error}")
        finally:
            partial.unlink(missing_ok=True)
    return {"total": len(sources), "copied": copied, "failed": failed}


def expected_module_files(db_path):
    """File names of the installed modules the main database says keep data.

    A module keeps a file only with a `data` section and an approved `data.store`.
    A snapshot from before the module tables existed expects none.
    """
    conn = sqlite3.connect(f"file:{quote(str(Path(db_path).resolve()), safe='/')}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT id, data_schema, approved_host_capabilities FROM installed_modules"
        ).fetchall()
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()
    names = []
    for module_id, data_schema, approved in rows:
        try:
            has_data = json.loads(data_schema) is not None
            approved_store = "data.store" in json.loads(approved)
        except (TypeError, ValueError):
            continue
        if has_data and approved_store:
            names.append(f"{module_id}.db")
    return sorted(names)


def check_modules(backup_root, restored_db=None):
    """Opens every mirrored file on its own and runs `PRAGMA integrity_check`.

    With `restored_db`, also reports the files the installed modules should have had.
    """
    verified, broken = [], []
    for path in module_files(Path(backup_root, "modules")):
        conn = sqlite3.connect(f"file:{quote(str(path.resolve()), safe='/')}?mode=ro", uri=True)
        try:
            result = conn.execute("PRAGMA integrity_check").fetchone()[0]
        except sqlite3.DatabaseError as error:
            result = f"unreadable: {error}"
        finally:
            conn.close()
        (verified if result == "ok" else broken).append((path.name, result))
    missing = []
    if restored_db is not None:
        mirrored = {path.name for path in module_files(Path(backup_root, "modules"))}
        missing = [name for name in expected_module_files(restored_db) if name not in mirrored]
    return {"verified": [n for n, _ in verified], "broken": broken, "missing": missing}
