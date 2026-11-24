# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""slimm:// links reach the app only through app_links, never through Flutter's own deep linking."""

import plistlib
import re
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dart_source import strip_block_comments  # noqa: E402

APP = Path(__file__).resolve().parents[2] / "client/packages/app"
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
MINIMUM_HOSTS = {"join", "message", "spotify-callback", "discord-link", "steam-link"}
HOST_CONSTANT = re.compile(r"\bconst\s+\w*Host\s*=\s*'([a-z][a-z-]*)'")
HOST_COMPARISON = re.compile(r"\buri\.host\s*==\s*'([a-z][a-z-]*)'")


def dart_hosts(source: str) -> set[str]:
    code = strip_block_comments(source)
    return set(HOST_CONSTANT.findall(code)) | set(HOST_COMPARISON.findall(code))


def callback_hosts() -> set[str]:
    found = set()
    for path in (APP / "lib").rglob("*.dart"):
        found |= dart_hosts(path.read_text())
    return MINIMUM_HOSTS | found


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
        wanted = callback_hosts()
        self.assertLessEqual(wanted, hosts)

    def test_hosts_are_read_from_the_dart_constants(self):
        found = set().union(*(dart_hosts(p.read_text()) for p in (APP / "lib").rglob("*.dart")))
        self.assertLessEqual({"steam-link", "discord-link", "spotify-callback"}, found)
        self.assertEqual(dart_hosts("const newLinkHost = 'new-link';"), {"new-link"})
        self.assertEqual(dart_hosts("// const oldLinkHost = 'old-link';"), set())


class IosDeepLinking(unittest.TestCase):
    def test_flutter_deep_linking_is_off(self):
        plist = plistlib.loads((APP / "ios/Runner/Info.plist").read_bytes())
        self.assertIs(plist.get("FlutterDeepLinkingEnabled"), False)


if __name__ == "__main__":
    unittest.main()
