# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Writes the speech-over-steady-noise WAV the noise suppression scenario captures.

Same voice as make_fake_voice.py, but it speaks for a stretch and then stops,
and a steady fan-like noise runs underneath all of it. The quiet stretch is
what makes the noise floor measurable at the other end of a call, and the
speech stretch is what proves suppression did not eat the voice. Seeded, so
every run captures byte-identical audio.

Chrome loops the file; the loop is long enough to hold several syllables and a
clear gap.
"""
import random
import struct
import sys
import wave

import make_fake_voice as voice

SECONDS = 6
SPEECH_SECONDS = 2.4
NOISE_RMS = 0.03
SEED = 20261018
# One-pole low-pass coefficient: darkens white noise toward a fan's hiss.
SMOOTHING = 0.6


def noise_samples(count, rng):
    """Smoothed Gaussian noise scaled to `NOISE_RMS`."""
    raw = []
    previous = 0.0
    for _ in range(count):
        previous = SMOOTHING * previous + (1 - SMOOTHING) * rng.gauss(0, 1)
        raw.append(previous)
    power = sum(v * v for v in raw) / count
    scale = NOISE_RMS / (power ** 0.5)
    return [v * scale for v in raw]


def samples():
    rng = random.Random(SEED)
    total = voice.RATE * SECONDS
    noise = noise_samples(total, rng)
    speech = list(voice.samples())
    cutoff = int(voice.RATE * SPEECH_SECONDS)
    for i in range(total):
        talk = speech[i % len(speech)] / 32767 if i < cutoff else 0.0
        mixed = talk + noise[i]
        yield int(max(-1.0, min(1.0, mixed)) * 32767)


def write(path):
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(voice.RATE)
        out.writeframes(b"".join(struct.pack("<h", s) for s in samples()))


if __name__ == "__main__":
    write(sys.argv[1] if len(sys.argv) > 1 else "noisy-voice.wav")
