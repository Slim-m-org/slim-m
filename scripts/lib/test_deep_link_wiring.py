# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""slimm:// links reach the app only through app_links, never through Flutter's own deep linking."""

import plistlib
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "client/packages/app"
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
CALLBACK_HOSTS = {"join", "message", "spotify-callback", "discord-link", "steam-link"}


def _main_activity():
    root = ET.parse(APP / "android/app/src/main/AndroidManifest.xml").getroot()
    for activity in root.iter("activity"):
        if activity.get(ANDROID_NS + "name") == ".MainActivity":
            return activity
    raise AssertionError("MainActivity is not declared")


class AndroidDeepLinking(unittest.TestCase):
    def test_flutter_deep_linking_is_off(self):
        values = {
            m.get(ANDROID_NS + "name"): m.get(ANDROID_NS + "value")
            for m in _main_activity().findall("meta-data")
        }
        self.assertEqual(values.get("flutter_deeplinking_enabled"), "false")

    def test_every_callback_host_is_in_the_slimm_filter(self):
        hosts = {
            d.get(ANDROID_NS + "host")
            for f in _main_activity().findall("intent-filter")
            for d in f.findall("data")
            if d.get(ANDROID_NS + "scheme") == "slimm"
        }
        self.assertTrue(CALLBACK_HOSTS <= hosts, CALLBACK_HOSTS - hosts)


class IosDeepLinking(unittest.TestCase):
    def test_flutter_deep_linking_is_off(self):
        plist = plistlib.loads((APP / "ios/Runner/Info.plist").read_bytes())
        self.assertIs(plist.get("FlutterDeepLinkingEnabled"), False)


if __name__ == "__main__":
    unittest.main()
