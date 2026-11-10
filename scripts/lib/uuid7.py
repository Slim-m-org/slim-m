# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A client-generated UUIDv7 id, matching what a real slim-m client sends.

CLAUDE.md's architecture summary says identity is UUIDv7 and durable writes
are keyed by a client-generated one, and the server's `Id` newtype is UUIDv7
- but these scripts had been minting plain, timestamp-free `uuid.uuid4()`
ids for every seeded message. The server accepts either (ordering comes
from the per-channel `seq` column, never the id), so nothing broke, but the
point of a realism script is to look like real traffic, and a real client
never sends this.

Python's stdlib grew `uuid.uuid7()` in 3.14, the version CI pins here, so
this prefers that where it exists and only falls back to a hand-rolled
RFC 9562 layout - a 48-bit big-endian millisecond timestamp, a version
nibble of 7, the RFC 4122 variant bits, and a random remainder - for a
contributor running these scripts under an older interpreter.
"""
import os
import time
import uuid


def uuid7():
    """One UUIDv7 id, as a string."""
    if hasattr(uuid, "uuid7"):
        return str(uuid.uuid7())
    return str(_build())


def _build(now_ms=None):
    """The hand-rolled fallback, taking an explicit clock so tests can drive
    it without depending on real wall-clock timing."""
    ts_ms = int(time.time() * 1000) if now_ms is None else now_ms
    payload = bytearray(ts_ms.to_bytes(6, "big") + os.urandom(10))
    payload[6] = 0x70 | (payload[6] & 0x0F)
    payload[8] = 0x80 | (payload[8] & 0x3F)
    return uuid.UUID(bytes=bytes(payload))
