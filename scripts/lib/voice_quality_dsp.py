# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Signal primitives for the voice quality analysis: stdlib, numpy only as a speed-up.

Everything runs at ANALYSIS_RATE; a 48kHz capture is box-averaged down first.
"""
import cmath
import math
import struct
import wave

try:
    import numpy as np
except ImportError:  # the pure-python path is the contract, numpy only makes it faster
    np = None

ANALYSIS_RATE = 16_000
FRAME = 512
HOP = 160
BINS = FRAME // 2 + 1
FLOOR_DB = -120.0


def read_wav(path):
    """`(samples in -1..1, rate)` of the first channel of a 16-bit PCM WAV."""
    with wave.open(path, "rb") as wav:
        if wav.getsampwidth() != 2:
            raise ValueError(f"{path}: only 16-bit PCM is supported")
        channels, rate = wav.getnchannels(), wav.getframerate()
        raw = wav.readframes(wav.getnframes())
    ints = struct.unpack(f"<{len(raw) // 2}h", raw)
    return [v / 32768.0 for v in ints[::channels]], rate


def write_wav(path, samples, rate):
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        ints = [int(max(-1.0, min(1.0, s)) * 32767) for s in samples]
        out.writeframes(struct.pack(f"<{len(ints)}h", *ints))


def decimate(samples, rate):
    """Box-average `samples` down to ANALYSIS_RATE; the rate must divide evenly."""
    if rate % ANALYSIS_RATE:
        raise ValueError(f"{rate} Hz is not a multiple of {ANALYSIS_RATE}")
    step = rate // ANALYSIS_RATE
    if step == 1:
        return list(samples)
    usable = len(samples) - len(samples) % step
    return [sum(samples[i:i + step]) / step for i in range(0, usable, step)]


def to_db(power):
    return FLOOR_DB if power <= 1e-12 else 10.0 * math.log10(power)


def rms_db(block):
    if not block:
        return FLOOR_DB
    return to_db(sum(v * v for v in block) / len(block))


def fft(values, inverse=False):
    """Iterative radix-2 FFT of a power-of-two list; the inverse is scaled."""
    n = len(values)
    if np is not None:
        arr = np.asarray(values, dtype=complex)
        out = np.fft.ifft(arr) if inverse else np.fft.fft(arr)
        return out.tolist()
    out = list(values)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    sign = 1 if inverse else -1
    length = 2
    while length <= n:
        step = cmath.exp(sign * 2j * math.pi / length)
        half = length // 2
        twiddles = [1 + 0j] * half
        for k in range(1, half):
            twiddles[k] = twiddles[k - 1] * step
        for start in range(0, n, length):
            for k in range(half):
                a = out[start + k]
                b = out[start + k + half] * twiddles[k]
                out[start + k] = a + b
                out[start + k + half] = a - b
        length <<= 1
    return [v / n for v in out] if inverse else out


_WINDOW = [0.5 - 0.5 * math.cos(2 * math.pi * i / FRAME) for i in range(FRAME)]


def frame_starts(length):
    return range(0, max(0, length - FRAME + 1), HOP)


def power_spectrogram(signal):
    """One power spectrum (BINS long) per 10 ms hop of a 32 ms Hann window."""
    starts = list(frame_starts(len(signal)))
    if np is not None:
        if not starts:
            return []
        arr = np.asarray(signal, dtype=float)
        frames = np.stack([arr[s:s + FRAME] * _WINDOW for s in starts])
        return (np.abs(np.fft.rfft(frames, axis=1)) ** 2 / FRAME).tolist()
    out = []
    for i in range(0, len(starts), 2):
        first = signal[starts[i]:starts[i] + FRAME]
        second = (signal[starts[i + 1]:starts[i + 1] + FRAME]
                  if i + 1 < len(starts) else [0.0] * FRAME)
        packed = fft([complex(a * w, b * w)
                      for a, b, w in zip(first, second, _WINDOW)])
        out.append(_half(packed, 0))
        if i + 1 < len(starts):
            out.append(_half(packed, 1))
    return out


def _half(packed, which):
    """Power spectrum of one of two real frames packed as real and imaginary parts."""
    n = FRAME
    spec = []
    for k in range(BINS):
        z, zc = packed[k], packed[(n - k) % n].conjugate()
        value = (z + zc) / 2 if which == 0 else (z - zc) / 2j
        spec.append(abs(value) ** 2 / FRAME)
    return spec
