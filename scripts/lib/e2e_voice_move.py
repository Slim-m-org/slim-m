# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A moderator moves someone to another call and they hear her there.

Checked at the SFU as well as on screen: the moved client has to end up in the
destination room by itself, with nobody left behind in the source room.
"""
import time

import e2e_audio
import e2e_voice_ui as ui
from e2e_voice import join_call, participants_with_mics, sfu_participants
from e2e_voice_rejoin import _click_channel_row

DESTINATION = "annex"
HEARD_ABOVE_DB = -45.0
MEASURE_SECONDS = 3
FOLLOW_TIMEOUT = 30


def _pick_destination(client):
    """Choose the destination in the open list, not the rail row of the same name."""
    deadline = time.time() + 10
    while time.time() < deadline:
        for n in client.nodes():
            if n["t"] == DESTINATION and n["x"] > 300:
                client.tap(n["x"], n["y"])
                time.sleep(1.5)
                return
        time.sleep(0.5)
    seen = [(n["t"], n["x"], n["y"]) for n in client.nodes()]
    raise AssertionError(f"{client.name}: no {DESTINATION!r} in the Move to list: {seen}")


def _wait_for_room(room, identity, timeout=FOLLOW_TIMEOUT):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if any(p["identity"] == identity for p in sfu_participants(room)):
            return
        time.sleep(1)
    raise AssertionError(f"{identity} never reached {room}")


def moving_a_member_takes_their_call_with_them(a, b, admin, lounge_room, bob_id):
    with e2e_audio.installed(b):
        _move_and_listen(a, b, admin, lounge_room, bob_id)


def _move_and_listen(a, b, admin, lounge_room, bob_id):
    admin.call("POST", "/channels", {"name": DESTINATION, "kind": "voice"})
    annex = admin.channel_named(DESTINATION)
    annex_room = f"channel-{annex['id']}"
    join_call(a, b, lounge_room)
    try:
        ui.open_tile_menu(a, "Bob")
        a.click("Move to...", settle=1)
        a.wait_for("Move Bob to")
        _pick_destination(a)

        _wait_for_room(annex_room, bob_id)
        b.wait_for("Alice moved you to")
        left = [p["identity"] for p in sfu_participants(lounge_room)]
        assert bob_id not in left, f"bob is still in the source room: {left}"
        print("  bob was moved and joined the destination room on his own")

        _click_channel_row(a, DESTINATION)
        a.click("Switch to this call", settle=1)
        parts = participants_with_mics(annex_room, expected=2)
        assert len(parts) == 2, f"destination has {len(parts)} participants, expected 2"
        probe = e2e_audio.AudioProbe(b)
        probe.wait_for_streams(1)
        alice_id = next(p["identity"] for p in parts if p["identity"] != bob_id)
        stream = ui.stream_for(probe, annex_room, alice_id)
        level = e2e_audio.speech_level(probe.measure(stream, MEASURE_SECONDS), 1)
        print(f"  bob hears alice in the destination at {level:.1f} dB")
        assert level > HEARD_ABOVE_DB, f"bob could not hear alice: {level}"
    finally:
        ui.leave_if_in_call(a, b)
        admin.call("DELETE", f"/channels/{annex['id']}")
