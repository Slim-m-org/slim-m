# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "client/packages/app/android/app/src/main/AndroidManifest.xml"
PLAY = ROOT / "client/packages/app/android/app/src/play/AndroidManifest.xml"
ACTION = ROOT / ".github/actions/release-android-client/action.yml"


def media_permissions(text):
    return set(re.findall(r'uses-permission android:name="android\.permission\.(READ_MEDIA_\w+)"', text))


class PlayManifestStripsEveryMediaPermission(unittest.TestCase):
    def test_play_manifest_removes_each_media_permission_main_declares(self):
        declared = media_permissions(MAIN.read_text())
        removed = set(re.findall(
            r'android\.permission\.(READ_MEDIA_\w+)" tools:node="remove"', PLAY.read_text()))
        self.assertTrue(declared)
        self.assertEqual(declared - removed, set())

    def test_release_check_loops_over_each_media_permission_main_declares(self):
        declared = media_permissions(MAIN.read_text())
        loop = re.search(r"for permission in ([^;]+); do", ACTION.read_text()).group(1).split()
        self.assertEqual(declared - set(loop), set())


if __name__ == "__main__":
    unittest.main()
