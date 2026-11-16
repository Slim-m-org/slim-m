# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A signal socket that drops while the microphone publishes leaves nothing the person cannot mute.

The publish is three messages on one socket: the request to add the track,
the server's answer to it, and the offer that carries the media. Losing the
socket between them left three different wrecks, depending on which message
was lost: a microphone open at the SFU that the client held no publication
for, a client showing its microphone on with no track at the SFU, and close
to a minute of failed resumes. Which one a given delay lands on is a race, so
every case asserts the same thing: the call converges to one microphone that
the client and the SFU agree on, and Mute and Unmute both reach it.
"""
import os
import time

import e2e_labels as L
from e2e_voice import (_click_channel_row, _tap_label, channel_row_point,
                       participants_with_mics, sfu_participants, tracks_of)

# Milliseconds between the add-track request leaving and the socket closing.
DELAYS_MS = [float(x) for x in
             os.environ.get("E2E_SIGNAL_DROP_DELAYS", "0,15,30").split(",")]
# Under the 48 s the SDK spent on resumes that could not succeed.
CONVERGE_SECONDS = float(os.environ.get("E2E_SIGNAL_DROP_CONVERGE", "30"))
TOGGLE_SECONDS = 15

# Closes the /rtc socket [delay] ms after the first frame naming the microphone once armed.
WRAP = r"""
(() => {
  if (window.__signalDrop) return;
  const W = window.WebSocket;
  const st = window.__signalDrop = {armed: false, closed: 0, delay: 0};
  function Wrapped(url, protos) {
    const ws = protos === undefined ? new W(url) : new W(url, protos);
    if (String(url).indexOf('/rtc') < 0) return ws;
    const send = ws.send.bind(ws);
    ws.send = function (data) {
      let head = '';
      try {
        const u = data instanceof ArrayBuffer ? new Uint8Array(data)
            : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        head = String.fromCharCode.apply(null, u.subarray(0, 300));
      } catch (e) { head = ''; }
      send(data);
      if (st.armed && head.indexOf('microphone') >= 0) {
        st.armed = false;
        setTimeout(() => { st.closed++; ws.close(); }, st.delay);
      }
    };
    return ws;
  }
  Wrapped.prototype = W.prototype;
  for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Wrapped[k] = W[k];
  window.WebSocket = Wrapped;
})();
"""


def _tile(client, who):
    for n in client.nodes():
        t = n["t"]
        if t.startswith(who) and ("microphone on" in t or "muted" in t):
            return t.replace("\n", " ").replace(L.SPEAKING, "")
    return None


def _bob_mics(room_id):
    """Bob's microphone tracks at the SFU, as 'on' or 'muted' each; None when he is not there."""
    for p in sfu_participants(room_id):
        if p.get("name") == "Bob":
            return ["muted" if t.get("muted") else "on"
                    for t in tracks_of(p, "MICROPHONE")]
    return None


def _state(a, b, room_id):
    return {
        "sfu": _bob_mics(room_id),
        "banner": b.find(L.RECONNECTING_CALL) is not None,
        "self": _tile(b, "Bob"),
        "peer": _tile(a, "Bob"),
    }


def _wait(a, b, room_id, seconds, wanted, what):
    """Polls until the SFU, bob's own tile and alice's tile of him all read [wanted]."""
    began = time.time()
    seen = None
    while time.time() - began < seconds:
        state = _state(a, b, room_id)
        if state != seen:
            print(f"    +{time.time() - began:4.1f}s {state}")
            seen = state
        if (state["sfu"] == wanted["sfu"] and not state["banner"]
                and wanted["tile"] in (state["self"] or "")
                and wanted["tile"] in (state["peer"] or "")):
            return time.time() - began
        time.sleep(0.5)
    b.shot("signal-drop")
    a.shot("signal-drop-peer")
    raise AssertionError(f"{what}: after {seconds:.0f}s the call reads {seen}, "
                         f"wanted {wanted}")


ON = {"sfu": ["on"], "tile": "microphone on"}
MUTED = {"sfu": ["muted"], "tile": "muted"}


def _leave(client):
    if client.find(L.LEAVE_CALL):
        _tap_label(client, L.LEAVE_CALL, settle=3)


def _one(a, b, room_id, delay):
    _leave(a)
    _leave(b)
    _click_channel_row(a, L.VOICE_CHANNEL)
    a.wait_for(L.IN_CALL)
    participants_with_mics(room_id, expected=1)
    closed = b.ev("window.__signalDrop.closed")
    b.ev(f"window.__signalDrop.delay={int(delay)}; window.__signalDrop.armed=true; 1")
    b.tap(*channel_row_point(b, L.VOICE_CHANNEL))
    took = _wait(a, b, room_id, CONVERGE_SECONDS, ON,
                 f"socket closed {delay:.0f} ms after the publish request")
    assert b.ev("window.__signalDrop.closed") == closed + 1, \
        "the signal socket was never closed, so this run proved nothing"
    print(f"  {delay:.0f} ms: one microphone, on, at the SFU and on both screens after {took:.1f}s")

    b.click(L.MUTE)
    _wait(a, b, room_id, TOGGLE_SECONDS, MUTED, f"{delay:.0f} ms: bob clicked Mute")
    b.click(L.UNMUTE)
    _wait(a, b, room_id, TOGGLE_SECONDS, ON, f"{delay:.0f} ms: bob clicked Unmute")
    a.wait_for(f"Bob{L.SPEAKING}", timeout=TOGGLE_SECONDS)
    print(f"  {delay:.0f} ms: Mute and Unmute reach that one track, and alice hears him after")


def a_signal_drop_mid_publish_converges(a, b, room_id):
    """Bob joins while alice waits, and his signal socket closes around his publish."""
    b.send("Page.enable")
    script = b.send("Page.addScriptToEvaluateOnNewDocument", {"source": WRAP})
    b.come_back(b.go_away())
    try:
        assert b.ev("typeof window.__signalDrop") == "object", \
            "the socket wrapper did not install"
        failed = []
        for delay in DELAYS_MS:
            # Each delay loses a different message, so one failing must not hide the others.
            try:
                _one(a, b, room_id, delay)
            except AssertionError as e:
                print(f"  FAILED at {delay:.0f} ms: {e}")
                failed.append(str(e))
        assert not failed, " | ".join(failed)
    finally:
        _leave(b)
        _leave(a)
        b.send("Page.removeScriptToEvaluateOnNewDocument",
               {"identifier": script.get("result", {}).get("identifier", "")})
        b.come_back(b.go_away())
