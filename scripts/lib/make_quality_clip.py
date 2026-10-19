# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The reference clips the voice quality harness plays through a call.

Voiced syllables with moving pitch and vowel formants (the part a speech codec
is tuned for), log sine sweeps (the part it is not), and silence gaps with
nothing in them, so any sound heard there is an artefact. Deliberately free of
noise and steady tones: both are anomaly classes the analysis hunts for.

Two variants differ in pitch, wording and sweep, so a call carries a different
voice each way. 48kHz mono 16-bit, which is what Chrome's fake capture needs.
"""
import math
import random
import sys

import voice_quality_dsp as dsp

RATE = 48_000
VOWELS = ((700, 1200), (500, 1800), (300, 2300), (500, 900), (350, 700))
HARMONICS = 14
PEAK = 0.5

# (kind, seconds, sweep start Hz, sweep end Hz)
LAYOUTS = {
    "A": (("silence", 1.0), ("speech", 11.0), ("silence", 0.7),
          ("sweep", 3.0, 200, 3400), ("silence", 0.9), ("speech", 9.0),
          ("silence", 0.7), ("sweep", 3.0, 3400, 200), ("silence", 1.0),
          ("speech", 8.0), ("silence", 1.2)),
    "B": (("silence", 1.2), ("speech", 8.0), ("silence", 0.8),
          ("sweep", 4.0, 300, 2800), ("silence", 1.0), ("speech", 11.0),
          ("silence", 0.6), ("sweep", 2.5, 2800, 300), ("silence", 0.8),
          ("speech", 9.0), ("silence", 1.0)),
}
PITCH = {"A": 125.0, "B": 190.0}
SEED = {"A": 11, "B": 23}


def _syllable(count, base, shape):
    """`count` samples of one voiced syllable at pitch contour `shape`."""
    f1, f2 = shape["vowel"]
    amps = []
    for h in range(1, HARMONICS + 1):
        f = h * base
        gain = 1.0 / h * (1 + 4 * math.exp(-((f - f1) / 150) ** 2)
                          + 3 * math.exp(-((f - f2) / 250) ** 2))
        amps.append(gain)
    norm = sum(amps)
    out, phase = [], 0.0
    attack, release = int(0.02 * RATE), int(0.04 * RATE)
    for i in range(count):
        pitch = base * (1 + shape["glide"] * (i / count - 0.5))
        phase += 2 * math.pi * pitch / RATE
        value = sum(a * math.sin(h * phase)
                    for h, a in enumerate(amps, start=1)) / norm
        env = min(1.0, i / attack, (count - i) / release)
        out.append(value * env)
    return out


def _speech(seconds, variant, rng):
    total, out = int(seconds * RATE), []
    base = PITCH[variant]
    while len(out) < total:
        for _ in range(rng.randint(3, 4)):
            count = int(rng.uniform(0.16, 0.24) * RATE)
            shape = {"vowel": rng.choice(VOWELS), "glide": rng.uniform(-0.3, 0.3)}
            out += _syllable(count, base * rng.uniform(0.9, 1.15), shape)
            out += [0.0] * int(0.05 * RATE)
        out += [0.0] * int(0.25 * RATE)
    return out[:total]


def _sweep(seconds, start, end):
    count, out, phase = int(seconds * RATE), [], 0.0
    ratio = end / start
    fade = int(0.05 * RATE)
    for i in range(count):
        freq = start * ratio ** (i / count)
        phase += 2 * math.pi * freq / RATE
        out.append(0.8 * math.sin(phase) * min(1.0, i / fade, (count - i) / fade))
    return out


def build(variant="A"):
    rng = random.Random(SEED[variant])
    out = []
    for part in LAYOUTS[variant]:
        kind, seconds, *sweep = part
        if kind == "silence":
            out += [0.0] * int(seconds * RATE)
        elif kind == "speech":
            out += _speech(seconds, variant, rng)
        else:
            out += _sweep(seconds, *sweep)
    top = max(abs(v) for v in out)
    return [v * PEAK / top for v in out]


def silence_spans(variant="A"):
    """`(start, end)` seconds of every silence gap, for tests that probe them."""
    spans, at = [], 0.0
    for part in LAYOUTS[variant]:
        if part[0] == "silence":
            spans.append((at, at + part[1]))
        at += part[1]
    return spans


def write(path, variant="A"):
    dsp.write_wav(path, build(variant), RATE)


if __name__ == "__main__":
    write(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "A")
