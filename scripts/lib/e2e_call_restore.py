# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A call the app went away from is offered back on the next start, and one left on purpose is not.

On the web a reload mid-call is the app going away without a leave, the same
case as a crash on desktop, so it asks before rejoining. The rejoin is checked
at the SFU.
"""
import e2e_labels as L
from e2e_voice import _tap_label, participants_with_mics

PROMPT = "Rejoin the call?"


def _reload(client):
    client.come_back(client.go_away())


def reload_mid_call_offers_to_rejoin(client, room_id):
    client.click(L.VOICE_CHANNEL)
    client.wait_for(L.IN_CALL)
    participants_with_mics(room_id, expected=1)

    _reload(client)
    client.wait_for(PROMPT, timeout=30)
    client.shot("rejoin-prompt")
    client.click("Rejoin")
    client.wait_for(L.IN_CALL)
    parts = participants_with_mics(room_id, expected=1)
    assert parts[0]["state"] == "ACTIVE", f'{parts[0]["identity"]} is {parts[0]["state"]}'
    print(f"  {client.name} reloaded mid-call, was asked, and Rejoin put her back, ACTIVE at the SFU")

    _tap_label(client, L.LEAVE_CALL, settle=3)
    _reload(client)
    client.wait_for(L.VOICE_CHANNEL)
    assert not client.find(PROMPT), "a call left on purpose was offered back after a reload"
    print("  after leaving on purpose, a reload offers nothing")
