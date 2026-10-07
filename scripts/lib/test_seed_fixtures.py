# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The attachment fixtures a seeding run picks from: every kind the server
accepts is present, and a missing ffmpeg only drops the video."""
import io
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_fixtures  # noqa: E402


def _fake_mp4(path, *args, **kwargs):
    Path(path).write_bytes(b"\x00\x00\x00\x18ftypmp42")


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.mkdtemp(prefix="seed-fixtures-test-")
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)

    def build(self, ffmpeg):
        with patch("seed_media.ffmpeg_available", return_value=ffmpeg), \
             patch("seed_media.mp4_clip", side_effect=_fake_mp4), \
             patch("builtins.print"):
            return seed_fixtures.build(self.scratch, 7)

    def test_without_ffmpeg_every_fixture_but_the_video_is_built(self):
        names = [name for _data, _type, name in self.build(ffmpeg=False)]
        self.assertEqual(names, [
            "seed-banner.png", "seed-poster.png", "seed-icon.png",
            "seed-screenshot.png", "seed-large-photo.png", "seed-notes.pdf",
            "server.log", "sync-notes.zip", "seed-tone.wav"])

    def test_with_ffmpeg_the_mp4_is_added_last(self):
        fixtures = self.build(ffmpeg=True)
        self.assertEqual(fixtures[-1][1:], ("video/mp4", "seed-clip.mp4"))

    def test_each_fixture_carries_bytes_of_the_type_it_declares(self):
        by_name = {name: (data, kind) for data, kind, name in self.build(ffmpeg=False)}
        self.assertTrue(by_name["seed-banner.png"][0].startswith(b"\x89PNG"))
        self.assertTrue(by_name["seed-notes.pdf"][0].startswith(b"%PDF"))
        self.assertTrue(by_name["seed-tone.wav"][0].startswith(b"RIFF"))
        self.assertEqual(by_name["sync-notes.zip"][1], "application/zip")
        with zipfile.ZipFile(io.BytesIO(by_name["sync-notes.zip"][0])) as archive:
            self.assertEqual(sorted(archive.namelist()), ["README.txt", "config.json"])

    def test_the_same_seed_builds_the_same_noise_image(self):
        first = self.build(ffmpeg=False)[4][0]
        second = self.build(ffmpeg=False)[4][0]
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
