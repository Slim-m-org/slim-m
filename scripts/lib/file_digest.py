# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Streams a file through sha256, so a gigabyte attachment never has to fit in
the backup container's memory, for backup_lib.py and restore_drill_lib.py."""
import hashlib
from pathlib import Path

CHUNK_BYTES = 1024 * 1024


def sha256_of_file(path):
    """The hex digest of the file and the number of bytes that were hashed."""
    digest, total = hashlib.sha256(), 0
    with Path(path).open("rb") as handle:
        while chunk := handle.read(CHUNK_BYTES):
            digest.update(chunk)
            total += len(chunk)
    return digest.hexdigest(), total
