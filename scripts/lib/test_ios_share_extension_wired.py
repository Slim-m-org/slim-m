# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The iOS share extension is wired end to end, read out of the project rather than grepped.

slim-m only appears in the iPhone share sheet if the extension is a real target, is
embedded in the app, is signed under its own bundle id and profile, shares an App Group
with the app, and the app listens on the channel Dart reads. Every one of these fails
silently on a phone, and there is no Xcode here, so the project file is parsed and the
pieces are compared with each other.
"""

import plistlib
import re
import unittest
from pathlib import Path

import pbxproj_parse as pbx

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "client/packages/app/ios"
EXT = IOS / "ShareExtension"
DART_SOURCE = ROOT / "client/packages/app/lib/src/features/share/providers/share_source.dart"
DART_WIRE = ROOT / "client/packages/app/lib/src/features/share/providers/incoming_share.dart"
TARGET = "ShareExtension"
CONFIGS = ("Debug", "Release", "Profile")


def code(path: Path) -> str:
    text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
    return re.sub(r"^[ \t]*//[^\n]*", "", text, flags=re.M)


def swift_string(path: Path, name: str) -> str:
    match = re.search(rf'\b{name}\s*=\s*"([^"]*)"', code(path))
    assert match, f"{path.name} has no string constant {name}"
    return match.group(1)


def entitlement_groups(path: Path) -> list:
    return plistlib.loads(path.read_bytes())["com.apple.security.application-groups"]


class Project(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = pbx.parse((IOS / "Runner.xcodeproj/project.pbxproj").read_text())
        _, cls.target = pbx.target_named(cls.project, TARGET)
        cls.runner_id, cls.runner = pbx.target_named(cls.project, "Runner")
        _, cls.tests = pbx.target_named(cls.project, "RunnerTests")

    def test_every_id_a_target_names_is_defined(self):
        self.assertEqual(pbx.every_reference_resolves(self.project), set())

    def test_it_is_an_app_extension_listed_as_a_project_target(self):
        self.assertEqual(self.target["productType"], "com.apple.product-type.app-extension")
        root = self.project["objects"][self.project["rootObject"]]
        listed = [self.project["objects"][t]["name"] for t in root["targets"]]
        self.assertIn(TARGET, listed)

    def test_it_compiles_exactly_the_swift_files_in_its_folder(self):
        on_disk = sorted(p.name for p in EXT.glob("*.swift"))
        built = sorted(pbx.phase_files(self.project, self.target, "PBXSourcesBuildPhase"))
        self.assertEqual(built, on_disk)

    def test_the_app_embeds_it_in_plugins_and_depends_on_it(self):
        embedded = []
        for phase_id in self.runner["buildPhases"]:
            phase = self.project["objects"][phase_id]
            if phase["isa"] == "PBXCopyFilesBuildPhase" and phase["dstSubfolderSpec"] == "13":
                embedded += pbx.phase_files(self.project, {"buildPhases": [phase_id]}, "PBXCopyFilesBuildPhase")
        self.assertIn("ShareExtension.appex", embedded)
        self.assertIn(TARGET, pbx.dependency_names(self.project, self.runner))

    def test_the_rules_are_shared_with_the_app_and_the_tests(self):
        self.assertIn(
            "ShareIntakeRules.swift", pbx.phase_files(self.project, self.runner, "PBXSourcesBuildPhase")
        )
        self.assertIn(
            "ShareIntakeChannel.swift", pbx.phase_files(self.project, self.runner, "PBXSourcesBuildPhase")
        )
        tests = pbx.phase_files(self.project, self.tests, "PBXSourcesBuildPhase")
        self.assertIn("ShareIntakeRules.swift", tests)
        self.assertIn("ShareIntakeRulesTests.swift", tests)

    def test_every_configuration_builds_under_a_bundle_id_inside_the_apps(self):
        settings = pbx.build_settings(self.project, self.target)
        self.assertEqual(set(settings), set(CONFIGS))
        app = pbx.build_settings(self.project, self.runner)["Release"]["PRODUCT_BUNDLE_IDENTIFIER"]
        for name, values in settings.items():
            self.assertEqual(values["PRODUCT_BUNDLE_IDENTIFIER"], f"{app}.{TARGET}", name)
            self.assertEqual(values["CODE_SIGN_ENTITLEMENTS"], f"{TARGET}/{TARGET}.entitlements", name)
            self.assertEqual(values["INFOPLIST_FILE"], f"{TARGET}/Info.plist", name)
            self.assertEqual(values["TARGETED_DEVICE_FAMILY"], "1", name)
            self.assertEqual(values["DEVELOPMENT_TEAM"], "76S78SUWVM", name)
            self.assertEqual(values["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"], "NO", name)

    def test_release_signs_manually_with_the_profile_the_export_names(self):
        release = pbx.build_settings(self.project, self.target)["Release"]
        self.assertEqual(release["CODE_SIGN_STYLE"], "Manual")
        export = plistlib.loads((IOS / "ExportOptions.plist").read_bytes())["provisioningProfiles"]
        self.assertEqual(
            export[release["PRODUCT_BUNDLE_IDENTIFIER"]], release["PROVISIONING_PROFILE_SPECIFIER"]
        )


class Plist(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((EXT / "Info.plist").read_bytes())
        self.extension = self.info["NSExtension"]

    def test_it_is_a_share_extension_whose_principal_class_exists(self):
        self.assertEqual(self.extension["NSExtensionPointIdentifier"], "com.apple.share-services")
        name = self.extension["NSExtensionPrincipalClass"].removeprefix("$(PRODUCT_MODULE_NAME).")
        self.assertRegex(code(EXT / "ShareViewController.swift"), rf"class {name}\s*:\s*UIViewController")

    def test_the_activation_rule_is_a_dictionary_the_store_accepts(self):
        rule = self.extension["NSExtensionAttributes"]["NSExtensionActivationRule"]
        self.assertIsInstance(rule, dict)
        for key in (
            "NSExtensionActivationSupportsText",
            "NSExtensionActivationSupportsWebURLWithMaxCount",
            "NSExtensionActivationSupportsImageWithMaxCount",
            "NSExtensionActivationSupportsMovieWithMaxCount",
            "NSExtensionActivationSupportsFileWithMaxCount",
        ):
            self.assertIn(key, rule)

    def test_its_version_pair_tracks_the_apps(self):
        self.assertEqual(self.info["CFBundleShortVersionString"], "$(FLUTTER_BUILD_NAME)")
        self.assertEqual(self.info["CFBundleVersion"], "$(FLUTTER_BUILD_NUMBER)")


class AppGroupAndHandoff(unittest.TestCase):
    def test_the_group_is_one_string_in_all_four_places(self):
        group = swift_string(EXT / "ShareIntakeRules.swift", "appGroupIdentifier")
        self.assertEqual(entitlement_groups(EXT / "ShareExtension.entitlements"), [group])
        self.assertIn(group, entitlement_groups(IOS / "Runner/Runner.entitlements"))
        broadcast = entitlement_groups(IOS / "BroadcastExtension/BroadcastExtension.entitlements")
        self.assertEqual(broadcast, [group])

    def test_the_url_the_extension_opens_is_a_scheme_the_app_registers(self):
        scheme = swift_string(EXT / "ShareIntakeRules.swift", "openURLString").split("://")[0]
        runner = plistlib.loads((IOS / "Runner/Info.plist").read_bytes())
        schemes = [s for entry in runner["CFBundleURLTypes"] for s in entry["CFBundleURLSchemes"]]
        self.assertIn(scheme, schemes)

    def test_the_app_answers_on_the_channel_dart_asks(self):
        dart = re.search(r"MethodChannel\('([^']+)'\)", DART_SOURCE.read_text()).group(1)
        swift = swift_string(IOS / "Runner/ShareIntakeChannel.swift", "name")
        self.assertEqual(swift, dart)
        self.assertIn("ShareIntakeChannel.name", code(IOS / "Runner/AppDelegate.swift"))

    def test_the_extension_writes_the_keys_dart_reads(self):
        writer = code(EXT / "ShareIntakeWriter.swift")
        reader = DART_WIRE.read_text()
        for key in ("files", "text", "unreadable", "tooLarge", "path", "name", "mimeType", "length"):
            self.assertIn(f'"{key}"', writer, key)
            self.assertRegex(reader, rf"\[\s*'{key}'\s*\]", key)

    def test_the_manifest_goes_in_last_and_the_app_waits_for_it(self):
        rules = EXT / "ShareIntakeRules.swift"
        name = swift_string(rules, "manifestName")
        self.assertIn(name, code(IOS / "Runner/ShareIntakeChannel.swift") + code(rules))
        self.assertIn(".atomic", code(EXT / "ShareIntakeWriter.swift"))


class Signing(unittest.TestCase):
    def test_the_profile_secret_is_imported_and_gated_everywhere_the_others_are(self):
        secret = "IOS_SHARE_PROVISIONING_PROFILE"
        action = (ROOT / ".github/actions/release-ios-testflight/action.yml").read_text()
        self.assertIn(secret, action)
        for flow in ("release.yml", "main-builds.yml"):
            text = (ROOT / ".github/workflows" / flow).read_text()
            self.assertIn(f"{secret}: ${{{{ secrets.{secret} }}}}", text, flow)
            self.assertIn(f'[ -n "${secret}" ]', text, flow)

    def test_the_docs_list_the_secret(self):
        docs = (ROOT / "docs/ci-details.md").read_text()
        self.assertIn("`IOS_SHARE_PROVISIONING_PROFILE`", docs)


if __name__ == "__main__":
    unittest.main()
