# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A client whose network drops mid-call comes back into it on its own.

Split out of e2e_voice.py for its review budget; it imports the helpers
there rather than duplicating them.
"""
import os
import time

import e2e_labels as L
from e2e_voice import (_tap_label, audio_actually_arrives, join_call,
                       participants_with_mics, sfu_participants)

DROP_SECONDS = int(os.environ.get("E2E_DROP_SECONDS", "90"))
EVICTED_GRACE = 3
RECOVERY_SECONDS = int(os.environ.get("E2E_RECOVERY_SECONDS", "90"))


def _timeline(a, b, room_id, seconds):
    """Prints what each side believes once a second-ish, so a failure says who evicted whom."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        parts = sfu_participants(room_id)
        states = ",".join(p["state"] for p in parts)
        a_in = a.find("2 in call") is not None
        b_in = b.find("2 in call") is not None
        print(f"    t={int(time.time() % 1000)} sfu=[{states}] "
              f"alice sees 2={a_in} bob sees 2={b_in}")
        if len(parts) == 2 and a_in and b_in:
            return True
        time.sleep(1)
    return False


def _stay_offline_until_evicted(room_id):
    """Seconds spent offline: until the SFU drops alice, then a moment past it.

    The drop has to outlast the SFU's own patience for the case to be the one
    that matters, a seat already given away, so it waits on that rather than
    on a clock that is only ever too long or too short. DROP_SECONDS is the
    most it will wait.
    """
    began = time.time()
    while time.time() - began < DROP_SECONDS:
        if len(sfu_participants(room_id)) < 2:
            time.sleep(EVICTED_GRACE)
            break
        time.sleep(0.25)
    return time.time() - began


def rejoins_after_a_network_drop(a, b, room_id, channel=L.VOICE_CHANNEL):
    """Alice loses her network for a while; once it returns she is back with no tap.

    Asserts audio both ways afterwards, since a reconnect that restores the
    roster and leaves the media path dead looks healthy on a roster.
    """
    join_call(a, b, room_id, channel)
    try:
        a.go_offline()
        held = _stay_offline_until_evicted(room_id)
        print(f"  alice was offline for {held:.0f}s, until the SFU let her go")
        a.go_online()
        print("  alice is back online, waiting for the call to recover")
        ok = _timeline(a, b, room_id, RECOVERY_SECONDS)
        a.shot("after-network-drop")
        b.shot("after-network-drop-peer")
        assert ok, "alice never rejoined the call after her network came back"
        parts = participants_with_mics(room_id)
        assert len(parts) == 2, f"SFU has {len(parts)} participants, expected 2"
        audio_actually_arrives(a, b, room_id)
        print("  alice is back in the call and audio flows both ways")
    finally:
        a.go_online()
        for c in (a, b):
            if c.find(L.LEAVE_CALL):
                _tap_label(c, L.LEAVE_CALL, settle=4)
