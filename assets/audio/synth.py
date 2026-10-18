# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The measuring stick and the WAV writer every sound in the palette goes through.

Both are deterministic on purpose: CI regenerates the committed WAVs and diffs them.
The bell below is no longer in the palette; it stays as the reference `scene_synth.dart` is tested against.
"""
from __future__ import annotations

import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.signal import lfilter

SAMPLE_RATE = 48_000

NOTIFICATION_LUFS = -20.0
OWN_ACTION_LUFS = -26.0

# The loudest 200 ms is what a brief cue is heard as, so that is what is matched.
SHORT_TERM_SECONDS = 0.2

_K_WEIGHTING = (
    ((1.53512485958697, -2.69169618940638, 1.19839281085285),
     (1.0, -1.69065929318241, 0.73248077421585)),
    ((1.0, -2.0, 1.0), (1.0, -1.99004745483398, 0.99007225036621)),
)

# Slightly inharmonic partials, so it reads as struck metal rather than an organ.
_PARTIALS = ((1.0, 1.00), (2.02, 0.24), (3.05, 0.08))


@dataclass(frozen=True)
class Note:
    """One struck note: when it starts, how high, and how long it rings."""

    start: float
    frequency: float
    seconds: float
    gain: float = 1.0


def _envelope(samples: int, seconds: float) -> np.ndarray:
    """A soft-struck envelope: 12 ms attack, exponential decay, because a linear fade sounds like turning a knob."""
    t = np.linspace(0.0, seconds, samples, endpoint=False)
    attack = np.clip(t / 0.012, 0.0, 1.0)
    decay = np.exp(-t * (4.6 / seconds))
    return attack * decay


def bell(note: Note) -> np.ndarray:
    """One note of the family's timbre."""
    samples = int(round(note.seconds * SAMPLE_RATE))
    t = np.linspace(0.0, note.seconds, samples, endpoint=False)
    voice = np.zeros(samples, dtype=np.float64)
    for multiple, amplitude in _PARTIALS:
        voice += amplitude * np.sin(2.0 * np.pi * note.frequency * multiple * t)
    return voice * _envelope(samples, note.seconds) * note.gain


def render(notes: list[Note], tail: float = 0.05) -> np.ndarray:
    """Lay the notes onto one timeline, overlapping where they overlap."""
    end = max(n.start + n.seconds for n in notes) + tail
    out = np.zeros(int(round(end * SAMPLE_RATE)), dtype=np.float64)
    for note in notes:
        rendered = bell(note)
        at = int(round(note.start * SAMPLE_RATE))
        out[at:at + rendered.size] += rendered
    return out



def loudness(signal: np.ndarray) -> float:
    """The loudest short-term K-weighted moment in the clip, in LUFS."""
    weighted = signal.astype(np.float64)
    for b, a in _K_WEIGHTING:
        weighted = lfilter(b, a, weighted)
    squared = weighted ** 2
    window = int(SHORT_TERM_SECONDS * SAMPLE_RATE)
    if squared.size <= window:
        mean_square = float(np.mean(squared))
    else:
        cumulative = np.concatenate([[0.0], np.cumsum(squared)])
        mean_square = float(np.max(cumulative[window:] - cumulative[:-window]) / window)
    if mean_square <= 0.0:
        return float("-inf")
    return -0.691 + 10.0 * np.log10(mean_square)


def write_wav(path: Path, signal: np.ndarray) -> int:
    """Write 16-bit mono, rounding the same way on every machine."""
    ints = np.round(np.clip(signal, -1.0, 1.0) * 32767.0).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(ints.tobytes())
    return path.stat().st_size
