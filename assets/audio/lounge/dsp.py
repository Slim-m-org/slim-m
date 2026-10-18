"""dj solo-call music: a lofi loop and an electronic loop, both in D major pentatonic territory.

Every event is placed modulo the loop length and every effect runs on a wrapped copy,
so tails cross the seam and the loop is gapless. numpy and scipy only, fixed seeds.
"""
from __future__ import annotations

import wave
from pathlib import Path

import numpy as np
from scipy import signal as sg

SR = 48_000
OUT = Path(__file__).resolve().parent / "wav"
TARGET = -20.0
CEIL = 10 ** (-1.4 / 20)


def hz(m):
    return 440.0 * 2 ** ((np.asarray(m, dtype=float) - 69) / 12)


class Mix:
    """A stereo circular buffer."""

    def __init__(self, seconds):
        self.n = int(round(seconds * SR))
        self.buf = np.zeros((2, self.n))

    def add(self, sig, start, pan=0.0, gain=1.0):
        """Add a mono (or 2xN) signal at start seconds, wrapping past the end."""
        s = int(round(start * SR)) % self.n
        sig = np.atleast_2d(sig)
        if sig.shape[0] == 1:
            a = (pan + 1) * np.pi / 4
            sig = np.vstack([sig[0] * np.cos(a), sig[0] * np.sin(a)]) * np.sqrt(2)
        m = sig.shape[1]
        first = min(m, self.n - s)
        self.buf[:, s:s + first] += gain * sig[:, :first]
        rest = m - first
        while rest > 0:
            k = min(rest, self.n)
            self.buf[:, :k] += gain * sig[:, first:first + k]
            first += k
            rest -= k


def circ(x, fx, pre=3.0):
    """Run fx (1-D -> 1-D, causal) on x with its own tail in front, so the loop wraps."""
    p = int(pre * SR)
    return fx(np.concatenate([x[-p:], x]))[p:]


def comb(x, d, g):
    y = x.copy()
    for i in range(d, x.size, d):
        j = min(i + d, x.size)
        y[i:j] += g * y[i - d:j - d]
    return y


def allpass(x, d, g):
    y = np.zeros_like(x)
    for i in range(0, x.size, d):
        j = min(i + d, x.size)
        prev_x = x[i - d:j - d] if i >= d else 0.0
        prev_y = y[i - d:j - d] if i >= d else 0.0
        y[i:j] = -g * x[i:j] + prev_x + g * prev_y
    return y


def reverb_ch(x, delays, wet, damp=5000.0):
    acc = np.zeros_like(x)
    for ms, g in zip(delays, (0.80, 0.78, 0.76, 0.74)):
        acc += comb(x, int(ms * SR / 1000), g)
    acc = sg.sosfilt(sg.butter(2, damp, fs=SR, output="sos"), acc)
    acc = allpass(allpass(acc, int(0.0067 * SR), 0.5), int(0.0023 * SR), 0.5)
    return x + wet * acc / 4


def reverb(mix_buf, wet=0.15):
    left = circ(mix_buf[0], lambda y: reverb_ch(y, (31.1, 37.3, 43.7, 51.9), wet))
    right = circ(mix_buf[1], lambda y: reverb_ch(y, (33.7, 39.1, 46.3, 53.3), wet))
    return np.vstack([left, right])


def echo_wet(x, d, fb, taps, tone=2800.0):
    """Only the repeats of x (no dry), each one darker, delayed by d samples."""
    sos = sg.butter(1, tone, fs=SR, output="sos")
    wet = np.zeros_like(x)
    cur = x
    for _ in range(taps):
        cur = sg.sosfilt(sos, np.concatenate([np.zeros(d), cur[:-d]])) * fb
        wet += cur
    return wet


def pingpong(stereo, d, amount=0.5, fb=0.5, taps=4):
    """Each side's repeats land on the other side, wrapped across the seam."""
    wl = circ(stereo[0], lambda y: echo_wet(y, d, fb, taps))
    wr = circ(stereo[1], lambda y: echo_wet(y, d, fb, taps))
    return stereo + amount * np.vstack([wr, wl])


# ---- voices -----------------------------------------------------------------
def tt(dur):
    return np.arange(int(round(dur * SR))) / SR


def ep(m, dur, vel=1.0, detune=0.0):
    """FM electric piano: soft bell body with a short tine."""
    f = hz(m) * 2 ** (detune / 1200)
    t = tt(dur)
    ph = 2 * np.pi * f * t
    body = np.sin(ph + (0.9 + 1.4 * vel) * np.exp(-t / 0.35) * np.sin(ph))
    tine = 0.05 * vel * np.sin(14 * ph) * np.exp(-t / 0.025)
    amp = np.clip(t / 0.004, 0, 1) * np.exp(-t / 0.9) * np.clip((dur - t) / 0.12, 0, 1)
    return (body + tine) * amp


def bar(m, dur, vel=1.0):
    f = hz(m)
    t = tt(dur)
    out = np.zeros_like(t)
    for r, a, k in ((1, 1.0, 1.0), (4, 0.28, 2.4), (10, 0.05, 4.5)):
        if f * r < 3800:
            out += a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * k * 5.0 / dur)
    return vel * out * np.clip(t / 0.003, 0, 1)


def bass(m, dur, vel=1.0):
    f = hz(m)
    t = tt(dur)
    ph = 2 * np.pi * f * t
    out = np.sin(ph) + 0.25 * np.sin(2 * ph) + 0.08 * np.sin(3 * ph)
    return vel * out * np.clip(t / 0.01, 0, 1) * np.exp(-t / (dur * 0.5)) * np.clip((dur - t) / 0.05, 0, 1)


def kick(vel=1.0, lo=48.0, hi=135.0, tau=0.07):
    t = tt(0.4)
    f = lo + (hi - lo) * np.exp(-t / 0.025)
    return vel * np.sin(2 * np.pi * np.cumsum(f) / SR) * np.clip(t / 0.002, 0, 1) * np.exp(-t / tau)


def noise(rng, dur, lo, hi, tau, atk=0.0008):
    t = tt(dur)
    sos = sg.butter(2, [lo, hi], btype="band", fs=SR, output="sos")
    return sg.sosfilt(sos, rng.standard_normal(t.size)) * np.clip(t / atk, 0, 1) * np.exp(-t / tau)


def snare(rng, vel=1.0):
    t = tt(0.3)
    body = np.sin(2 * np.pi * 185 * t) * np.exp(-t / 0.05)
    return vel * (0.55 * noise(rng, 0.3, 1200, 6500, 0.075) + 0.5 * body)


def saw_stack(m, dur, spread=(-9, 0, 9), harmonics=26, lp=None):
    f0 = hz(m)
    t = tt(dur)
    out = np.zeros_like(t)
    for d in spread:
        f = f0 * 2 ** (d / 1200)
        for k in range(1, harmonics + 1):
            if f * k < 9000:
                out += np.sin(2 * np.pi * f * k * t + 0.7 * k * d) / k
    return out / len(spread)


# ---- master -----------------------------------------------------------------
_K = (
    ((1.53512485958697, -2.69169618940638, 1.19839281085285), (1.0, -1.69065929318241, 0.73248077421585)),
    ((1.0, -2.0, 1.0), (1.0, -1.99004745483398, 0.99007225036621)),
)


def lufs_integrated(st):
    ms = []
    for ch in st:
        y = ch
        for b, a in _K:
            y = sg.lfilter(b, a, y)
        ms.append(y)
    blk, hop = int(0.4 * SR), int(0.1 * SR)
    sq = sum(m ** 2 for m in ms)
    c = np.concatenate([[0.0], np.cumsum(sq)])
    starts = np.arange(0, sq.size - blk, hop)
    z = (c[starts + blk] - c[starts]) / blk
    l = -0.691 + 10 * np.log10(np.maximum(z, 1e-12))
    z1 = z[l > -70]
    rel = -0.691 + 10 * np.log10(z1.mean()) - 10
    z2 = z1[(-0.691 + 10 * np.log10(z1)) > rel]
    return -0.691 + 10 * np.log10(z2.mean())


def master(st, drive=1.15):
    hp = sg.butter(2, 28, "high", fs=SR, output="sos")
    st = np.vstack([circ(c, lambda y: sg.sosfilt(hp, y), 3.0) for c in st])
    g = 1.0
    for _ in range(10):
        y = np.tanh(st * g * drive) / drive
        peak = np.abs(y).max()
        if peak > CEIL:
            y = y * CEIL / peak
        err = TARGET - lufs_integrated(y)
        if abs(err) < 0.03:
            break
        g *= 10 ** (err / 20)
    return y


def write(name, st):
    OUT.mkdir(exist_ok=True)
    ints = np.round(np.clip(st, -1, 1) * 32767).astype("<i2").T.copy()
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(ints.tobytes())


def lowpass(x, fc, order=2):
    sos = sg.butter(order, fc, fs=SR, output="sos")
    if x.ndim == 1:
        return circ(x, lambda y: sg.sosfilt(sos, y), 1.0)
    return np.vstack([lowpass(c, fc, order) for c in x])
