# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A speech clip with a noisy room mixed in: fan hum, keyboard typing and a dog bark.

Generated, not recorded, so nothing needs a licence: the fan is a few mains
harmonics plus low-passed hiss, a keystroke is a damped click over a short
thump, a bark is a gliding harmonic burst with two formants. Events are placed
from the sentence spans so some land in clean gaps (what the suppressor should
remove) and some on top of speech (what it should leave alone or ignore).
`events` names each one with its start and end in seconds.
"""
import math
import random

RATE = 48_000
HUM_RMS = 0.012
TYPING_PEAK = 0.14
BARK_PEAK = 0.35


def _fan(count, rng):
    out, state = [], 0.0
    for i in range(count):
        t = i / RATE
        hum = (math.sin(2 * math.pi * 100 * t) + 0.6 * math.sin(2 * math.pi * 200 * t)
               + 0.35 * math.sin(2 * math.pi * 300 * t) + 0.2 * math.sin(2 * math.pi * 420 * t))
        state += 0.08 * (rng.uniform(-1, 1) - state)
        out.append(hum * 0.5 + state * 2.2)
    rms = math.sqrt(sum(v * v for v in out) / len(out)) or 1.0
    return [v * HUM_RMS / rms for v in out]


def _keystroke(rng):
    length = int(0.04 * RATE)
    thump = rng.uniform(220, 380)
    out = []
    for i in range(length):
        t = i / RATE
        click = rng.uniform(-1, 1) * math.exp(-t / 0.0012)
        body = math.sin(2 * math.pi * thump * t) * math.exp(-t / 0.012) * 0.6
        out.append(TYPING_PEAK * (0.7 * click + body))
    return out


def _typing(start_s, strokes, rng, total):
    """A bed of `strokes` keystrokes from `start_s`, and the time the last one ends."""
    bed = [0.0] * total
    at = start_s
    for _ in range(strokes):
        for i, v in enumerate(_keystroke(rng)):
            idx = int(at * RATE) + i
            if idx < total:
                bed[idx] += v
        at += rng.uniform(0.09, 0.22)
    return bed, at


def _bark(rng):
    pitch, length = rng.uniform(380, 480), int(0.24 * RATE)
    phase, out = 0.0, []
    for i in range(length):
        f0 = pitch * (1 - 0.25 * i / length)
        phase += 2 * math.pi * f0 / RATE
        value = 0.0
        for h in range(1, 13):
            f = h * f0
            gain = (1 + 3 * math.exp(-((f - 900) / 300) ** 2)
                    + 2 * math.exp(-((f - 2000) / 500) ** 2)) / h
            value += gain * math.sin(h * phase)
        env = min(1.0, i / (0.01 * RATE)) * math.exp(-i / (0.09 * RATE))
        out.append(value * env)
    top = max(abs(v) for v in out) or 1.0
    return [v * BARK_PEAK / top for v in out]


def _barks(start_s, number, rng, total):
    bed, at = [0.0] * total, start_s
    for _ in range(number):
        for i, v in enumerate(_bark(rng)):
            idx = int(at * RATE) + i
            if idx < total:
                bed[idx] += v
        at += 0.5
    return bed, at


def plan(spans):
    """Where each event goes: `(kind, start_s)` from the sentence spans.

    Six or more spans keep the fixed places every earlier measurement used;
    a short clip with fewer spreads the same four events over what it has.
    """
    assert spans, "the noise plan needs at least one speech span"
    last = len(spans) - 1
    at = [0, 2, 3, 5] if last >= 5 else [round(i * last / 5) for i in (0, 2, 3, 5)]
    return [("typing_gap", spans[at[0]][1] + 0.5), ("typing_speech", spans[at[1]][0] + 0.6),
            ("bark_gap", spans[at[2]][1] + 0.7), ("bark_speech", spans[at[3]][0] + 1.0)]


def mix(speech, spans, seed=5):
    """`(noisy samples, events)`; events are `{kind, start, end}` in seconds."""
    rng = random.Random(seed)
    total = len(speech)
    beds, events = [_fan(total, rng)], []
    for kind, start in plan(spans):
        if kind.startswith("typing"):
            bed, end = _typing(start, 10, rng, total)
        else:
            bed, end = _barks(start, 2, rng, total)
        beds.append(bed)
        events.append({"kind": kind, "start": round(start, 3), "end": round(end + 0.1, 3)})
    noisy = [s + sum(b[i] for b in beds) for i, s in enumerate(speech)]
    return [max(-1.0, min(1.0, v)) for v in noisy], events
