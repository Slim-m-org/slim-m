# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What the palette promises: one format, two level bands, no clicks, seamless loops.

Run with: python3 -m unittest discover -s assets/audio
"""
from __future__ import annotations

import re
import subprocess
import sys
import unittest
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import generate  # noqa: E402
import synth  # noqa: E402

OUT = HERE / "notifications"
DART_ENUM = (
    HERE.parent.parent / "client" / "packages" / "app" / "lib" / "src" / "audio"
    / "notification_sound.dart"
)

NOTIFICATION_FAMILY = {
    "direct_message", "mention", "group_message", "call_ring",
    "member_join", "member_leave", "error",
}
LEVEL_TOLERANCE_DB = 0.5
PEAK_CEILING_DB = -1.0
EDGE_SECONDS = 0.002
HEAD_CEILING_DB = -15.0
TAIL_CEILING_DB = -40.0
LOOP_LIMITS_SECONDS = {"call_ring": 3.0, "ringback": 4.0}
MAX_SEAM_JUMP = 0.002
# Apple's own ceiling; past this CallKit silently plays the default ringtone.
CALLKIT_MAX_SECONDS = 30.0


def read(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        assert w.getnchannels() == 1, f"{path.name} is not mono"
        assert w.getsampwidth() == 2, f"{path.name} is not 16-bit"
        assert w.getframerate() == synth.SAMPLE_RATE, f"{path.name} is not 48 kHz"
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32767.0


def db(amplitude: float) -> float:
    return 20.0 * np.log10(max(amplitude, 1e-9))


def shipped_names() -> list[str]:
    source = DART_ENUM.read_text()
    return re.findall(r"^\s+\w+\('([a-z_]+)'\)[,;]", source, re.MULTILINE)


class Palette(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.names = shipped_names()
        cls.clips = {name: read(OUT / f"{name}.wav") for name in cls.names}

    def test_every_notification_sound_in_the_client_has_a_file(self) -> None:
        self.assertEqual(len(self.names), 16, "the palette is sixteen sounds")
        for name in self.names:
            self.assertTrue((OUT / f"{name}.wav").exists(), f"{name}.wav is missing")

    def test_no_stray_files_beyond_the_palette_and_the_ringtone(self) -> None:
        present = {p.stem for p in OUT.glob("*.wav")}
        self.assertEqual(present, {*self.names, "callkit_ringtone"})

    def test_notifications_sit_at_minus_20_and_own_actions_at_minus_26(self) -> None:
        for name, clip in self.clips.items():
            target = -20.0 if name in NOTIFICATION_FAMILY else -26.0
            with self.subTest(name):
                self.assertAlmostEqual(
                    synth.loudness(clip), target, delta=LEVEL_TOLERANCE_DB)

    def test_nothing_peaks_above_minus_1_dbfs(self) -> None:
        for name, clip in {**self.clips, "callkit_ringtone": read(OUT / "callkit_ringtone.wav")}.items():
            with self.subTest(name):
                self.assertLessEqual(db(float(np.abs(clip).max())), PEAK_CEILING_DB)

    def test_every_sound_starts_and_ends_without_a_click(self) -> None:
        edge = int(EDGE_SECONDS * synth.SAMPLE_RATE)
        for name, clip in self.clips.items():
            with self.subTest(name):
                self.assertLess(abs(clip[0]), 0.001, "starts off zero")
                self.assertLess(abs(clip[-1]), 0.001, "ends off zero")
                head = db(float(np.sqrt(np.mean(clip[:edge] ** 2))))
                tail = db(float(np.sqrt(np.mean(clip[-edge:] ** 2))))
                self.assertLess(head, HEAD_CEILING_DB, "first 2 ms are not quiet")
                self.assertLess(tail, TAIL_CEILING_DB, "last 2 ms are not quiet")

    def test_loops_have_no_seam_jump_and_stay_short(self) -> None:
        for name, limit in LOOP_LIMITS_SECONDS.items():
            clip = self.clips[name]
            with self.subTest(name):
                self.assertLess(abs(clip[0] - clip[-1]), MAX_SEAM_JUMP)
                self.assertLessEqual(clip.size / synth.SAMPLE_RATE, limit)

    def test_no_two_sounds_are_the_same(self) -> None:
        seen: dict[bytes, str] = {}
        for name, clip in self.clips.items():
            key = clip.tobytes()
            self.assertNotIn(key, seen, f"{name} is identical to {seen.get(key)}")
            seen[key] = name

    def test_regenerating_changes_nothing(self) -> None:
        """The committed WAVs are what this code makes, or the gate is a lie."""
        before = {p.name: p.read_bytes() for p in OUT.glob("*.wav")}
        subprocess.run(
            [sys.executable, str(HERE / "generate.py")],
            check=True, capture_output=True)
        after = {p.name: p.read_bytes() for p in OUT.glob("*.wav")}
        self.assertEqual(sorted(before), sorted(after), "a sound appeared or vanished")
        drifted = [n for n in before if before[n] != after[n]]
        self.assertEqual(drifted, [], f"regenerating changed {drifted}")


class CallKitRingtone(unittest.TestCase):
    """The iOS CallKit ringtone: a system asset, so only Apple's limits and the ring itself apply."""

    def setUp(self) -> None:
        self.clip = read(OUT / "callkit_ringtone.wav")
        self.ring = read(OUT / "call_ring.wav")

    def test_within_callkits_own_length_ceiling(self) -> None:
        self.assertLess(self.clip.size / synth.SAMPLE_RATE, CALLKIT_MAX_SECONDS)

    def test_is_the_call_ring_repeated_with_real_pauses(self) -> None:
        pause = int(generate.RINGTONE_PAUSE_SECONDS * synth.SAMPLE_RATE)
        stride = self.ring.size + pause
        self.assertEqual(self.clip.size, stride * (generate.RINGTONE_REPEATS - 1) + self.ring.size)
        for i in range(generate.RINGTONE_REPEATS):
            start = i * stride
            with self.subTest(repeat=i):
                np.testing.assert_allclose(
                    self.clip[start:start + self.ring.size], self.ring, atol=2e-3)
            if i:
                self.assertEqual(float(np.abs(self.clip[start - pause:start]).max()), 0.0)


if __name__ == "__main__":
    unittest.main()
