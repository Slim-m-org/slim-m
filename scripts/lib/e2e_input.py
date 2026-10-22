# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Real pointer and keyboard input for the affordances that have no label.

A context menu, a held reaction chip and a Tab-indented list item are reached
by the input a person uses, not by activating a semantics node, so these send
genuine browser input events. The accessibility tree's own elements swallow
pointer events, so every pointer helper here lifts them for the gesture and
puts them back afterwards, the same way `Client.gestures` is used elsewhere.
"""
import time

_MOUSE = "Input.dispatchMouseEvent"
_KEY = "Input.dispatchKeyEvent"
_SHIFT = 8
_CTRL = 2
_CODES = {"Tab": 9, "Enter": 13, "Escape": 27, "Backspace": 8, "a": 65,
          "ArrowLeft": 37, "ArrowRight": 39}
# Longer than Flutter's long-press threshold, shorter than a test would notice.
HOLD_SECONDS = 1.0


def _modifier_key(name, code, vk, kind, modifiers):
    return {"type": kind, "key": name, "code": code, "windowsVirtualKeyCode": vk,
            "nativeVirtualKeyCode": vk, "modifiers": modifiers}


def press(client, key, shift=False, ctrl=False):
    """One key down and up, with Shift or Ctrl held when asked.

    The modifier is pressed as a key of its own, not just flagged on the event,
    because Flutter tracks which modifiers are down from the keys themselves.
    """
    code = _CODES[key]
    modifiers = (_SHIFT if shift else 0) | (_CTRL if ctrl else 0)
    held = []
    if shift:
        held.append(("Shift", "ShiftLeft", 16))
    if ctrl:
        held.append(("Control", "ControlLeft", 17))
    for name, where, vk in held:
        client.send(_KEY, _modifier_key(name, where, vk, "keyDown", modifiers))
    base = {"key": key, "code": key, "windowsVirtualKeyCode": code,
            "nativeVirtualKeyCode": code, "modifiers": modifiers}
    down = dict(base, type="keyDown")
    if key == "Enter":
        down["text"] = "\r"
    client.send(_KEY, down)
    client.send(_KEY, dict(base, type="keyUp"))
    for name, where, vk in reversed(held):
        client.send(_KEY, _modifier_key(name, where, vk, "keyUp", 0))
    time.sleep(0.4)


def clear_field(client):
    """Select everything in the focused field and delete it."""
    press(client, "a", ctrl=True)
    press(client, "Backspace")


def right_click(client, x, y):
    """A secondary click, which opens a context menu on a wide window."""
    client.gestures(True)
    try:
        client.hover(x, y, settle=0.5)
        client.mouse_click(x, y, button="right")
    finally:
        client.gestures(False)
    time.sleep(0.8)


def hold(client, x, y, seconds=HOLD_SECONDS):
    """Press, wait past the long-press threshold, release."""
    client.gestures(True)
    try:
        client.hover(x, y, settle=0.5)
        point = {"x": x, "y": y, "button": "left", "clickCount": 1}
        client.send(_MOUSE, dict(point, type="mousePressed"))
        time.sleep(seconds)
        client.send(_MOUSE, dict(point, type="mouseReleased"))
    finally:
        client.gestures(False)
    time.sleep(0.8)


def focused_value(client):
    """The text in whichever field the browser has focused, or None."""
    return client.ev(
        "(function(){var e=document.activeElement;"
        "return e && 'value' in e ? e.value : null})()")


def focused_label(client):
    """The accessible name of the focused element, or None."""
    return client.ev(
        "(function(){var e=document.activeElement;"
        "return e ? e.getAttribute('aria-label') : null})()")


def exact(client, label):
    """The one node named exactly `label`, or None."""
    for node in client.nodes():
        if node["t"] == label:
            return node
    return None


def wait_exact(client, label, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        node = exact(client, label)
        if node:
            return node
        time.sleep(0.25)
    client.shot(f"missing-exact-{label[:20].replace(' ', '-')}")
    raise AssertionError(f"{client.name}: never saw exactly {label!r}")
