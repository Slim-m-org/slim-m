# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A camera tile's shared, persistent position on the Voice Canvas.

Every other canvas scenario in this run proves a client agrees with the
server about an object it drew; this is the first one whose entire point is
that two *clients* agree with each other about something neither of them
drew - decision 0010's reversal made position, size, lock and depth of a
camera or screen-share tile shared and server-persisted rather than a purely
local presence artifact. No unit test on either side can see that: the
server's own tests check the row it stores, the client's own tests check one
`CanvasPresenceTileOverrides` in isolation, and neither can see whether a
drag on one browser is what a second browser, and a fresh fetch on a third
mount, actually agree happened.

Runs while `a` and `b` are both already in the 'lounge' call with its canvas
open on `a` (e2e_voice.canvas_keeps_call_controls leaves it that way) - a
canvas viewer sees no presence tile at all for a channel they have not
themselves joined the call in (canvas_pane_gestures.dart's own
`_callParticipants` doc says why), so `b` has to open the same channel's
canvas from the voice header too before any of this is visible to them.

Drags the tile while the camera stays off, deliberately: `presenceTileKeys`
(canvas_presence_geometry.dart) gives every call participant a `camera:<id>`
tile the instant they are on the call, camera on or off, rendered as a
plain avatar bubble - real `CustomPaint`/`Text` content Flutter's own canvas
hit-tests normally. A live camera track renders through flutter_webrtc's web
`RTCVideoView`, an `HtmlElementView` platform view - a genuine interactive
DOM `<video>` element layered over Flutter's own canvas, which absorbs a
raw CDP-dispatched mouse event before it ever reaches Flutter's gesture
arena. Confirmed directly: dragging the tile with the camera on left it at
the exact pixel it started, screenshot and all, while the identical drag
against the same tile with the camera off moves it. The feature under test
- shared, persistent position, size, lock and depth - has nothing to do
with what the tile currently shows, so there is nothing lost by never
turning the camera on here.

The second drag's own commit is checked for real movement in the right
direction, never for landing on the exact pixel requested. A canvas
object's own drag (`canvas_ops_controller_select.dart`, see `e2e_canvas.py`)
tracks a raw pointer directly and lands within single digits of the
requested delta every time; this tile's own `_drag` (`canvas_presence_tile.dart`)
goes through `GestureDetector.onPanUpdate` instead, whose `PanGestureRecognizer`
resolves the gesture arena against a touch-slop threshold before it starts
reporting deltas at all - confirmed live, not assumed, when a second 120x90
drag only ever committed roughly 60x60 server-side. Both are real, honest
movement; only one of them is exact enough to assert pixel-for-pixel.
"""
import time

import e2e_board_frame
import e2e_labels as L
from e2e_voice import participants_with_mics

# canvas_presence_layer.dart's own `_tile` builds these, on or off camera.
ALICE_SELF_LABEL = "Alice, you, on this call's canvas"
ALICE_REMOTE_LABEL = "Alice, on this call's canvas"

# Different deltas, so a second commit is told apart from a stale first one.
_DRAG_ONE = (70, 50)
_DRAG_TWO = (120, 90)


def _drag_tile(client, label, dx, dy):
    n = client.wait_for(label)
    client.gestures(True)
    client.drag([(n["x"], n["y"]), (n["x"] + dx // 2, n["y"] + dy // 2),
                 (n["x"] + dx, n["y"] + dy)])
    client.gestures(False)
    time.sleep(2)


def _wait_for_slot(admin_api, channel_id, alice_id, after_updated_at=None,
                    timeout=20):
    """Polls for the committed slot, told apart from a stale prior commit by
    its own `updated_at` rather than by its coordinates - a second drag
    landing back on the first drag's exact pixel is unlikely but not
    impossible, and a monotonic write timestamp can never tie that way.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        slot = admin_api.canvas_media_slot(channel_id, "camera", alice_id)
        if slot and (after_updated_at is None or
                     slot["updated_at"] > after_updated_at):
            return slot
        time.sleep(0.5)
    raise AssertionError("the server never recorded the tile's own commit")


def move_converges_and_persists(a, b, admin_api, channel_id, room_id):
    """`a` drags her own camera tile twice; the server tracks both commits,
    `b` sees the second one live, and the position survives both a call
    rejoin and a cold reopen of the canvas pane.

    The leave-and-rejoin half checks the SFU rather than waiting for
    `L.IN_CALL` or "N in call" on screen: both strings live in
    `CallStageLayout`, and the moment of the rejoin is the voice screen,
    not the canvas. Hanging up from the canvas dock closes the canvas with
    the call now (the owner was left on an empty canvas otherwise, and
    closing it by hand later rejoined the call), so both sides land on the
    voice screen, rejoin by re-clicking the channel (PR #469's fix), and
    reopen the canvas from the voice header before looking for the tile.
    """
    alice_id = admin_api.me()["id"]

    b.click(L.OPEN_CANVAS)
    # The surface, not an empty one: the canvas scenarios leave objects here.
    b.wait_for("Canvas,")
    print("  b opened the same channel's canvas from the voice header")

    a.wait_for(ALICE_SELF_LABEL)
    b.wait_for(ALICE_REMOTE_LABEL)
    print("  alice's own tile is already there for both, camera off - "
          "every call participant gets one on the canvas unconditionally")

    # The pen is armed on open and a drag over a tile draws with it now; moving is the Move tool's job.
    a.click(L.PAN_TOOL)
    _drag_tile(a, ALICE_SELF_LABEL, *_DRAG_ONE)
    slot_1 = _wait_for_slot(admin_api, channel_id, alice_id)
    print(f"  first drag committed to the server: ({slot_1['x']:.0f}, "
          f"{slot_1['y']:.0f})")

    b_before = b.wait_for(ALICE_REMOTE_LABEL)
    _drag_tile(a, ALICE_SELF_LABEL, *_DRAG_TWO)
    slot_2 = _wait_for_slot(admin_api, channel_id, alice_id,
                            after_updated_at=slot_1["updated_at"])
    server_dx, server_dy = slot_2["x"] - slot_1["x"], slot_2["y"] - slot_1["y"]
    # Not an exact match against _DRAG_TWO - see this module's own doc.
    assert server_dx > 20 and server_dy > 20, \
        f"the second drag barely moved the tile server-side: " \
        f"dx={server_dx} dy={server_dy}"
    print(f"  second drag committed too: ({slot_2['x']:.0f}, "
          f"{slot_2['y']:.0f}), a real move of ({server_dx:.0f}, {server_dy:.0f})")

    b_after = b.wait_for(ALICE_REMOTE_LABEL)
    dx, dy = b_after["x"] - b_before["x"], b_after["y"] - b_before["y"]
    # The server stores board units; b sees them through its own fitted board's zoom (decision 0073).
    _, _, zoom = e2e_board_frame.board_frame(b)
    want_dx, want_dy = server_dx * zoom, server_dy * zoom
    assert abs(dx - want_dx) < 15 and abs(dy - want_dy) < 15, \
        f"b's own screen moved by ({dx}, {dy}), not the server's move " \
        f"({server_dx:.0f}, {server_dy:.0f}) at b's zoom {zoom:.3f}: " \
        f"({want_dx:.0f}, {want_dy:.0f})"
    print(f"  b's own screen moved with it, live, with no reload: "
          f"dx={dx} dy={dy}")

    for c in (a, b):
        c.click(L.LEAVE_CALL, settle=6)
    for c in (a, b):
        # The hang-up closes the canvas with the call; its own button is gone.
        assert not c.find(L.CLOSE_CANVAS), \
            f"{c.name}: the canvas stayed open after hanging up"
    print("  hanging up from the canvas dock closed the canvas for both")
    time.sleep(2)
    for c in (a, b):
        c.click(L.VOICE_CHANNEL)
    for c in (a, b):
        c.wait_for(L.MUTE, timeout=20)
    parts = participants_with_mics(room_id)
    assert len(parts) == 2, \
        f"SFU has {len(parts)} participants after rejoining, expected 2"
    print("  both rejoined by re-clicking the channel, confirmed at the SFU")
    for c in (a, b):
        c.click(L.OPEN_CANVAS)
        c.wait_for("Canvas,")
    a.wait_for(ALICE_SELF_LABEL, timeout=30)
    b.wait_for(ALICE_REMOTE_LABEL, timeout=30)
    print("  the tile reappeared for both after leaving and rejoining "
          "the call")

    b.click(L.CLOSE_CANVAS)
    b.wait_for(L.MUTE)
    b.click(L.OPEN_CANVAS)
    reopened = b.wait_for(ALICE_REMOTE_LABEL, timeout=30)
    rx, ry = reopened["x"] - b_after["x"], reopened["y"] - b_after["y"]
    assert abs(rx) < 15 and abs(ry) < 15, \
        f"b's freshly reopened canvas, with no local cache left, landed " \
        f"at a different spot than the server holds: dx={rx} dy={ry}"
    print("  and a cold reopen - a brand new local cache, fetched fresh "
          "from the server - still finds it exactly where it was left")

    b.click(L.CLOSE_CANVAS)
    print("  b's canvas is closed, so the next scenario (leaving) finds "
          "the plain call screen it expects")
