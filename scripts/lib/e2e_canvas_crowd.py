# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Three people on one canvas, in the call with cameras on, through a restart.

What a real onboarding looks like and two browsers never are: alice and bob
and carol all in the voice call with their cameras publishing and the call
dock showing, each drawing, each switching tools with a real mouse press on
the dock, the server restarted under them as a deploy does, and the admin
clearing at the end. Every step is read off all three screens and the server.
"""
import os
import subprocess
import time

import e2e_audio
import e2e_browsers
import e2e_labels as L
from e2e_canvas import at, origin, wait_for_kind_count, wait_for_summary
from e2e_api import wait_until

CAMERA_ON = "Turn on camera"
RESTART_SETTLE_SECONDS = 20


def _in_canvas(c, channel):
    if not c.find(L.OPEN_CANVAS) and not c.find("Canvas,"):
        c.click(channel)
        c.wait_for(L.IN_CALL)
    if not c.find("Canvas,"):
        c.click(L.OPEN_CANVAS)
    c.wait_for("Canvas,")


def _stroke(c, row):
    org = origin(c)
    y = 260 + row * 50
    c.gestures(True)
    c.drag([at(org, (300, y)), at(org, (380, y + 20)), at(org, (460, y))])
    c.gestures(False)


def _everyone_sees(clients, needle):
    for c in clients:
        wait_for_summary(c, needle, timeout=30)


def _press_tool(c, label):
    """A real pointer press on the dock button, not a semantics click."""
    node = c.wait_for(label)
    c.gestures(True)
    c.mouse_click(node["x"], node["y"])
    c.gestures(False)
    time.sleep(0.5)


def _restart_server():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    subprocess.run(["bash", os.path.join(root, "e2e-stack.sh"),
                    "restart-server"], check=True, timeout=180)


def crowd_draws_through_a_restart(a, b, server, secret, admin_api, sign_in,
                                  channel_id):
    e2e_browsers.register(server, admin_api, "carol", secret)
    wav = os.path.join(e2e_browsers.work_dir(), "fake-voice.wav")
    with e2e_browsers.browser("carol", wav) as c:
        e2e_audio.install(c)
        sign_in(c, server, "carol", secret)
        e2e_browsers.dismiss_welcome(c)
        try:
            _run(a, b, c, admin_api, channel_id)
        finally:
            _leave(c)


def _leave(c):
    # The next scenarios count the call's members, so carol must be out of it.
    if c.find(L.LEAVE_CALL):
        c.click(L.LEAVE_CALL, settle=2)


def _run(a, b, c, admin_api, channel_id):
    clients = (a, b, c)
    for client in clients:
        _in_canvas(client, L.VOICE_CHANNEL)
    for client in clients:
        client.wait_for("3 in call")
        client.click(CAMERA_ON, settle=2)
    print("  three in the call with cameras on and the canvas open")

    base = len(admin_api.canvas_objects(channel_id))
    for client in clients:
        _press_tool(client, L.PEN_TOOL)
    for row, client in enumerate(clients):
        _stroke(client, row)
    wait_until(lambda: len(admin_api.canvas_objects(channel_id)),
               lambda n: n == base + 3, "three strokes never reached the server")
    for client in clients:
        wait_for_summary(client, f"{base + 3} objects", timeout=30)
    print("  each drew a stroke and all three screens show all three")

    for client in clients:
        _press_tool(client, L.ERASER_TOOL)
    org = origin(b)
    b.gestures(True)
    b.drag([at(org, (300, 310)), at(org, (380, 330)), at(org, (460, 310))])
    b.gestures(False)
    wait_until(lambda: len(admin_api.canvas_objects(channel_id)),
               lambda n: n == base + 2, "bob's eraser press never took effect")
    print("  a real press on the dock switched bob to the eraser, and it erased")

    _restart_server()
    time.sleep(RESTART_SETTLE_SECONDS)
    for client in clients:
        _press_tool(client, L.PEN_TOOL)
    for row, client in enumerate(clients):
        _stroke(client, row + 4)
    wait_until(lambda: len(admin_api.canvas_objects(channel_id)),
               lambda n: n == base + 5, "ink after the restart never arrived")
    for client in clients:
        wait_for_summary(client, f"{base + 5} objects", timeout=30)
    print("  after a server restart all three still draw and still see each other")

    b.click(L.MORE_CANVAS_ACTIONS)
    assert not b.find(L.CLEAR_CANVAS), "a member without manage sees Clear canvas"
    b.dismiss_overlay()
    a.click(L.MORE_CANVAS_ACTIONS)
    a.click(L.CLEAR_CANVAS)
    a.click(L.CLEAR_CANVAS, settle=3)
    _everyone_sees(clients, "no objects")
    wait_until(lambda: admin_api.canvas_objects(channel_id),
               lambda objects: not objects, "the server kept ink after a clear")
    print("  the admin's clear emptied all three screens and the server")
