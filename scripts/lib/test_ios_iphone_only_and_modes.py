# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The iOS app is iPhone only and declares only the capabilities it uses.

App Store review rejects an unused background mode (guideline 2.5.4), an iPad
build that was never laid out for iPad, and a local network prompt with no
purpose string. None of these show in a diff as a behaviour change.
"""

import plistlib
import re
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[2] / "client/packages/app/ios"
PBX = IOS / "Runner.xcodeproj/project.pbxproj"


def runner_plist() -> dict:
    return plistlib.loads((IOS / "Runner/Info.plist").read_bytes())


class DeviceFamily(unittest.TestCase):
    def test_every_build_configuration_targets_iphone_only(self):
        values = re.findall(r"TARGETED_DEVICE_FAMILY = (.+?);", PBX.read_text())
        self.assertTrue(values)
        self.assertEqual(set(values), {"1"})

    def test_no_bundle_declares_ipad_orientations(self):
        for plist in IOS.glob("*/Info.plist"):
            self.assertNotIn("~ipad", plist.read_text(), plist)


class BackgroundModes(unittest.TestCase):
    def test_modes_are_audio_and_remote_notification(self):
        self.assertEqual(
            sorted(runner_plist()["UIBackgroundModes"]),
            ["audio", "remote-notification"],
        )


class LocalNetwork(unittest.TestCase):
    def test_usage_description_is_present_and_plain(self):
        text = runner_plist()["NSLocalNetworkUsageDescription"]
        self.assertTrue(text.strip())
        self.assertNotIn("—", text)

    def test_no_bonjour_and_no_transport_security_exception(self):
        plist = runner_plist()
        self.assertNotIn("NSBonjourServices", plist)
        self.assertNotIn("NSAppTransportSecurity", plist)


if __name__ == "__main__":
    unittest.main()
