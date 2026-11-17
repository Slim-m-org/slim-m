# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Writes the WAV Chrome captures as a microphone during an e2e run.

Chrome's built-in `--use-fake-device-for-media-stream` tone is not loud enough
for LiveKit to call it speech: a real run reached the call with both tiles on
screen, correctly named, and neither ever flagged as speaking. The mechanism
was fine and the audio was not, so this supplies audio that is.

Speech-shaped rather than a pure tone, because voice-activity detection is
built to ignore steady tones: a fundamental around 160Hz with a few harmonics,
amplitude-modulated into syllable-length bursts with gaps between them, which
is the shape of a voice as far as a level detector is concerned. Loud, at
roughly half full scale, since the whole point is to clear a threshold.

Chrome loops the file, so a few seconds covers a scenario of any length.
16-bit PCM mono at 48kHz, which is what Chrome requires and what the SFU wants
anyway.
"""
import math
import struct
import sys
import wave

RATE = 48_000
SECONDS = 4
FUNDAMENTAL = 160.0
HARMONICS = (1.0, 0.5, 0.3, 0.15)
AMPLITUDE = 0.5
# Syllables a second, and the fraction of each one that carries sound.
SYLLABLES = 4.0
DUTY = 0.65


def samples(amplitude=AMPLITUDE):
    for i in range(RATE * SECONDS):
        t = i / RATE
        # A syllable envelope: a raised-cosine burst, then a gap.
        phase = (t * SYLLABLES) % 1.0
        if phase > DUTY:
            yield 0
            continue
        envelope = 0.5 - 0.5 * math.cos(2 * math.pi * phase / DUTY)
        tone = sum(
            weight * math.sin(2 * math.pi * FUNDAMENTAL * (n + 1) * t)
            for n, weight in enumerate(HARMONICS)
        ) / sum(HARMONICS)
        yield int(max(-1.0, min(1.0, tone * envelope * amplitude)) * 32767)


def write(path, amplitude=AMPLITUDE):
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<h", s) for s in samples(amplitude)))


if __name__ == "__main__":
    write(sys.argv[1] if len(sys.argv) > 1 else "fake-voice.wav")
