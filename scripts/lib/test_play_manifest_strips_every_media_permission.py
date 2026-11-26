# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "client/packages/app/android/app/src/main/AndroidManifest.xml"
PLAY = ROOT / "client/packages/app/android/app/src/play/AndroidManifest.xml"
ACTION = ROOT / ".github/actions/release-android-client/action.yml"


MEDIA_PERMISSIONS = {"READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_VISUAL_USER_SELECTED"}


def media_permissions(text):
    return set(re.findall(r'uses-permission android:name="android\.permission\.(READ_MEDIA_\w+)"', text))


class PlayManifestStripsEveryMediaPermission(unittest.TestCase):
    def test_main_manifest_declares_no_media_permission(self):
        self.assertEqual(media_permissions(MAIN.read_text()), set())

    def test_play_manifest_removes_every_media_permission(self):
        declared = MEDIA_PERMISSIONS
        removed = set(re.findall(
            r'android\.permission\.(READ_MEDIA_\w+)" tools:node="remove"', PLAY.read_text()))
        self.assertEqual(declared - removed, set())

    def test_release_check_loops_over_every_media_permission(self):
        declared = MEDIA_PERMISSIONS
        loop = re.search(r"for permission in ([^;]+); do", ACTION.read_text()).group(1).split()
        self.assertEqual(declared - set(loop), set())


if __name__ == "__main__":
    unittest.main()
