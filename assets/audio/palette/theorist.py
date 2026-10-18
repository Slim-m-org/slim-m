# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Glass marimba in D: the message, join and mute cues, all D major pentatonic plus one outside tone for error."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from synth import NOTIFICATION_LUFS as NOTIF, OWN_ACTION_LUFS as OWN, SAMPLE_RATE as SR, loudness

D5, E5, Fs5, A5 = 587.33, 659.25, 739.99, 880.00
D6, A6, Fs6 = 1174.66, 1760.00, 1479.98
Gs5 = 830.61

# kind -> (partial ratio, amplitude, decay multiplier); the bar is tuned 1:4:10 so octaves never beat.
TIMBRES = {
    "bar": [(1.0, 1.00, 1.0), (4.0, 0.30, 2.4), (10.0, 0.06, 4.5)],
    "felt": [(1.0, 1.00, 1.0), (4.0, 0.07, 3.0)],
}
ATTACK = {"bar": 0.004, "felt": 0.006}
DECAY_DB = {"bar": 46.0, "felt": 46.0}


@dataclass(frozen=True)
class N:
    start: float
    freq: float
    dur: float
    gain: float = 1.0
    kind: str = "bar"
    bend: float = 0.0  # starting offset in semitones, glides to 0 over 40 ms


def voice(n: N) -> np.ndarray:
    count = int(round(n.dur * SR))
    t = np.arange(count) / SR
    inst = np.full(count, n.freq)
    if n.bend:
        inst = n.freq * 2.0 ** ((n.bend / 12.0) * np.clip(1.0 - t / 0.04, 0.0, 1.0))
    phase = 2 * np.pi * np.cumsum(inst) / SR
    k = DECAY_DB[n.kind] / 20.0 * np.log(10.0) / n.dur
    out = np.zeros(count)
    for ratio, amp, mult in TIMBRES[n.kind]:
        pf = n.freq * ratio
        if pf > 4200.0:
            continue
        # upper partials stay out of the 2 to 5 kHz harshness zone
        amp = amp * min(1.0, (2300.0 / pf) ** 2) if ratio > 1.0 else amp
        out += amp * np.sin(phase * ratio) * np.exp(-t * k * mult)
    attack = ATTACK[n.kind]
    out *= np.sin(np.clip(t / attack, 0, 1) * np.pi / 2) ** 2
    tail = int(0.006 * SR)
    out[-tail:] *= np.cos(np.linspace(0, np.pi / 2, tail)) ** 2
    return out * n.gain


def render(notes: list[N], total: float) -> np.ndarray:
    sig = np.zeros(int(round(total * SR)))
    for n in notes:
        v = voice(n)
        at = int(round(n.start * SR))
        sig[at:at + v.size] += v[: sig.size - at]
    return sig


def finish(sig: np.ndarray, target: float) -> np.ndarray:
    sig = sig - np.mean(sig)
    out = sig * 10 ** ((target - loudness(sig)) / 20)
    peak = np.max(np.abs(out))
    ceil = 10 ** (-1.5 / 20)
    if peak > ceil:
        out *= ceil / peak
    f = int(0.005 * SR)
    out[:f] *= np.sin(np.linspace(0, np.pi / 2, f)) ** 2
    out[-f:] *= np.cos(np.linspace(0, np.pi / 2, f)) ** 2
    return out


# name -> (notes, total seconds, target LUFS)
SOUNDS: dict[str, tuple[list[N], float, float]] = {
    "direct_message": ([N(0.00, A5, 0.22, 0.9), N(0.10, D6, 0.36, 1.0), N(0.10, Fs6, 0.36, 0.55)], 0.46, NOTIF),
    "mention": ([N(0.00, D6, 0.24, 0.9), N(0.11, A6, 0.40, 1.0), N(0.34, A6, 0.30, 0.40)], 0.66, NOTIF),
    "group_message": ([N(0.00, Fs5, 0.30, 1.0)], 0.30, NOTIF),
    "member_join": ([N(0.00, Fs5, 0.22), N(0.09, A5, 0.22), N(0.18, D6, 0.38)], 0.56, NOTIF),
    "error": ([N(0.00, Gs5, 0.24, 1.0, "bar"), N(0.13, D5, 0.36, 0.95, "felt", -0.35)], 0.50, NOTIF),
    "message_sent": ([N(0.00, D6, 0.20, 1.0, "bar", -2.0)], 0.20, OWN),
    "message_received_in_view": ([N(0.00, Fs5, 0.17, 1.0, "felt")], 0.17, OWN),
    "mute_off": ([N(0.00, Fs5, 0.11, 0.9), N(0.06, A5, 0.14, 1.0)], 0.20, OWN),
}


def render_all() -> dict[str, np.ndarray]:
    return {name: finish(render(notes, total), target)
            for name, (notes, total, target) in SOUNDS.items()}
