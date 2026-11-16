# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Hanging up with the network down ends the call on screen at once.

The leave cannot reach the SFU, and the SDK waited 10 s for an answer to it
before the call left the screen. The SFU drops the participant on its own
once it stops hearing from the client.
"""
import time

import e2e_labels as L
from e2e_voice import (_click_channel_row, _wait_for_empty_room,
                       participants_with_mics)

OFFLINE_SECONDS = 3
# Well under the SDK's 10 s wait, with room for a slow runner.
GONE_WITHIN_SECONDS = 5
SFU_FORGETS_WITHIN_SECONDS = 60


def hanging_up_offline_ends_the_call_at_once(client, room_id):
    _click_channel_row(client, L.VOICE_CHANNEL)
    client.wait_for(L.IN_CALL)
    participants_with_mics(room_id, expected=1)
    client.go_offline()
    try:
        time.sleep(OFFLINE_SECONDS)
        button = client.wait_for(L.LEAVE_CALL)
        began = time.time()
        client.tap(button["x"], button["y"])
        while client.find(L.LEAVE_CALL) and time.time() - began < 20:
            time.sleep(0.1)
        took = time.time() - began
        client.shot("hung-up-offline")
        assert took < GONE_WITHIN_SECONDS, \
            f"the call stayed on screen {took:.1f}s after hanging up offline"
        print(f"  the call left the screen {took:.1f}s after the tap, with the network down")
    finally:
        client.go_online()
    parts = _wait_for_empty_room(room_id, SFU_FORGETS_WITHIN_SECONDS)
    assert not parts, f"the SFU still lists {len(parts)} participant(s) after the hang-up"
    print("  and the SFU let the participant go on its own")
