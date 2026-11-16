# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Whether the speaking ring lights for someone you can plainly hear, however softly they talk.

A sender captures the same speech-shaped voice at a lower level each round and
joins alice's call. Alice's page samples what reaches her from that sender and,
every 100 ms, whether the sender shows as speaking. Someone else's ring follows
the SFU's own voice-activity report, which only counts packets over a fixed
level, so a soft talker can be heard with their ring dark.

The thresholds carry the numbers they were set from, beside them below.
"""
import json
import os
import random
import struct
import time
import wave

import e2e_audio
import e2e_audio_levels as lv
import e2e_browsers
import e2e_labels as L
import e2e_voice_ui as ui
import make_fake_voice
import make_noisy_voice
from e2e_api import Api
from e2e_voice import _tap_label

SENDER = "quiet"
# Gain on the captured voice in dB, before the sender's own auto gain: a normal voice down to a soft one.
LEVELS_DB = (-6, -20, -30, -40, -50, -60)
AUDIBLE_DB = -50.0
# Measured at active_level 45: 100% at every audible level, down to a voice heard at -25 dB (91% at the old 35).
MIN_LIT = 0.8
# A hiss heard this quietly is background, and may light the ring for at most MAX_NOISE_LIT of the time.
QUIET_HISS_DB = -45.0
MAX_NOISE_LIT = 0.1
SETTLE_SECONDS = 3
MEASURE_SECONDS = 10
# A syllable gap is about 90 ms, so a ring sample counts as audible when speech reached alice this recently.
AUDIBLE_WINDOW = 0.25

RING_JS = """
(function(wanted){
  if (window.__e2eRing) return;
  var rows = [];
  window.__e2eRing = {since: function(ms){
    return rows.filter(function(r){ return r[0] >= ms; });
  }};
  setInterval(function(){
    var lit = false;
    document.querySelectorAll('flt-semantics').forEach(function(e){
      var t = (e.getAttribute('aria-label') || e.textContent || '').toLowerCase();
      if (t.indexOf(wanted) >= 0) lit = true;
    });
    rows.push([window.__e2eAudio.now(), lit]);
  }, 100);
})(%s)"""


def lit_while_audible(levels, ring, audible_db=AUDIBLE_DB, window=AUDIBLE_WINDOW):
    """Share of ring samples taken while the sender was audible that showed them speaking; None if never audible.

    `levels` is `[(seconds, db)]` as received, `ring` is `[(seconds, lit)]`.
    """
    loud = sorted(t for t, db in levels if db >= audible_db)
    audible = [lit for t, lit in ring if any(t - window < s <= t for s in loud)]
    if not audible:
        return None
    return sum(1 for lit in audible if lit) / len(audible)


def soft_but_unlit(rounds, audible_db=AUDIBLE_DB, min_lit=MIN_LIT):
    """The rounds whose voice was plainly heard while the ring mostly stayed dark."""
    return [r for r in rounds
            if r["heard_db"] >= audible_db and (r["lit"] or 0.0) < min_lit]


def _new_stream(probe, before, room_id, sender_id, timeout=45):
    """The sender's stream, found as the one stream that is new since they joined.

    Chrome reuses an earlier round's receiver for the sender's new track, and
    livekit names the audio element after that receiver, so the element keeps
    the first round's track id and a lookup by the SFU's track id misses it.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        fresh = [s for s in probe.stream_ids() if s not in before]
        if fresh:
            return fresh[0]
        time.sleep(0.25)
    return ui.stream_for(probe, room_id, sender_id, timeout=1)


def lit_share(ring):
    """Share of all ring samples that showed the sender speaking."""
    return sum(1 for _, lit in ring if lit) / len(ring) if ring else 0.0


def _write_noise(path, seconds=6):
    rng = random.Random(make_noisy_voice.SEED)
    hiss = make_noisy_voice.noise_samples(make_fake_voice.RATE * seconds, rng)
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(make_fake_voice.RATE)
        out.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in hiss))


def _round(listener, server, secret, sign_in, room_id, sender_id, path):
    probe = e2e_audio.AudioProbe(listener)
    before = set(probe.stream_ids())
    with e2e_browsers.browser(SENDER, path) as sender:
        sign_in(sender, server, SENDER, secret)
        e2e_browsers.dismiss_welcome(sender)
        try:
            sender.click(L.VOICE_CHANNEL)
            sender.wait_for(L.IN_CALL)
            stream = _new_stream(probe, before, room_id, sender_id)
            time.sleep(SETTLE_SECONDS)
            start = probe.now()
            time.sleep(MEASURE_SECONDS)
            levels = [(t, pre) for t, _, pre in probe.series(stream, start)]
            ring = [(t / 1000.0, lit) for t, lit in json.loads(listener.ev(
                "JSON.stringify(window.__e2eRing.since(%s))" % json.dumps(start)) or "[]")]
        finally:
            if sender.find(L.LEAVE_CALL):
                _tap_label(sender, L.LEAVE_CALL, settle=3)
    heard = lv.percentile([db for _, db in levels], 95)
    return {"heard_db": heard, "lit": lit_while_audible(levels, ring),
            "lit_any": lit_share(ring), "samples": len(ring)}


def ring_follows_a_soft_voice(listener, server, secret, admin_api, sign_in, room_id):
    e2e_browsers.register(server, admin_api, SENDER, secret)
    api = Api(server)
    api.login(SENDER, secret, device="e2e-quiet")
    sender_id = api.me()["id"]
    rounds = []
    with e2e_audio.installed(listener):
        try:
            listener.click(L.VOICE_CHANNEL)
            listener.wait_for(L.IN_CALL)
            listener.ev(RING_JS % json.dumps(f"{SENDER}{L.SPEAKING}".lower()))
            for level in LEVELS_DB:
                path = os.path.join(e2e_browsers.work_dir(), f"quiet-voice{level}.wav")
                make_fake_voice.write(path, amplitude=10 ** (level / 20))
                r = {"level_db": level, **_round(listener, server, secret, sign_in,
                                                 room_id, sender_id, path)}
                rounds.append(r)
                lit = "never audible" if r["lit"] is None else f"{r['lit']:.0%}"
                print(f"  voice at {level:4d} dB: heard at {r['heard_db']:6.1f} dB, "
                      f"ring lit {lit} of the time it was audible ({r['samples']} samples)")
            path = os.path.join(e2e_browsers.work_dir(), "quiet-hiss.wav")
            _write_noise(path)
            hiss = _round(listener, server, secret, sign_in, room_id, sender_id, path)
            print(f"  hiss with no voice: heard at {hiss['heard_db']:6.1f} dB, "
                  f"ring lit {hiss['lit_any']:.0%} of the time")
        finally:
            if listener.find(L.LEAVE_CALL):
                _tap_label(listener, L.LEAVE_CALL, settle=3)
    dark = soft_but_unlit(rounds)
    assert not dark, f"heard without a speaking ring: {dark}"
    if hiss["heard_db"] < QUIET_HISS_DB:
        assert hiss["lit_any"] <= MAX_NOISE_LIT, \
            f"a hiss heard at {hiss['heard_db']:.1f} dB lit the ring {hiss['lit_any']:.0%} of the time"
    else:
        # Noise suppression left it plainly audible (measured -35.5 dB on CI, -49 here), so a lit ring is honest.
        print(f"  the hiss reached {hiss['heard_db']:.1f} dB, loud enough to count as sound")
