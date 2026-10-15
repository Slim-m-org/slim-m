# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Drives `judge` in scripts/check-release-assets.py with fake asset lists."""
import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "check_release_assets",
    Path(__file__).resolve().parents[1] / "check-release-assets.py",
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

NOW = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)
GRACE = timedelta(minutes=90)
OLD = NOW - timedelta(hours=5)

CLIENT = [
    "manifest.json",
    "manifest.json.sig",
    "SHA256SUMS",
    "SHA256SUMS.android",
    "slim-m-client-0.89.0-1.fc44.x86_64.rpm",
    "slim-m-client-0.89.0-linux-amd64.tar.gz",
    "slim-m-client-0.89.0-macos.zip",
    "slim-m-client-0.89.0-windows-x64.zip",
    "slim-m-client-0.89.0.flatpak",
    "slim-m-client-android.apk",
]
SERVER = [
    "SHA256SUMS",
    "slimm-server-0.77.0-linux-amd64",
    "slimm-server-0.77.0-linux-arm64",
]


def judge(tag, names, published=OLD, manifest=None):
    return mod.judge(tag, names, published, NOW, GRACE, manifest)


class CheckReleaseAssetsTest(unittest.TestCase):
    def test_a_complete_client_release_passes(self):
        self.assertEqual(judge("client-v0.89.0", CLIENT), ("ok", []))

    def test_a_missing_manifest_fails_and_is_named(self):
        names = [n for n in CLIENT if n != "manifest.json"]
        self.assertEqual(
            judge("client-v0.89.0", names), ("incomplete", ["manifest.json"])
        )

    def test_a_missing_windows_zip_fails_and_is_named(self):
        names = [n for n in CLIENT if "windows" not in n]
        self.assertEqual(
            judge("client-v0.89.0", names),
            ("incomplete", ["slim-m-client-0.89.0-windows-x64.zip"]),
        )

    def test_an_asset_for_another_version_does_not_count(self):
        names = [n.replace("0.89.0", "0.88.0") for n in CLIENT]
        status, missing = judge("client-v0.89.0", names)
        self.assertEqual(status, "incomplete")
        self.assertIn("slim-m-client-0.89.0-macos.zip", missing)

    def test_a_server_release_is_judged_by_the_server_set(self):
        self.assertEqual(judge("server-v0.77.0", SERVER), ("ok", []))
        self.assertEqual(
            judge("server-v0.77.0", SERVER[:2]),
            ("incomplete", ["slimm-server-0.77.0-linux-arm64"]),
        )

    def test_client_assets_do_not_satisfy_a_server_release(self):
        status, _ = judge("server-v0.77.0", CLIENT)
        self.assertEqual(status, "incomplete")

    def test_a_release_inside_the_grace_period_is_pending(self):
        young = NOW - timedelta(minutes=30)
        status, missing = judge("client-v0.89.0", CLIENT[:3], published=young)
        self.assertEqual(status, "pending")
        self.assertEqual(len(missing), 7)

    def test_a_complete_release_inside_the_grace_period_is_ok(self):
        young = NOW - timedelta(minutes=30)
        self.assertEqual(judge("client-v0.89.0", CLIENT, published=young), ("ok", []))

    def test_a_manifest_missing_an_attached_platform_is_incomplete(self):
        listed = {"macos", "windows-x64"}
        self.assertEqual(
            judge("client-v0.89.0", CLIENT, manifest=listed),
            ("incomplete", ["manifest.json listing linux-x64"]),
        )

    def test_a_manifest_listing_every_attached_platform_passes(self):
        listed = {"macos", "windows-x64", "linux-x64"}
        self.assertEqual(judge("client-v0.89.0", CLIENT, manifest=listed), ("ok", []))

    def test_an_unattached_platform_is_not_blamed_on_the_manifest(self):
        names = [n for n in CLIENT if "windows" not in n]
        self.assertEqual(
            judge("client-v0.89.0", names, manifest={"macos", "linux-x64"}),
            ("incomplete", ["slim-m-client-0.89.0-windows-x64.zip"]),
        )

    def test_an_unread_manifest_is_not_judged(self):
        self.assertEqual(judge("client-v0.89.0", CLIENT, manifest=None), ("ok", []))

    def test_a_stale_manifest_inside_the_grace_period_is_pending(self):
        status, _ = judge("client-v0.89.0", CLIENT, NOW - timedelta(minutes=5), {"macos"})
        self.assertEqual(status, "pending")

    def test_an_unknown_tag_prefix_is_ignored(self):
        self.assertEqual(judge("schema-v0.77.0", []), ("ignored", []))

    def test_the_script_is_the_one_the_workflow_runs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/release-asset-watchdog.yml").read_text()
        self.assertIn("scripts/check-release-assets.py", workflow)



class ExemptTags(unittest.TestCase):
    def test_an_exempt_incomplete_release_is_ignored(self):
        status, missing = mod.judge("client-v0.91.0", ["SHA256SUMS"], OLD, NOW, GRACE, exempt={"client-v0.91.0"})
        self.assertEqual((status, missing), ("ignored", []))

    def test_other_tags_are_still_judged(self):
        status, _ = mod.judge("client-v0.91.2", ["SHA256SUMS"], OLD, NOW, GRACE, exempt={"client-v0.91.0"})
        self.assertEqual(status, "incomplete")

    def test_the_file_parser_reads_tags_and_skips_notes(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("# note\nclient-v1.0.0 because\n\n  # indented note\nserver-v2.0.0\n")
        self.assertEqual(mod.exempt_tags(f.name), {"client-v1.0.0", "server-v2.0.0"})
        self.assertEqual(mod.exempt_tags(f.name + ".missing"), set())

    def test_the_repo_file_exempts_only_the_known_incidents(self):
        self.assertEqual(mod.exempt_tags(), {"client-v0.91.0", "client-v0.101.1"})


if __name__ == "__main__":
    unittest.main()
