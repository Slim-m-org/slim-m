# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Real-speech reference clips and the timed-chirp latency clip for the voice harness.

An objective MOS model needs natural speech, which make_quality_clip.py's synthetic clips are not, so Piper (a local neural TTS) says plain sentences in two voices; nothing is downloaded at run time or committed.
Set SLIMM_PIPER to the `piper` executable and SLIMM_PIPER_VOICES to a folder holding en_US-lessac-medium.onnx and en_US-ryan-medium.onnx.

usage: make_speech_clip.py speech|latency|pulse out.wav [A|B]
"""
import math
import os
import re
import subprocess
import sys

import voice_quality_dsp as dsp

RATE = 48_000
PEAK = 0.5
VOICE_NAME = re.compile(r"[A-Za-z0-9]+(?:[_-][A-Za-z0-9]+)*")
VOICES = {"A": "en_US-lessac-medium", "B": "en_US-ryan-medium"}
SENTENCES = {
    "A": ("Good morning, can everyone hear me alright?",
          "I pushed the fix last night, so it should be live by now.",
          "Let's meet at three and go through the plan once more.",
          "The server was a little slow earlier, but it seems fine again.",
          "Could you share your screen so we can look at that together?",
          "I think the second option is cleaner, and it is easier to test.",
          "Thanks for waiting, I will be right back in a minute."),
    "B": ("Hey, I just joined, sorry if I am a bit late.",
          "We found the problem, and it was a missing setting all along.",
          "Can you say that again, the sound cut out for a second.",
          "I will write it up tonight and send it over in the morning.",
          "That sounds good to me, let's go ahead and ship it.",
          "Remember to turn off your microphone when you are not talking.",
          "Alright, that is everything from my side for today."),
}
LATENCY_PHRASES = {"A": ("testing one two three", "can you hear me now",
                         "the quick brown fox", "hello over there"),
                   "B": ("this is a test call", "are we connected yet",
                         "good evening everyone", "one more time please")}
CHIRP_SECONDS = 0.06
CHIRP_HZ = (1500.0, 3500.0)
CHIRP_LEVEL = 0.6


def chirp(rate=RATE):
    """The latency marker: a 60 ms rising linear sweep with Hann edges."""
    count = int(CHIRP_SECONDS * rate)
    lo, hi = CHIRP_HZ
    out = []
    for i in range(count):
        t = i / rate
        phase = 2 * math.pi * (lo * t + (hi - lo) * t * t / (2 * CHIRP_SECONDS))
        edge = 0.5 - 0.5 * math.cos(2 * math.pi * i / (count - 1))
        out.append(CHIRP_LEVEL * edge * math.sin(phase))
    return out


def _piper(text, voice):
    """Samples at RATE for `text`, said by the piper voice named `voice`."""
    if not VOICE_NAME.fullmatch(voice) or not isinstance(text, str):
        raise ValueError(f"not a piper voice name: {voice!r}")
    exe = os.environ.get("SLIMM_PIPER") or os.path.expanduser(
        "~/.slimm-scratch/piper-venv/bin/piper")
    folder = os.environ.get("SLIMM_PIPER_VOICES") or os.path.expanduser(
        "~/.slimm-scratch/piper-voices")
    raw = subprocess.run(
        [exe, "-m", os.path.join(folder, voice + ".onnx"), "--output-raw"],
        input=text.encode(), capture_output=True, check=True).stdout
    sample_rate = _voice_rate(os.path.join(folder, voice + ".onnx.json"))
    pcm = subprocess.run(
        ["ffmpeg", "-v", "error", "-f", "s16le", "-ar", str(sample_rate), "-ac", "1",
         "-i", "-", "-f", "s16le", "-ar", str(RATE), "-ac", "1", "-"],
        input=raw, capture_output=True, check=True).stdout
    return [v / 32768.0 for v in (int.from_bytes(pcm[i:i + 2], "little", signed=True)
                                  for i in range(0, len(pcm) - 1, 2))]


def _voice_rate(path):
    import json
    with open(path) as fh:
        return int(json.load(fh)["audio"]["sample_rate"])


def _normalise(samples):
    top = max((abs(v) for v in samples), default=0.0) or 1.0
    return [v * PEAK / top for v in samples]


def build_speech(who="A"):
    """About 40 s of sentences with 0.8 s gaps; silence leads and trails."""
    gap = [0.0] * int(0.8 * RATE)
    out = [0.0] * RATE
    for text in SENTENCES[who]:
        out += _piper(text, VOICES[who]) + gap
    return _normalise(out)


def build_latency(who="A", cycles=20):
    """A chirp, half a second of silence, a short phrase, a pause; repeated.

    Returns `(samples, chirp_times)` with each chirp's start in seconds.
    """
    marker, times, out = chirp(), [], [0.0] * int(0.5 * RATE)
    phrases = [_piper(p, VOICES[who]) for p in LATENCY_PHRASES[who]]
    speech_peak = max(abs(v) for p in phrases for v in p)
    for i in range(cycles):
        times.append(len(out) / RATE)
        phrase = [v * PEAK / speech_peak for v in phrases[i % len(phrases)]]
        out += marker + [0.0] * int(0.5 * RATE) + phrase + [0.0] * int(0.4 * RATE)
    return out, times


def build_gapped(who="A", gap_s=2.6):
    """Sentences with long gaps, plus each sentence's `(start, end)` seconds.

    The gaps are long enough to hold a noise event with clean air around it.
    """
    gap = [0.0] * int(gap_s * RATE)
    out, spans = [0.0] * RATE, []
    sentences = [_piper(text, VOICES[who]) for text in SENTENCES[who]]
    top = max(abs(v) for s in sentences for v in s) or 1.0
    for sentence in sentences:
        start = len(out) / RATE
        out += [v * PEAK / top for v in sentence]
        spans.append((start, len(out) / RATE))
        out += gap
    return out, spans


def build_pulse(who="A", cycles=8):
    """One short phrase after 3.5 s of silence, repeated: clean speech onsets."""
    phrases = [_piper(p, VOICES[who]) for p in LATENCY_PHRASES[who]]
    out = [0.0] * int(1.5 * RATE)
    for i in range(cycles):
        out += phrases[i % len(phrases)] + [0.0] * int(3.5 * RATE)
    return _normalise(out)


def write(path, who="A", kind="speech"):
    builders = {"speech": build_speech, "pulse": build_pulse,
                "latency": lambda w: build_latency(w)[0]}
    samples = builders[kind](who)
    dsp.write_wav(path, samples, RATE)


if __name__ == "__main__":
    write(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "A", sys.argv[1])
