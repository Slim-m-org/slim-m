# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The iOS bundles that need an Apple privacy manifest carry a correct one.

App Store Connect rejects an upload whose binary uses a required-reason API
with no declared reason, and a manifest present on disk but absent from the
Xcode project ships nothing. Neither shows in a Linux build, so this reads the
manifest, the project and the extension sources directly.

The extensions need a manifest only if their own Swift calls a
required-reason API; the scan below makes that a checked fact, not a belief.
"""

import plistlib
import re
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[2] / "client/packages/app/ios"
PBX = IOS / "Runner.xcodeproj/project.pbxproj"
MANIFEST = "PrivacyInfo.xcprivacy"

# Apple's NSPrivacyCollectedDataType value for each row of the owner's table. Call audio is not listed: it passes through the voice server in real time and is not kept.
COLLECTED = {
    "NSPrivacyCollectedDataTypeName",
    "NSPrivacyCollectedDataTypeUserID",
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypePhotosorVideos",
}
PURPOSE = "NSPrivacyCollectedDataTypePurposeAppFunctionality"

# Symbols behind Apple's required-reason API categories.
REQUIRED_REASON_SYMBOLS = re.compile(
    r"\b(UserDefaults|NSUserDefaults|fstat|lstat|stat\(|getattrlist|"
    r"creationDate|modificationDate|contentModificationDateKey|"
    r"creationDateKey|NSFileCreationDate|NSFileModificationDate|"
    r"systemUptime|mach_absolute_time|volumeAvailableCapacity|"
    r"systemFreeSize|statfs|statvfs|activeInputModes)\b"
)

MANIFEST_BUNDLES = ("Runner",)
EXTENSIONS = ("BroadcastExtension", "NotificationService")


def load(bundle: str) -> dict:
    return plistlib.loads((IOS / bundle / MANIFEST).read_bytes())


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def blocks(section: str) -> dict[str, str]:
    """Object id -> body for one `Begin X section` of the project file."""
    text = PBX.read_text()
    body = re.search(rf"Begin {section} section \*/(.*?)/\* End {section} section", text, re.S)
    if not body:
        raise AssertionError(f"no {section} section")
    found: dict[str, str] = {}
    current: str | None = None
    for line in body.group(1).splitlines():
        start = re.match(r"\t\t([0-9A-F]{24}) /\*[^*]*\*/ = \{", line)
        if start:
            current = start.group(1)
            found[current] = line
            if line.rstrip().endswith("};"):
                current = None
        elif current:
            found[current] += "\n" + line
            if line == "\t\t};":
                current = None
    return found


def target_resources(target: str) -> str:
    for body in blocks("PBXNativeTarget").values():
        if re.search(rf'\bname = "?{target}"?;', body):
            phase_ids = re.findall(r"([0-9A-F]{24}) /\* Resources \*/", body)
            phases = blocks("PBXResourcesBuildPhase")
            return "\n".join(phases[p] for p in phase_ids if p in phases)
    raise AssertionError(f"no target {target}")


class PrivacyManifests(unittest.TestCase):
    def test_runner_manifest_is_a_plist_with_the_required_keys(self):
        data = load("Runner")
        for key in ("NSPrivacyTracking", "NSPrivacyTrackingDomains",
                    "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"):
            self.assertIn(key, data)

    def test_tracking_is_off_with_no_domains(self):
        data = load("Runner")
        self.assertIs(data["NSPrivacyTracking"], False)
        self.assertEqual(data["NSPrivacyTrackingDomains"], [])

    def test_collected_types_equal_the_owner_table(self):
        entries = load("Runner")["NSPrivacyCollectedDataTypes"]
        self.assertEqual({e["NSPrivacyCollectedDataType"] for e in entries}, COLLECTED)
        self.assertEqual(len(entries), len(COLLECTED))
        for entry in entries:
            self.assertIs(entry["NSPrivacyCollectedDataTypeLinked"], True)
            self.assertIs(entry["NSPrivacyCollectedDataTypeTracking"], False)
            self.assertEqual(entry["NSPrivacyCollectedDataTypePurposes"], [PURPOSE])

    def test_every_accessed_api_has_a_reason(self):
        for api in load("Runner")["NSPrivacyAccessedAPITypes"]:
            self.assertRegex(api["NSPrivacyAccessedAPIType"], r"^NSPrivacyAccessedAPICategory\w+$")
            self.assertTrue(api["NSPrivacyAccessedAPITypeReasons"])
            for reason in api["NSPrivacyAccessedAPITypeReasons"]:
                self.assertRegex(reason, r"^[0-9A-F]{4}\.\d$")

    def test_manifest_is_in_the_project_and_the_runner_resources_phase(self):
        refs = [i for i, b in blocks("PBXFileReference").items() if MANIFEST in b]
        self.assertEqual(len(refs), 1, "one file reference for the manifest")
        builds = [i for i, b in blocks("PBXBuildFile").items() if f"fileRef = {refs[0]}" in b]
        self.assertEqual(len(builds), 1, "one build file for the manifest")
        self.assertIn(builds[0], target_resources("Runner"))
        groups = "\n".join(blocks("PBXGroup").values())
        self.assertIn(refs[0], groups)

    def test_project_ids_are_unique(self):
        ids = re.findall(r"^\t\t([0-9A-F]{24}) /\*", PBX.read_text(), re.M)
        self.assertEqual(len(ids), len(set(ids)))

    def test_extensions_without_a_manifest_use_no_required_reason_api(self):
        for ext in EXTENSIONS:
            if (IOS / ext / MANIFEST).exists():
                continue
            for swift in (IOS / ext).glob("*.swift"):
                hit = REQUIRED_REASON_SYMBOLS.search(strip_comments(swift.read_text()))
                self.assertIsNone(hit, f"{swift.name} uses {hit and hit.group(0)}: add a manifest")

    def test_no_stray_manifest_outside_the_declared_bundles(self):
        found = {p.parent.name for p in IOS.rglob(MANIFEST)}
        self.assertTrue(found <= set(MANIFEST_BUNDLES) | set(EXTENSIONS), found)


if __name__ == "__main__":
    unittest.main()
