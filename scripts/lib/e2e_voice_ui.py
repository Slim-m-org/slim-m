# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Driving the call surface by the input a person uses, shared by the voice scenarios."""
import json
import time

import e2e_input
import e2e_labels as L
from e2e_voice import _tap_label, sfu_participants

# Material's slider inset: the track starts this far inside the control's box.
SLIDER_INSET = 12

_RECT_OF_LABEL = """
JSON.stringify((function(){
  var e=Array.from(document.querySelectorAll('flt-semantics')).find(function(e){
    var t=e.getAttribute('aria-label')||'';
    return t===%s || t.indexOf(%s+'\\n')===0;});
  if(!e) return null;
  var r=e.getBoundingClientRect();
  return [r.x, r.y, r.width, r.height];})())"""


def stream_for(probe, room_id, identity, source="MICROPHONE", timeout=45):
    """The listener's stream id carrying `identity`'s SFU track of `source`."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for p in sfu_participants(room_id):
            if p["identity"] != identity:
                continue
            for track in p.get("tracks", []):
                if track.get("source") != source:
                    continue
                stream = probe.stream_of_track(track["sid"])
                if stream:
                    return stream
        time.sleep(1)
    raise AssertionError(f"no {source} stream from {identity} reached the listener")


def leave_if_in_call(*clients):
    for c in clients:
        if c.find(L.LEAVE_CALL):
            _tap_label(c, L.LEAVE_CALL, settle=3)


def slider_rect(client, label):
    raw = client.ev(_RECT_OF_LABEL % (json.dumps(label), json.dumps(label)))
    if not raw or raw == "null":
        client.shot("no-slider")
        raise AssertionError(f"{client.name}: no slider named {label!r}")
    return json.loads(raw)


def slider_percent(client, label):
    """The number the slider's own readout shows, from the row it sits on."""
    x, y, w, h = slider_rect(client, label)
    # In a context menu the readout is merged into the slider's own name.
    for n in client.nodes():
        if n["t"].startswith(label + "\n") and n["t"].endswith("%"):
            return int(n["t"].rsplit("\n", 1)[1].rstrip("%"))
    for n in client.nodes():
        if n["t"].endswith("%") and abs(n["y"] - (y + h / 2)) < 20 \
                and n["x"] > x + w - 10:
            return int(n["t"].rstrip("%"))
    raise AssertionError(f"{client.name}: no readout beside {label!r}")


def set_slider(client, label, percent, maximum=200, tolerance=4, tries=40):
    """Move the slider until the readout reaches `percent`; returns what it shows.

    A tap lands within a few percent of where it was aimed, and within four of
    100% it snaps there, so the loop reads the readout back rather than
    trusting the aim.
    """
    for _ in range(tries):
        shown = slider_percent(client, label)
        if abs(shown - percent) <= tolerance:
            return shown
        if any(n["t"].startswith(label + "\n") for n in client.nodes()):
            # A menu's slider has focus when the menu opens, so the arrow keys move it straight away.
            e2e_input.press(client, "ArrowRight" if shown < percent else "ArrowLeft")
            continue
        x, y, w, h = slider_rect(client, label)
        aim = x + SLIDER_INSET + (w - 2 * SLIDER_INSET) * percent / maximum
        client.gestures(True)
        try:
            client.mouse_click(aim, y + h / 2)
        finally:
            client.gestures(False)
        time.sleep(0.8)
    shown = slider_percent(client, label)
    assert abs(shown - percent) <= tolerance, \
        f"{client.name}: {label!r} would not reach {percent}%, stuck at {shown}%"
    return shown


def open_tile_menu(client, name):
    """Right-click `name`'s call tile and wait for the menu's first row."""
    tile = client.wait_for(f"{name}, microphone")
    e2e_input.right_click(client, tile["x"], tile["y"])
    client.wait_for("Mute for me")


def open_share_menu(client, caption, item):
    """Right-click a share tile, found by its caption, and wait for `item`."""
    tile = client.wait_for(caption)
    # The grid caption sits under its tile, so aim up into the picture.
    e2e_input.right_click(client, tile["x"], tile["y"] - 60)
    client.wait_for(item)


def dismiss_popover(client):
    """Close an anchored popover by clicking its barrier, away from the call tiles."""
    client.gestures(True)
    try:
        client.mouse_click(400, 640)
    finally:
        client.gestures(False)
    time.sleep(0.6)


def open_volume_popover(client, name):
    """The tile menu, whose first row is the volume slider itself."""
    open_tile_menu(client, name)
    client.wait_for("Volume for you")


def reset_volumes(client, name, labels):
    """Put `name`'s sliders back at 100%, so a failed run leaves nothing behind."""
    dismiss_popover(client)
    if not client.find(f"{name}, microphone"):
        return
    open_volume_popover(client, name)
    for label in labels:
        if client.find(label):
            set_slider(client, label, 100)
    dismiss_popover(client)
