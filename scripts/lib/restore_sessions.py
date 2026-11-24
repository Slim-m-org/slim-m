# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Signs everyone out of a restored database, so a snapshot cannot revive a revoked login."""
import sqlite3
import time

# Each statement is skipped when the snapshot predates its table.
_STATEMENTS = (
    "DELETE FROM access_tokens",
    "DELETE FROM ws_tickets",
    "DELETE FROM dropped_refresh_tokens",
    "UPDATE refresh_tokens SET revoked_at = :now WHERE revoked_at IS NULL",
    "UPDATE sessions SET revoked_at = :now WHERE revoked_at IS NULL",
)


_LIVE_BOTS = (
    "SELECT DISTINCT t.name FROM bot_tokens t JOIN sessions s ON s.id = t.session_id "
    "WHERE t.revoked_at IS NULL AND s.revoked_at IS NULL ORDER BY t.name"
)


def revoke_all(database, now_ms=None):
    """Revokes every session and returns the names of the bots whose token that ended."""
    now = now_ms if now_ms is not None else int(time.time() * 1000)
    conn = sqlite3.connect(str(database))
    try:
        try:
            bots = [row[0] for row in conn.execute(_LIVE_BOTS)]
        except sqlite3.OperationalError as error:
            if "no such table" not in str(error):
                raise
            bots = []
        for statement in _STATEMENTS:
            try:
                conn.execute(statement, {"now": now})
            except sqlite3.OperationalError as error:
                if "no such table" not in str(error):
                    raise
        conn.commit()
        return bots
    finally:
        conn.close()
