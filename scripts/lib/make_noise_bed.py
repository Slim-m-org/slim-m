# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A speech clip with a noisy room mixed in: fan hum, keyboard typing and a dog bark.

Generated, not recorded, so nothing needs a licence. Events are placed from the sentence spans so some land in clean gaps (what a suppressor should remove) and some on speech (what it should leave alone); `events` names each with its start and end in seconds.
`mix(transients=...)` adds the mouth and desk sounds a suppressor is most often blamed for (lip smacks, chewing, a swallow, a breath), synthetic or from recorded clips.
"""
import math
import random

RATE = 48_000
HUM_RMS = 0.012
TYPING_PEAK = 0.14
BARK_PEAK = 0.35
SMACK_PEAK = 0.12
CHEW_PEAK = 0.1
SWALLOW_PEAK = 0.08
BREATH_PEAK = 0.03


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


def _burst(rng, seconds, decay_s, low_hz, high_hz, peak):
    """Noise shaped by a one-pole band and an exponential decay: the body of a click or crunch."""
    length = int(seconds * RATE)
    low_a, high_a = math.exp(-2 * math.pi * low_hz / RATE), math.exp(-2 * math.pi * high_hz / RATE)
    low_state = high_state = 0.0
    out = []
    for i in range(length):
        white = rng.uniform(-1, 1)
        high_state = high_a * high_state + (1 - high_a) * white
        low_state = low_a * low_state + (1 - low_a) * high_state
        out.append((high_state - low_state) * math.exp(-i / (decay_s * RATE)))
    top = max((abs(v) for v in out), default=1.0) or 1.0
    return [v * peak / top for v in out]


def _smack(rng):
    """A lip smack: a 6 ms click with a 2 kHz ring."""
    return _burst(rng, 0.012, 0.0015, 900, 5000, SMACK_PEAK)


def _crunch(rng):
    """One bite of something crisp: 35 ms of broadband crackle."""
    return _burst(rng, 0.05, 0.012, 700, 6000, CHEW_PEAK)


def _swallow(rng):
    """A gulp: a low thump that falls in pitch, then a soft click as the throat opens."""
    length = int(0.16 * RATE)
    phase, out = 0.0, []
    for i in range(length):
        t = i / RATE
        phase += 2 * math.pi * (140 - 70 * t / 0.16) / RATE
        out.append(math.sin(phase) * math.exp(-t / 0.05))
    click = _burst(rng, 0.01, 0.002, 1500, 4000, 0.5)
    for i, v in enumerate(click):
        idx = int(0.09 * RATE) + i
        if idx < length:
            out[idx] += v
    top = max(abs(v) for v in out) or 1.0
    return [v * SWALLOW_PEAK / top for v in out]


def _breath(rng):
    """Half a second of exhale close to the mic: dark noise with a slow rise and fall."""
    body = _burst(rng, 0.5, 10.0, 60, 1500, 1.0)
    length = len(body)
    out = [v * math.sin(math.pi * i / length) ** 2 for i, v in enumerate(body)]
    top = max(abs(v) for v in out) or 1.0
    return [v * BREATH_PEAK / top for v in out]


def _repeat(make, start_s, count, step, rng, total):
    """`count` copies of `make(rng)` from `start_s`, `step(rng)` seconds apart; returns the bed and the end."""
    bed, at = [0.0] * total, start_s
    for _ in range(count):
        for i, v in enumerate(make(rng)):
            idx = int(at * RATE) + i
            if idx < total:
                bed[idx] += v
        at += step(rng)
    return bed, at


TRANSIENTS = {
    "smack": lambda rng, start, total: _repeat(_smack, start, 3, lambda r: r.uniform(0.3, 0.5), rng, total),
    "chew": lambda rng, start, total: _repeat(_crunch, start, 6, lambda r: r.uniform(0.18, 0.28), rng, total),
    "swallow": lambda rng, start, total: _repeat(_swallow, start, 1, lambda _: 0.4, rng, total),
    "breath": lambda rng, start, total: _repeat(_breath, start, 1, lambda _: 0.8, rng, total),
}


def _fixed_slots(spans):
    """The span index each fixed event hangs off: typing gap, typing speech, bark gap, bark speech."""
    assert spans, "the noise plan needs at least one speech span"
    last = len(spans) - 1
    return [0, 2, 3, 5] if last >= 5 else [round(i * last / 5) for i in (0, 2, 3, 5)]


def plan(spans):
    """Where each event goes: `(kind, start_s)` from the sentence spans.

    Six or more spans keep the fixed places every earlier measurement used;
    a short clip with fewer spreads the same four events over what it has.
    """
    at = _fixed_slots(spans)
    return [("typing_gap", spans[at[0]][1] + 0.5), ("typing_speech", spans[at[1]][0] + 0.6),
            ("bark_gap", spans[at[2]][1] + 0.7), ("bark_speech", spans[at[3]][0] + 1.0)]


def plan_transients(spans, kinds):
    """Each transient kind once in a gap and once over speech, on spans the fixed events leave alone."""
    at = _fixed_slots(spans)
    indices = range(len(spans))
    gaps = [i for i in indices if i not in (at[0], at[2])] or list(indices)
    talks = [i for i in indices if i not in (at[1], at[3])] or list(indices)
    out = []
    for slot, kind in enumerate(kinds):
        out.append((f"{kind}_gap", spans[gaps[slot % len(gaps)]][1] + 0.9))
        out.append((f"{kind}_speech", spans[talks[(slot + 2) % len(talks)]][0] + 0.4))
    return out


def _lay(clip, start_s, total):
    bed = [0.0] * total
    for i, v in enumerate(clip):
        idx = int(start_s * RATE) + i
        if idx < total:
            bed[idx] += v
    return bed, start_s + len(clip) / RATE


def mix(speech, spans, seed=5, transients=None):
    """`(noisy samples, events)`; events are `{kind, start, end}` in seconds.

    `transients` adds mouth and desk sounds: `True` for the synthetic set, or a
    dict of kind to recorded samples (48 kHz mono in [-1, 1]) to lay real clips.
    """
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
    if transients:
        clips = TRANSIENTS if transients is True else transients
        for kind, start in plan_transients(spans, list(clips)):
            source = clips[kind.rsplit("_", 1)[0]]
            bed, end = _lay(source, start, total) if isinstance(source, list) else source(rng, start, total)
            beds.append(bed)
            events.append({"kind": kind, "start": round(start, 3), "end": round(end + 0.1, 3)})
    noisy = [s + sum(b[i] for b in beds) for i, s in enumerate(speech)]
    return [max(-1.0, min(1.0, v)) for v in noisy], events
