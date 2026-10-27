# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Phones may speak plain http to a private network, and nowhere else."""

import plistlib
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "client/packages/app"


class IosTransportSecurity(unittest.TestCase):
    def test_only_local_networking_is_exempt(self):
        ats = plistlib.loads((APP / "ios/Runner/Info.plist").read_bytes())[
            "NSAppTransportSecurity"
        ]
        self.assertEqual(ats, {"NSAllowsLocalNetworking": True})


class AndroidNetworkSecurityConfig(unittest.TestCase):
    def test_cleartext_is_off_by_default_and_on_only_for_local_names(self):
        root = ET.parse(
            APP / "android/app/src/main/res/xml/network_security_config.xml"
        ).getroot()
        self.assertEqual(
            root.find("base-config").get("cleartextTrafficPermitted"), "false"
        )
        hosts = [
            d.text
            for c in root.findall("domain-config")
            if c.get("cleartextTrafficPermitted") == "true"
            for d in c.findall("domain")
        ]
        self.assertEqual(sorted(hosts), ["local", "localhost"])

    def test_manifest_points_at_the_config(self):
        manifest = (APP / "android/app/src/main/AndroidManifest.xml").read_text()
        self.assertIn('android:networkSecurityConfig="@xml/network_security_config"', manifest)


if __name__ == "__main__":
    unittest.main()
