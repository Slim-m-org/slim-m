#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Regenerate every interface sound from the palette modules.

The WAVs are committed and CI runs this and diffs, so a sound that drifts from the code that claims to make it fails the build:

    python3 assets/audio/generate.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import synth  # noqa: E402
from palette import dj, game_ui, kenney, theorist  # noqa: E402

OUT = HERE / "notifications"

# CallKit loops a file on its own, so the ringtone is the call_ring loop three times with a real pause between.
RINGTONE_REPEATS = 3
RINGTONE_PAUSE_SECONDS = 1.5
PEAK_CEILING = 10 ** (-1.0 / 20)


def render_palette() -> dict[str, np.ndarray]:
    sounds: dict[str, np.ndarray] = {}
    for module in (theorist, dj, game_ui, kenney):
        sounds.update(module.render_all())
    return sounds


def callkit_ringtone(call_ring: np.ndarray) -> np.ndarray:
    pause = np.zeros(int(RINGTONE_PAUSE_SECONDS * synth.SAMPLE_RATE))
    parts = [call_ring if i == 0 else np.concatenate([pause, call_ring])
             for i in range(RINGTONE_REPEATS)]
    joined = np.concatenate(parts)
    levelled = joined * 10 ** ((synth.NOTIFICATION_LUFS - synth.loudness(joined)) / 20)
    peak = float(np.abs(levelled).max())
    return levelled * (PEAK_CEILING / peak) if peak > PEAK_CEILING else levelled


def main() -> int:
    sounds = render_palette()
    sounds["callkit_ringtone"] = callkit_ringtone(sounds["call_ring"])
    print(f"{'sound':26} {'seconds':>8} {'LUFS':>8} {'bytes':>8}")
    for name, signal in sorted(sounds.items()):
        size = synth.write_wav(OUT / f"{name}.wav", signal)
        print(f"{name:26} {signal.size / synth.SAMPLE_RATE:8.3f} "
              f"{synth.loudness(signal):8.2f} {size:8d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
