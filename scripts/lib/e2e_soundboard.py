# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A soundboard clip played in a call is played by every client in it.

The server only fans out a signal (decision 0118), so the proof has to come
from the listener's own browser: bob's page must start a media element on the
clip's bytes and actually advance through them. Deafening bob must keep it
silent for him while alice still hears her own clip, and the server's refusals
(the per-person rate, a deleted clip) are read back as statuses.
"""
import io
import json
import math
import struct
import time
import wave

import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call

CLIP_NAME = "e2e-honk"
PLAY_TIMEOUT = 8.0
RATE_WINDOW = 3.2

# Records every element started on in-memory bytes, which is how a clip plays; call audio uses srcObject and chimes use asset URLs.
_SPY = """(() => {
  if (window.__clipPlays) return true;
  window.__clipPlays = [];
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    if (!this.srcObject && /^(blob|data):/.test(this.src || '')) {
      const rec = {volume: this.volume, muted: this.muted, advanced: false};
      const mark = () => { if (this.currentTime > 0 || this.ended) rec.advanced = true; };
      this.addEventListener('timeupdate', mark);
      this.addEventListener('ended', () => { rec.advanced = true; });
      window.__clipPlays.push(rec);
    }
    return play.apply(this, arguments);
  };
  return true;
})()"""

_PLAYS = "JSON.stringify(window.__clipPlays || [])"


def clip_wav(seconds=1.0, rate=16000, hz=440):
    """A short tone, small enough for the 512 KB and 5 s limits."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        frames = b"".join(
            struct.pack("<h", int(12000 * math.sin(2 * math.pi * hz * i / rate)))
            for i in range(int(seconds * rate)))
        out.writeframes(frames)
    return buf.getvalue()


def _plays(client):
    return json.loads(client.ev(_PLAYS) or "[]")


def _wait_for_plays(client, count, timeout=PLAY_TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        plays = _plays(client)
        if len(plays) >= count:
            return plays
        time.sleep(0.2)
    client.shot("soundboard-no-play")
    raise AssertionError(f"{client.name}: {len(_plays(client))} clip plays, expected {count}")


def _play_from_the_dock(client):
    client.click("Soundboard", settle=1.5)
    client.click(CLIP_NAME, settle=0.5)
    client.dismiss_overlay()


def clip_plays_for_everyone_in_the_call(a, b, admin, member, room_id):
    channel_id = admin.channel_named(L.VOICE_CHANNEL)["id"]
    clip = admin.call("POST", f"/soundboard?name={CLIP_NAME}",
                      raw=clip_wav(), content_type="audio/wav")
    play_path = f"/channels/{channel_id}/voice/soundboard/{clip['id']}/play"
    try:
        assert clip["duration_ms"] == 1000, clip
        print(f"  alice uploaded {CLIP_NAME!r}, {clip['duration_ms']} ms")
        assert member.status("POST", play_path) == 403, \
            "bob played a clip into a call he is not in"
        join_call(a, b, room_id)
        for c in (a, b):
            assert c.ev(_SPY), f"{c.name}: the play spy did not install"

        _play_from_the_dock(a)
        heard = _wait_for_plays(b, 1)
        mine = _wait_for_plays(a, 1)
        time.sleep(1.5)
        heard, mine = _plays(b), _plays(a)
        assert heard[0]["advanced"], f"bob's clip never played through: {heard}"
        assert heard[0]["volume"] > 0 and not heard[0]["muted"], heard
        assert mine[0]["advanced"], f"alice did not hear her own clip: {mine}"
        print(f"  bob's browser played alice's clip at volume {heard[0]['volume']:.2f}, "
              "and alice heard it too")

        time.sleep(RATE_WINDOW)
        assert admin.status("POST", play_path) == 200
        assert admin.status("POST", play_path) == 429, \
            "a second play inside 3 s was not refused"
        print("  a second play inside three seconds is refused with 429")
        _wait_for_plays(b, 2)

        b.click("Deafen", settle=1.5, fixed=True)
        time.sleep(RATE_WINDOW)
        before_b, before_a = len(_plays(b)), len(_plays(a))
        _play_from_the_dock(a)
        _wait_for_plays(a, before_a + 1)
        time.sleep(2)
        assert len(_plays(b)) == before_b, "a deafened bob still played the clip"
        print("  deafened, bob plays nothing while alice still hears her clip")
        b.click("Undeafen", settle=1)

        admin.call("DELETE", f"/soundboard/{clip['id']}")
        time.sleep(RATE_WINDOW)
        assert admin.status("POST", play_path) == 404, "a deleted clip still played"
        print("  a deleted clip is refused with 404")
    finally:
        admin.status("DELETE", f"/soundboard/{clip['id']}")
        if b.find("Undeafen"):
            b.click("Undeafen", settle=1)
        ui.leave_if_in_call(a, b)
