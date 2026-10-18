# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Cockpit switches: the mute-on cue, a click transient with a short tonal body."""
from __future__ import annotations

import numpy as np
from scipy import signal as sg

from synth import OWN_ACTION_LUFS as OWN, SAMPLE_RATE as SR, loudness


def tt(sec): return np.arange(int(round(sec * SR))) / SR


def highpass(x, fc, order=2): return sg.sosfilt(sg.butter(order, fc, "hp", fs=SR, output="sos"), x)


def env(n, attack, tau):
    t = np.arange(n) / SR
    return np.clip(t / attack, 0, 1) * np.exp(-t / tau)


def tone(f, sec, tau, attack=0.003, parts=((1, 1.0), (2.0, 0.12)), glide=None):
    """Sine stack; glide=(f_end, glide_tau) sweeps the pitch exponentially."""
    t = tt(sec)
    fr = f * np.ones_like(t) if glide is None else glide[0] + (f - glide[0]) * np.exp(-t / glide[1])
    ph = 2 * np.pi * np.cumsum(fr) / SR
    x = sum(a * np.sin(m * ph) for m, a in parts)
    return x * env(t.size, attack, tau)


def tick(rng, fc, sec=0.012, tau=0.0018, width=0.6):
    n = rng.standard_normal(int(sec * SR))
    n = sg.sosfilt(sg.butter(2, [fc * (1 - width / 2), fc * (1 + width / 2)], "bp", fs=SR, output="sos"), n)
    return n * env(n.size, 0.0003, tau)


def put(buf, x, at, gain=1.0):
    i = int(round(at * SR))
    buf[i:i + x.size] += x[: buf.size - i] * gain


def true_peak_db(x):
    return 20 * np.log10(np.max(np.abs(sg.resample_poly(x, 4, 1))) + 1e-12)


def finish(x, target):
    # 2.5 ms of lead-in silence keeps the first 2 ms at exactly zero without softening the click.
    f = int(0.002 * SR)
    x = np.concatenate([np.zeros(int(0.0025 * SR)), x])
    x[-f:] *= np.linspace(1, 0, f)
    x = x - x.mean()
    for _ in range(8):
        x = x * 10 ** ((target - loudness(x)) / 20)
        if true_peak_db(x) <= -1.2:
            break
        # a transient too tall for the level is rounded gently, then re-levelled
        lim = 10 ** (-3.0 / 20)
        x = np.where(np.abs(x) > lim, np.sign(x) * (lim + np.tanh((np.abs(x) - lim) / 0.3) * 0.3 * 0.5), x)
    return x


def mute_on():
    rng = np.random.default_rng(sum(map(ord, "muteon")) + 7)
    b = np.zeros(int(round(0.17 * SR)))
    put(b, tick(rng, 1500, 0.01, 0.0018), 0, 1.0)
    put(b, tone(1100, 0.14, 0.03, attack=0.001, glide=(560, 0.02), parts=((1, 1.0), (2, 0.08))), 0, 0.9)
    return highpass(b, 320)


def render_all() -> dict[str, np.ndarray]:
    return {"mute_on": finish(mute_on(), OWN)}
