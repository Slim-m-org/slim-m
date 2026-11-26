# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How long after you start talking your own speaking ring lights.

A browser joins a call alone with a microphone that alternates silence and
speech-shaped voice. Its page samples the raw capture level every 10 ms and,
every 20 ms, whether any avatar carries the speaking suffix. The delay is the
gap between each speech onset in the capture and the next lit sample.
"""
import json
import os
import struct
import time
import wave

import e2e_audio
import e2e_browsers
import e2e_labels as L
import make_fake_voice
from e2e_api import Api
from e2e_voice import _click_channel_row, _tap_label

SENDER = "quiet"
SILENCE_SECONDS = 2.0
SPEECH_SECONDS = 2.0
MEASURE_SECONDS = 24
# Digital silence reads far below this; speech at the e2e level reads far above it.
QUIET_DB = -70.0
SPEECH_DB = -45.0
# The SFU path measured 0.19 s on loopback with no meter shown; the gate path measured 0.09 s.
MAX_MEDIAN_SECONDS = 0.15
MIN_ONSETS = 4

MIC_JS = """
(function(){
  var rows = [];
  window.__e2eMic = {since: function(ms){ return rows.filter(function(r){ return r[0] >= ms; }); }};
  var md = navigator.mediaDevices;
  var gum = md.getUserMedia.bind(md);
  md.getUserMedia = function(c){
    return gum(c).then(function(stream){
      if (stream.getAudioTracks().length && !window.__e2eMicTapped) {
        window.__e2eMicTapped = true;
        var ctx = new AudioContext();
        var an = ctx.createAnalyser();
        an.fftSize = 512;
        ctx.createMediaStreamSource(stream).connect(an);
        var buf = new Float32Array(an.fftSize);
        setInterval(function(){
          an.getFloatTimeDomainData(buf);
          var s = 0; for (var i = 0; i < buf.length; i++) s += buf[i] * buf[i];
          rows.push([performance.now(), 10 * Math.log10(s / buf.length + 1e-12)]);
        }, 10);
      }
      return stream;
    });
  };
})()"""

RING_JS = """
(function(suffix){
  var rows = [];
  window.__e2eOwnRing = {since: function(ms){ return rows.filter(function(r){ return r[0] >= ms; }); }};
  setInterval(function(){
    var lit = false;
    document.querySelectorAll('flt-semantics').forEach(function(e){
      var t = (e.getAttribute('aria-label') || e.textContent || '').toLowerCase();
      if (t.indexOf(suffix) >= 0) lit = true;
    });
    rows.push([performance.now(), lit]);
  }, 20);
})(%s)"""


def write_gapped_voice(path):
    """One loop of silence then voice, long enough that the ring's hold has run out before each onset."""
    voice = list(make_fake_voice.samples())
    quiet = [0] * int(make_fake_voice.RATE * SILENCE_SECONDS)
    loud = voice[:int(make_fake_voice.RATE * SPEECH_SECONDS)]
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(make_fake_voice.RATE)
        out.writeframes(b"".join(struct.pack("<h", v) for v in quiet + list(loud)))


def speech_onsets(mic, quiet_db=QUIET_DB, speech_db=SPEECH_DB, quiet_ms=500):
    """Times (ms) where the capture goes from at least `quiet_ms` of silence to speech."""
    onsets, quiet_since = [], None
    for t, db in mic:
        if db < quiet_db:
            quiet_since = t if quiet_since is None else quiet_since
        elif db > speech_db:
            if quiet_since is not None and t - quiet_since >= quiet_ms:
                onsets.append(t)
            quiet_since = None
    return onsets


def onset_delays(onsets, ring):
    """Seconds from each onset to the next lit ring sample at or after it; None if it never lit."""
    out = []
    for onset in onsets:
        lit = next((t for t, on in ring if t >= onset and on), None)
        out.append(None if lit is None else (lit - onset) / 1000.0)
    return out


def median(values):
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def own_ring_lights_promptly(server, secret, sign_in, admin_api):
    e2e_browsers.register(server, admin_api, SENDER, secret)
    Api(server).login(SENDER, secret, device="e2e-ownring")
    path = os.path.join(e2e_browsers.work_dir(), "own-ring-voice.wav")
    write_gapped_voice(path)
    with e2e_browsers.browser(SENDER, path) as page, e2e_audio.installed(page, MIC_JS):
        sign_in(page, server, SENDER, secret)
        e2e_browsers.dismiss_welcome(page)
        try:
            _click_channel_row(page, L.VOICE_CHANNEL)
            page.wait_for(L.LEAVE_CALL)
            page.ev(RING_JS % json.dumps(L.SPEAKING.lower()))
            start = page.ev("performance.now()")
            time.sleep(MEASURE_SECONDS)
            mic = json.loads(page.ev("JSON.stringify(window.__e2eMic.since(%s))" % start) or "[]")
            ring = json.loads(page.ev("JSON.stringify(window.__e2eOwnRing.since(%s))" % start) or "[]")
        finally:
            if page.find(L.LEAVE_CALL):
                _tap_label(page, L.LEAVE_CALL, settle=3)
    delays = onset_delays(speech_onsets(mic), ring)
    for d in delays:
        print(f"  speech onset to own ring: {'never' if d is None else f'{d * 1000:.0f} ms'}")
    lit = [d for d in delays if d is not None]
    assert len(lit) >= MIN_ONSETS, f"only {len(lit)} of {len(delays)} speech onsets lit the own ring"
    print(f"  median {median(lit) * 1000:.0f} ms, worst {max(lit) * 1000:.0f} ms")
    assert median(lit) <= MAX_MEDIAN_SECONDS, f"own ring took {median(lit):.2f} s at the median"
