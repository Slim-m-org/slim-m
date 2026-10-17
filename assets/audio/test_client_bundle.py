# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The client app's own copy of the notification sounds must stay byte-
identical to the canonical set this directory generates.

It is a copy rather than a symlink (see `client/packages/app/pubspec.yaml`'s
own comment on the assets entry, and `docs/os_backlog/windows_backlog.md`):
a git symlink checks out as a small text file naming its target on a Windows
clone without `core.symlinks` set, which Flutter then bundles as a garbage
"sound" rather than refusing to build. A plain committed copy has no such
failure mode on any platform, and this test is what keeps it from silently
drifting away from the canonical source `generate.py` writes.

Run with: python3 -m unittest discover -s assets/audio
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "notifications"))

from sounds import SOUNDS, UI_SOUNDS  # noqa: E402

SHIPPED = [*SOUNDS, *UI_SOUNDS]

CANONICAL = HERE / "notifications"
CLIENT_COPY = (
    HERE.parent.parent / "client" / "packages" / "app" / "assets" / "audio" / "notifications"
)


class ClientBundleCopy(unittest.TestCase):
    def test_every_sound_is_byte_identical_in_the_client_copy(self) -> None:
        for name in SHIPPED:
            canonical = (CANONICAL / f"{name}.wav").read_bytes()
            copy_path = CLIENT_COPY / f"{name}.wav"
            self.assertTrue(copy_path.exists(), f"{copy_path} is missing")
            self.assertEqual(
                canonical,
                copy_path.read_bytes(),
                f"{copy_path.name} in the client copy does not match "
                "the canonical sound generate.py just wrote",
            )

    def test_the_client_copy_carries_no_extra_or_stale_files(self) -> None:
        present = {p.name for p in CLIENT_COPY.glob("*.wav")}
        expected = {f"{name}.wav" for name in SHIPPED}
        self.assertEqual(
            present,
            expected,
            "the client copy's file set has drifted from SOUNDS and UI_SOUNDS",
        )


if __name__ == "__main__":
    unittest.main()
