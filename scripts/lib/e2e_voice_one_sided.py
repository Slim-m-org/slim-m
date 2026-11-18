# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A call whose signalling stalls on one side shows that side who the server says is there.

On 2026-11-18 Cloudflare stalled and dropped LiveKit's signalling sockets
for minutes at a time while media kept flowing straight to the server. One
person saw the other in the call; the other thought he was alone. Here bob's
signalling socket goes silent both ways and new ones fail, the way an edge
that stopped forwarding looks, while his API and media paths stay up. Alice
joins in that window: the server lists her and bob's room never hears of her.
Bob's screen has to say so, and show her as connecting, within DETECT_SECONDS;
once the socket is back the call has to read normally again.
"""
import os
import re
import time

import e2e_labels as L
from e2e_voice import (_click_channel_row, _tap_label, participants_with_mics,
                       sfu_participants)

DETECT_SECONDS = float(os.environ.get("E2E_ONE_SIDED_DETECT", "30"))
RECOVER_SECONDS = float(os.environ.get("E2E_ONE_SIDED_RECOVER", "120"))
CONNECTING = "connecting"
NOT_CONNECTED = "not connected to you"
LOST_YOU = "The call server lost you"
# What only a call tile says after a name; a member row reads "Alice, online".
TILE_WORDS = re.compile(r", (microphone on|muted|connecting)\b")

# Swallows every /rtc frame both ways while cut, and points a new /rtc socket at a closed port.
WRAP = r"""
(() => {
  if (window.__signalCut) return;
  const W = window.WebSocket;
  const st = window.__signalCut = {cut: false, swallowed: 0, refused: 0};
  const isRtc = (url) => String(url).indexOf('/rtc') >= 0;
  function Wrapped(url, protos) {
    const rtc = isRtc(url);
    if (rtc && st.cut) { st.refused++; url = 'ws://127.0.0.1:9/rtc'; }
    const ws = protos === undefined ? new W(url) : new W(url, protos);
    if (!rtc) return ws;
    const send = ws.send.bind(ws);
    ws.send = function (data) { if (st.cut) { st.swallowed++; return; } send(data); };
    const add = ws.addEventListener.bind(ws);
    const gate = (fn) => function (ev) {
      if (st.cut) { st.swallowed++; return; }
      return fn.call(this, ev);
    };
    ws.addEventListener = function (type, fn, opts) {
      return add(type, type === 'message' && fn ? gate(fn) : fn, opts);
    };
    let handler = null;
    add('message', gate((ev) => handler && handler.call(ws, ev)));
    Object.defineProperty(ws, 'onmessage',
      {get() { return handler; }, set(fn) { handler = fn; }});
    return ws;
  }
  Wrapped.prototype = W.prototype;
  for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Wrapped[k] = W[k];
  window.WebSocket = Wrapped;
})();
"""


def _tile(client, who):
    """The call tile line naming `who`, such as "Alice, microphone on", or None."""
    for n in client.nodes():
        for line in n["t"].split("\n"):
            if line.startswith(f"{who}, ") and TILE_WORDS.search(line):
                return line.replace(L.SPEAKING, "")
    return None


def _view(b):
    return {
        "alice": _tile(b, "Alice"),
        "notice": b.find(NOT_CONNECTED) is not None,
        "reconnecting": b.find(L.RECONNECTING_CALL) is not None,
        "lost_you": b.find(LOST_YOU) is not None,
    }


def _until(b, room_id, seconds, done, what):
    """Polls bob's view and the SFU until `done(view)`, printing each change; the seconds it took."""
    began = time.time()
    seen = None
    while time.time() - began < seconds:
        view = _view(b)
        view["sfu"] = sorted(p.get("name", "?") for p in sfu_participants(room_id))
        if view != seen:
            print(f"    +{time.time() - began:5.1f}s {view}")
            seen = view
        if done(view):
            return time.time() - began
        time.sleep(0.5)
    b.shot(f"one-sided-{what.split()[0]}")
    raise AssertionError(f"{what}: after {seconds:.0f}s bob's call reads {seen}")


def _leave(client):
    if client.find(L.LEAVE_CALL):
        _tap_label(client, L.LEAVE_CALL, settle=3)


def _shown_as_connecting(view):
    tile = view["alice"] or ""
    return CONNECTING in tile and (view["notice"] or view["reconnecting"])


def _back_to_normal(view):
    tile = view["alice"] or ""
    return (("microphone on" in tile or "muted" in tile) and CONNECTING not in tile
            and not view["notice"] and not view["reconnecting"]
            and not view["lost_you"])


def a_stalled_signal_shows_who_the_server_has(a, b, room_id):
    """Bob's signalling stalls while alice joins; he sees her as connecting, then normally."""
    b.send("Page.enable")
    script = b.send("Page.addScriptToEvaluateOnNewDocument", {"source": WRAP})
    b.come_back(b.go_away())
    try:
        assert b.ev("typeof window.__signalCut") == "object", \
            "the socket wrapper did not install"
        _leave(a)
        _leave(b)
        _click_channel_row(b, L.VOICE_CHANNEL)
        b.wait_for(L.IN_CALL)
        participants_with_mics(room_id, expected=1)
        b.ev("window.__signalCut.cut = true; 1")
        print("  bob's signalling is cut; alice joins")
        _click_channel_row(a, L.VOICE_CHANNEL)
        a.wait_for(L.IN_CALL)
        took = _until(b, room_id, DETECT_SECONDS, _shown_as_connecting,
                      "alice joined while bob's signalling was cut")
        assert b.ev("window.__signalCut.swallowed") > 0, \
            "no signalling frame was swallowed, so this run proved nothing"
        print(f"  bob shows alice as connecting {took:.1f}s after she joined")
        b.ev("window.__signalCut.cut = false; 1")
        took = _until(b, room_id, RECOVER_SECONDS, _back_to_normal,
                      "bob's signalling came back")
        print(f"  bob's call reads normally {took:.1f}s after his signalling came back")
    finally:
        b.ev("window.__signalCut && (window.__signalCut.cut = false); 1")
        _leave(b)
        _leave(a)
        b.send("Page.removeScriptToEvaluateOnNewDocument",
               {"identifier": script.get("result", {}).get("identifier", "")})
        b.come_back(b.go_away())
