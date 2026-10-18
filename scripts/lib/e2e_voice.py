# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A real voice call across two web clients, checked on both sides.

Every claim is checked twice over: once against what each client renders, and
once against what the SFU itself reports, because a roster that looks right is
not evidence that a track was ever published.

Rejoining a channel already left lives in e2e_voice_rejoin.py, split out to
stay under the file budget; it imports the helpers below rather than
duplicating them.
"""
import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request

import e2e_api
import e2e_labels as L


def sfu_participants(room):
    """Ask the SFU itself who is connected, rather than trusting either UI."""
    def b64(b):
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

    # Required rather than defaulted: e2e.sh always exports both, and a
    # guessable fallback would quietly sign tokens for whatever SFU answered.
    key = os.environ["LIVEKIT_API_KEY"]
    secret = os.environ["LIVEKIT_API_SECRET"].encode()
    now = int(time.time())
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64(json.dumps({
        "iss": key, "sub": "e2e", "nbf": now - 30, "exp": now + 300,
        "video": {"roomAdmin": True, "room": room}}).encode())
    sig = b64(hmac.new(secret, f"{header}.{payload}".encode(),
                       hashlib.sha256).digest())
    url = os.environ.get("LIVEKIT_HTTP", "http://localhost:7880")
    # e2e_api.py's Cloudflare UA workaround applies here too, if ever pointed off-localhost.
    req = urllib.request.Request(
        f"{url}/twirp/livekit.RoomService/ListParticipants",
        data=json.dumps({"room": room}).encode(),
        headers={"Authorization": f"Bearer {header}.{payload}.{sig}",
                 "Content-Type": "application/json",
                 "User-Agent": e2e_api.USER_AGENT})
    return json.load(urllib.request.urlopen(req)).get("participants", [])


def tracks_of(participant, source):
    return [t for t in participant.get("tracks", [])
            if t.get("source") == source]


def participants_with_mics(room_id, expected=2, timeout=25):
    """The room's participants, once every one of them is publishing a mic.

    "N in call" on screen means the client joined, which the SFU learns
    before the microphone track is published, so reading the roster the
    instant that label appears is a race the caller happens to win or lose.
    The plain-voice path won it and the DM path did not, which read as a DM
    bug rather than as the timing it was. Polling is what makes both honest;
    the assertions the callers run afterwards are unchanged, so a genuinely
    missing track still fails, just after a real wait rather than instantly.
    """
    deadline = time.time() + timeout
    parts = []
    while time.time() < deadline:
        parts = sfu_participants(room_id)
        if (len(parts) == expected
                and all(tracks_of(p, "MICROPHONE") for p in parts)):
            return parts
        time.sleep(1)
    return parts


def join_call(a, b, room_id, channel=L.VOICE_CHANNEL):
    """Both clients into the same room, each publishing and subscribed.

    Clicking a voice channel joins it directly (PR #354 removed the join
    lobby), so the click that used to open a preview is the join itself, and
    the wait for L.IN_CALL is what proves the connect actually completed.
    """
    # Reached through the rail rather than by URL, which is also the only
    # end-to-end check that the rail is reachable at all: it published no
    # accessibility nodes until the shell stopped letting a modal barrier
    # block them, and nothing but a real run would have noticed.
    for c in (a, b):
        c.click(channel)
        c.wait_for(L.IN_CALL)

    for c in (a, b):
        c.wait_for("2 in call")
        c.shot("in-call")
    a.wait_for("Bob")
    b.wait_for("Alice")
    print("  both clients report 2 in call and list each other")

    parts = participants_with_mics(room_id)
    assert len(parts) == 2, f"SFU has {len(parts)} participants, expected 2"
    for p in parts:
        mics = tracks_of(p, "MICROPHONE")
        assert p["state"] == "ACTIVE", f'{p["identity"]} is {p["state"]}'
        assert mics, f'{p["identity"]} published no microphone track'
        assert not mics[0].get("muted"), f'{p["identity"]} is muted on join'
        print(f'  {p["identity"][:13]} ACTIVE, mic published unmuted')


def _wait_until_gone(client, label, timeout=30):
    """Waits for a label to leave the tree, which `wait_for` cannot express.

    Returns nothing and raises on timeout, so a caller reads the same way
    round as `wait_for` does.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        if client.find(label) is None:
            return
        time.sleep(1)
    client.shot(f"still-there-{label[:20].replace(' ', '-')}")
    raise AssertionError(f"{client.name}: {label!r} never went away")


def audio_actually_arrives(a, b):
    """Sound crossing the SFU, rather than tracks merely being present.

    `join_call` already proves both participants are ACTIVE with an unmuted
    microphone track published. That is presence and plumbing, and it is what
    every voice check here was until this one: two people can satisfy all of
    it with no audio getting through at all - an ICE path that failed over to
    nothing, a codec both ends refused, a capture device producing silence.

    Chrome runs with `--use-fake-device-for-media-stream`, which generates a
    real tone rather than silence, so asserting the speaking indicator lights
    exercises the whole chain: capture, encode, the SFU, decode, LiveKit's own
    voice-activity detection, and that state reaching the roster.

    Each client is asked about the *other* one, which is the load-bearing part.
    A participant's own speaking state is computed from its own local audio
    level and would light with the network unplugged; only the remote one
    proves media crossed the room. A generous timeout because voice-activity
    detection needs a moment of audio before it reports anything.

    Reading a failure here: `join_call` runs immediately before and has already
    asserted both participants are ACTIVE at the SFU with unmuted microphone
    tracks. So a failure at this step is not "the call broke" - it is tracks
    present and no audio detected across them, which is either media genuinely
    not flowing or LiveKit's voice-activity detection never firing on Chrome's
    synthetic tone. The client half is not a suspect: the speaking threshold
    passes any level at the default sensitivity, so this reduces to whatever
    the SFU reports.
    """
    a.wait_for(f"Bob{L.SPEAKING}", timeout=45)
    b.wait_for(f"Alice{L.SPEAKING}", timeout=45)
    a.shot("audio-arrives")
    print("  each client hears the other: the speaking ring lit on both")


def share_screen(client, other, room_id):
    """Publish a screen track, and see the other side told about it.

    The browser is started with a capture source pre-selected, so the picker
    the operating system would raise never appears; everything after that is
    the app's own path. PR #348 removed the in-call quality dialog this used
    to click through ("Balanced"): quality is read from saved Voice settings
    now, so a click on Share a screen calls getDisplayMedia directly with no
    further interaction, on web where `screenShareNeedsSource` is false.
    """
    client.click(L.SHARE_SCREEN, settle=10)

    deadline = time.time() + 45
    shared = None
    while time.time() < deadline:
        for p in sfu_participants(room_id):
            if tracks_of(p, "SCREEN_SHARE"):
                shared = p
                break
        if shared:
            break
        time.sleep(2)
    assert shared, "no screen-share track ever reached the SFU"
    print(f'  {shared["identity"][:13]} is publishing a screen track')

    client.wait_for(L.SHARING_NOTICE)
    client.shot("sharing-screen")
    other.shot("peer-sharing-screen")
    print("  the sharing client says so on screen")

    client.click(L.STOP_SHARING, settle=8)
    deadline = time.time() + 30
    while time.time() < deadline:
        live = [p for p in sfu_participants(room_id)
                if tracks_of(p, "SCREEN_SHARE")]
        if not live:
            break
        time.sleep(2)
    assert not [p for p in sfu_participants(room_id)
                if tracks_of(p, "SCREEN_SHARE")], "the screen track stayed up"
    print("  and stopping it takes the track down")


def mute_propagates(a, b, room_id):
    """One side mutes and the SFU reflects it, then the mute is undone.

    Muting is a persisted preference, not a per-call toggle: leaving a call
    muted carries `microphoneEnabled: false` into VoiceController's next
    `join` (see voice_screen.dart's own doc comment), so a mute left standing
    here would silently carry into whatever call this same client joins
    next, publishing no microphone track at all rather than a muted one.
    Unmuting before returning is this scenario cleaning up after itself, the
    same shape leave_call's own trailing leave already does for the rail.
    """
    a.click(L.MUTE)
    time.sleep(4)
    muted = {p["identity"][:13]: p["tracks"][0].get("muted", False)
             for p in sfu_participants(room_id) if p.get("tracks")}
    assert any(muted.values()), f"no participant reads as muted: {muted}"
    assert not all(muted.values()), f"both read as muted: {muted}"
    b.shot("peer-muted")
    print(f"  exactly one side muted: {muted}")

    a.click(L.UNMUTE)
    time.sleep(4)
    unmuted = {p["identity"][:13]: p["tracks"][0].get("muted", False)
               for p in sfu_participants(room_id) if p.get("tracks")}
    # The comprehension drops the no-track participant this guards against.
    assert unmuted, f"nobody is publishing a mic track: {sfu_participants(room_id)}"
    assert not any(unmuted.values()), f"still reads as muted: {unmuted}"
    print("  and unmuting clears it, so the next call this client joins starts unmuted")


def mute_actually_silences(a, b):
    """Muting stops the sound, not just the flag.

    `mute_propagates` asserts the SFU's own muted bit flips, which is the
    client having said so. It is not the same claim as no audio arriving: a
    track marked muted that still carries frames, or a second capture path
    left publishing, would satisfy every assertion there and be audible to
    everyone in the room. Nothing checked the difference until the speaking
    indicator became something a test could read.

    So this mutes and waits for the other client to stop hearing it, then
    unmutes and waits for it to come back. Each half matters: the first
    catches audio that outlives the flag, and the second catches a mute that
    never releases - a microphone that stays dead after unmuting is the worse
    bug of the two, and one a test that only muted would miss entirely.

    Leaves the client unmuted, as `mute_propagates` does and for the reason
    its own doc gives: a mute left standing carries into the next call.
    """
    a.wait_for(f"Bob{L.SPEAKING}", timeout=45)

    b.click(L.MUTE)
    _wait_until_gone(a, f"Bob{L.SPEAKING}", timeout=30)
    a.shot("peer-muted-and-silent")
    print("  muting stops the sound, not just the flag")

    b.click(L.UNMUTE)
    a.wait_for(f"Bob{L.SPEAKING}", timeout=45)
    print("  and unmuting brings it back, so the mute released the microphone")


def canvas_keeps_call_controls(client, room_id, channel=L.VOICE_CHANNEL):
    """Opening the canvas from inside a call must not cost the call its own
    controls - the owner's own report, and the reason #460 built one shared
    dock. `ConversationPane`'s stage ternary still swaps `VoiceScreen` out
    entirely the instant the canvas opens (home_shell.dart), so the call's
    controls can only still be on screen if the *canvas's own* dock carries
    them: `CanvasCallDock` renders a call row only when the canvas's own
    channel matches the call's, which is why this opens the canvas from the
    voice channel's own wide header rather than the text channel the other
    canvas scenarios in this run use.

    Deliberately never closes the canvas before returning. It did once, and
    that one extra `Client.click(L.CLOSE_CANVAS)` made the very next
    scenario's own `Leave call` click - a real, correctly-found
    `flt-tappable` node, unrelated to the semantics-exposure bug
    `canvas_object_context_menu.dart`'s own fix closed - silently do
    nothing for anywhere between a few seconds and over twenty, reproduced
    across several clean runs. `leave_call` (the next scenario) still
    proves hanging up works, from the ordinary call screen; what this
    scenario needs to prove is only that mute and hang-up survive the
    canvas opening, which the dock while it is still open already answers
    without ever triggering `ConversationPane`'s stage swap back.
    """
    try:
        client.wait_for(L.OPEN_CANVAS, timeout=8)
    except AssertionError:
        # Run alone there is no earlier join; the scenario needs only a call.
        client.click(channel)
        client.wait_for(L.IN_CALL)
    client.click(L.OPEN_CANVAS)
    # "Canvas," not "no objects": the canvas scenarios leave objects here.
    client.wait_for("Canvas,")
    client.wait_for(L.MUTE)
    client.wait_for(L.LEAVE_CALL)
    client.shot("canvas-with-call-dock")
    print(f"  {client.name}: mute and leave call stayed reachable "
          f"with the canvas open")

    client.click(L.MUTE)
    time.sleep(3)
    muted = {p["identity"][:13]: p["tracks"][0].get("muted", False)
             for p in sfu_participants(room_id) if p.get("tracks")}
    assert any(muted.values()), \
        f"muting from inside the canvas's own dock never reached the SFU: {muted}"
    client.wait_for(L.UNMUTE)

    client.click(L.UNMUTE)
    time.sleep(3)
    unmuted = {p["identity"][:13]: p["tracks"][0].get("muted", False)
               for p in sfu_participants(room_id) if p.get("tracks")}
    # As above: an empty dict satisfies `not any` and hides a dropped track.
    assert unmuted, f"nobody is publishing a mic track: {sfu_participants(room_id)}"
    assert not any(unmuted.values()), \
        f"unmuting from inside the canvas's own dock never reached the SFU: {unmuted}"
    print(f"  {client.name}: mute still reaches the SFU with the canvas open")


def _tap_label(client, label, settle=1.0):
    """A raw coordinate tap, bypassing `e2e_js.click`'s own DOM search.

    'Leave call' renders with a doubled accessible text - `Tooltip` and
    `Semantics` both contribute "Leave call" into one node with no
    `aria-label` attribute of its own, `named||textContent` in NODES()
    falls through to the doubled `textContent` - and `click()`'s own
    candidate search can resolve that to an inert ancestor: no exception,
    `.click()` genuinely called on something, and nothing happens.
    Confirmed live, not guessed at: the SFU never saw bob's own disconnect
    after exactly this shape of click. A direct tap at the label's own
    coordinates is the same fallback `client.click()` already reaches for
    on an outright miss, used here unconditionally instead of hoping for
    a hit.
    """
    n = client.wait_for(label)
    client.tap(n["x"], n["y"])
    time.sleep(settle)


def leave_call(a, b, room_id=None):
    """Both sides leave: the drop to 1 proves the count, then a real empty room.

    The room's own doc claims an empty room, but until `room_id` is
    threaded through only the *screen* ever said so - a clean disconnect's
    own signalling to the SFU is not instant, and nothing here polled it.
    When given, waits out that gap directly rather than leaving it for
    whichever later scenario happens to be the first to actually depend
    on the room being empty (`rejoin_after_leaving` is).

    One retry, not a shrug, on bob's own half: his second leave in this
    session (his first is inside the media-slot scenario's own rejoin
    cycle) has been seen to leave the SFU reporting him ACTIVE well past a
    first 25-second wait. Retapping only if `L.LEAVE_CALL` is still on his
    own screen too - if his client already believes it left, clicking a
    button no longer there would only raise a worse error than the one
    this retry exists to recover from.
    """
    _tap_label(a, L.LEAVE_CALL, settle=8)
    b.wait_for("1 in call")
    b.shot("peer-left")
    print("  the remaining client dropped to 1 in call")
    # A lingering call here reads as "in call" on b's own rail summary too,
    # which would let the next scenario's own IN_CALL wait pass on nothing.
    _tap_label(b, L.LEAVE_CALL, settle=4)
    if room_id is not None:
        parts = _wait_for_empty_room(room_id, timeout=25)
        if parts and b.find(L.LEAVE_CALL):
            _tap_label(b, L.LEAVE_CALL, settle=4)
        if parts:
            parts = _wait_for_empty_room(room_id, timeout=25)
        assert not parts, f"the room is not actually empty at the SFU: {parts}"
    print("  and the remaining client leaves too, so no call is left open")


def _wait_for_empty_room(room_id, timeout):
    deadline = time.time() + timeout
    parts = sfu_participants(room_id)
    while parts and time.time() < deadline:
        time.sleep(1)
        parts = sfu_participants(room_id)
    return parts

