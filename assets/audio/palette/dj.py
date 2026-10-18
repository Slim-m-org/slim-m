# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Club pluck kit: the call ring and the member leave cue, from filtered saws, squares and FM plucks."""
from __future__ import annotations

import numpy as np
from scipy import signal as sg

from synth import NOTIFICATION_LUFS as NOTIF, SAMPLE_RATE as SR, loudness

CEIL = 10 ** (-1.6 / 20)  # sample ceiling, leaves room for the true peak
# Each sound's noise seed is its place among the 16 names of the full kit, so trimming the kit kept the bytes.
SEED_BASE = 1107
KIT_ORDER = {"call_ring": 0, "member_leave": 7}


def hz(midi: float) -> float:
    return 440.0 * 2 ** ((midi - 69) / 12)


def tt(dur: float) -> np.ndarray:
    return np.arange(int(round(dur * SR))) / SR


def env(t, attack=0.0015, tau=0.06):
    return np.clip(t / attack, 0, 1) * np.exp(-t / tau)


def freq_track(f, t, glide=0.0, gtau=0.03):
    return f * 2 ** (glide * np.exp(-t / gtau))


def fm(f, dur, ratio=2.0, index=2.0, itau=0.03, tau=0.06, attack=0.0015, glide=0.0, gtau=0.03, gain=1.0):
    t = tt(dur)
    ft = freq_track(f, t, glide, gtau)
    ph = 2 * np.pi * np.cumsum(ft) / SR
    mod = np.sin(ratio * ph) * index * np.exp(-t / itau)
    return gain * np.sin(ph + mod) * env(t, attack, tau)


def subtractive(f, dur, kind="saw", fc0=3000.0, fc1=700.0, ftau=0.06, tau=0.08,
                attack=0.0015, glide=0.0, gtau=0.03, detune=0.0, gain=1.0):
    """Additive band-limited saw or square with a swept 12 dB/oct low-pass."""
    t = tt(dur)
    ft = freq_track(f, t, glide, gtau)
    fc = fc1 + (fc0 - fc1) * np.exp(-t / ftau)
    out = np.zeros_like(t)
    voices = [-detune, detune] if detune else [0.0]
    for d in voices:
        ph = 2 * np.pi * np.cumsum(ft * 2 ** (d / 1200)) / SR
        step = 1 if kind == "saw" else 2
        for k in range(1, 60, step):
            fk = ft * k
            amp = (1.0 / k) / np.sqrt(1 + (fk / fc) ** 4)
            amp = np.where(fk < 12000, amp, 0.0)
            out += amp * np.sin(k * ph)
    return gain * out * env(t, attack, tau) / len(voices)


def noise_hit(rng, dur, lo, hi, tau=0.004, gain=1.0):
    t = tt(dur)
    n = rng.standard_normal(t.size)
    sos = sg.butter(2, [lo, hi], btype="band", fs=SR, output="sos")
    return gain * sg.sosfilt(sos, n) * env(t, 0.0005, tau)


def thump(dur=0.05, f0=900.0, f1=380.0, gain=1.0):
    t = tt(dur)
    f = f1 + (f0 - f1) * np.exp(-t / 0.008)
    return gain * np.sin(2 * np.pi * np.cumsum(f) / SR) * env(t, 0.0008, 0.012)


def place(buf, sig, start, gain=1.0):
    i = int(round(start * SR))
    j = min(buf.size, i + sig.size)
    if j > i:
        buf[i:j] += gain * sig[: j - i]


def echo(x, delay, fb=0.3, taps=3):
    out = x.copy()
    d = int(delay * SR)
    for k in range(1, taps + 1):
        sh = np.zeros_like(x)
        sh[k * d:] = x[: x.size - k * d] if k * d < x.size else 0
        lp = sg.sosfilt(sg.butter(1, 2500, fs=SR, output="sos"), sh)
        out += (fb ** k) * lp
    return out


def reverb(x, wet=0.18, size=1.0):
    acc = np.zeros_like(x)
    for ms, g in ((23.1, 0.60), (29.3, 0.58), (34.7, 0.56), (41.9, 0.54)):
        d = int(ms * size * SR / 1000)
        a = np.zeros(d + 1)
        a[0], a[d] = 1.0, -g
        acc += sg.lfilter([1.0], a, x)
    for ms, g in ((5.0, 0.5), (1.7, 0.5)):
        d = int(ms * SR / 1000)
        b = np.zeros(d + 1)
        a = np.zeros(d + 1)
        b[0], b[d] = g, 1.0
        a[0], a[d] = 1.0, g
        acc = sg.lfilter(b, a, acc)
    acc = sg.sosfilt(sg.butter(2, [450, 4500], btype="band", fs=SR, output="sos"), acc)
    return x + wet * acc / 2


def loop_fx(x, fx):
    """Run fx on three tiled copies and keep the middle one, so the tail wraps."""
    n = x.size
    return fx(np.tile(x, 3))[n:2 * n]


def finish(x, target, length, fade_out=0.006):
    x = x[: int(round(length * SR))]
    x = np.pad(x, (0, int(round(length * SR)) - x.size))
    x = sg.sosfilt(sg.butter(2, 250, btype="high", fs=SR, output="sos"), x)
    x = x - x.mean()
    g = 10 ** ((target - loudness(x)) / 20)
    for _ in range(12):
        y = CEIL * np.tanh(x * g / CEIL)
        err = target - loudness(y)
        if abs(err) < 0.05:
            break
        g *= 10 ** (err / 20)
    fi, fo = int(0.002 * SR), int(fade_out * SR)
    y[:fi] *= np.sin(np.linspace(0, np.pi / 2, fi)) ** 2
    y[-fo:] *= np.cos(np.linspace(0, np.pi / 2, fo)) ** 2
    return y


E5, A5, C6, D6, E6 = 76, 81, 84, 86, 88
A4 = 69


def member_leave(rng):
    x = np.zeros(int(0.5 * SR))
    for i, m in enumerate((C6, A5, E5)):
        place(x, subtractive(hz(m), 0.22, "square", fc0=1800, fc1=500, ftau=0.05,
                             tau=0.05, detune=5), 0.08 * i, 1.0 - 0.1 * i)
    return reverb(x, 0.12, 0.9)


def call_ring(rng):
    step = 0.175
    x = np.zeros(int(16 * step * SR))
    pat = {0: A5, 2: E5, 3: A5, 5: C6, 7: E5, 8: D6, 10: A5, 11: D6, 13: E6, 15: C6}
    kw = dict(kind="saw", fc0=3200, fc1=900, ftau=0.05, tau=0.1, detune=7)
    for s, m in pat.items():
        vel = 1.0 if s % 8 == 0 else 0.75
        place(x, subtractive(hz(m), 0.3, **kw), s * step, vel)
    for s in (0, 8):
        place(x, fm(hz(A5 + 12), 0.3, 3.5, 1.2, 0.04, 0.08), s * step, 0.2)
    for s in (0, 4, 8, 12):
        place(x, thump(0.05, 900, 400), s * step, 0.55 if s % 8 == 0 else 0.35)
    for s in (2, 6, 10, 14):
        place(x, noise_hit(rng, 0.05, 6000, 9500, 0.012), s * step, 0.05)
    return loop_fx(x, lambda y: reverb(echo(y, step * 3, 0.35, 2), 0.16, 1.1))


# name -> (builder, target LUFS, seconds)
SOUNDS = {
    "call_ring": (call_ring, NOTIF, 16 * 0.175),
    "member_leave": (member_leave, NOTIF, 0.5),
}


def render_all() -> dict[str, np.ndarray]:
    out = {}
    for name, (build, target, length) in SOUNDS.items():
        rng = np.random.default_rng(SEED_BASE + KIT_ORDER[name])
        out[name] = finish(build(rng), target, length)
    return out
