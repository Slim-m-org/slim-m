# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The review bundle turns snapshot PNGs into a manifest a reviewer walks, so a
name that parses wrongly, a rerun that rewrites bytes, or a stale image left in
the bundle each make the review lie."""
import contextlib
import io
import json
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
import unittest.mock
import zlib
from pathlib import Path

import ui_review_bundle as bundle
import ui_review_names as names

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "client" / "packages" / "app"
SETTINGS = {"format": "webp", "max_width": 1600, "quality": 80}


def write_png(path: Path, width: int = 8, height: int = 4, color=(30, 60, 90)) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    row = b"\x00" + bytes(color) * width
    raw = zlib.compress(row * height)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


class TokenTest(unittest.TestCase):
    def split(self, name):
        return names.strip_tokens(name)

    def test_trailing_viewport_and_theme(self):
        self.assertEqual(self.split("settings-profile-phone-portrait-dark"), ("settings-profile", "phone-portrait", "dark"))

    def test_viewport_alone_leaves_the_theme_to_the_sidecar(self):
        self.assertEqual(self.split("confirm-clear-canvas-phone"), ("confirm-clear-canvas", "phone", None))

    def test_a_palette_after_the_viewport(self):
        self.assertEqual(self.split("theme-appearance-desktop-forest"), ("theme-appearance", "desktop", "forest"))

    def test_double_dash_spelling(self):
        self.assertEqual(self.split("call-header--state--phone--dark"), ("call-header--state", "phone", "dark"))

    def test_a_width_suffix(self):
        self.assertEqual(self.split("dock-module-xp-390"), ("dock-module-xp", "390", None))

    def test_tokens_before_a_state_are_taken_out_of_the_middle(self):
        self.assertEqual(self.split("member-profile-away-desktop-dark-colour"), ("member-profile-away-colour", "desktop", "dark"))
        self.assertEqual(self.split("admin-roles-phone-portrait-200pct"), ("admin-roles-200pct", "phone-portrait", None))

    def test_a_pane_named_like_a_viewport_keeps_its_name(self):
        self.assertEqual(self.split("settings-pane-desktop-phone-dark"), ("settings-pane-desktop", "phone", "dark"))

    def test_only_one_theme_is_taken(self):
        self.assertEqual(self.split("thing-dark-light"), ("thing-dark", None, "light"))

    def test_a_name_that_is_only_a_token_stays_whole(self):
        self.assertEqual(self.split("desktop"), ("desktop", None, None))

    def test_a_word_that_merely_contains_a_token_is_not_one(self):
        self.assertEqual(self.split("iphone-call-alone"), ("iphone-call-alone", None, None))
        self.assertEqual(self.split("highlight-row"), ("highlight-row", None, None))

    def test_the_phone_boundary_is_the_compact_width(self):
        self.assertEqual(names.viewport_class(599), "phone")
        self.assertEqual(names.viewport_class(600), "desktop")

    def test_every_viewport_the_suites_can_use_is_a_known_token(self):
        support = (APP / "test" / "ui_snapshot_support.dart").read_text()
        block = support[support.index("const viewports"):support.index("};", support.index("const viewports"))]
        keys = re.findall(r"'([a-z0-9-]+)':\s*Size\(", block)
        self.assertGreater(len(keys), 10)
        self.assertEqual([k for k in keys if k not in names.VIEWPORT_TOKENS], [])

    def test_every_palette_the_suites_can_use_is_a_known_token(self):
        support = (APP / "test" / "ui_snapshot_support.dart").read_text()
        block = support[support.index("final snapshotThemes"):support.index("};", support.index("final snapshotThemes"))]
        keys = re.findall(r"'([a-z]+)':\s*\(brightness", block)
        self.assertEqual([k for k in keys if k not in names.THEME_TOKENS], [])


class RegistryTest(unittest.TestCase):
    TEXT = (
        "# kind|key|area|snapshots\n"
        "\n"
        "route|/join|auth|onboarding\n"
        "settings|profile|settings|settings-pane-profile, settings-profile\n"
        "route|/share|auth|exclude: opened by the OS share sheet only\n"
        "route|/thread/:channelId|shell|pending: needs a seeded thread\n"
    )

    def test_rows_carry_their_status(self):
        rows = names.parse_registry(self.TEXT)
        self.assertEqual([r.status for r in rows], ["covered", "covered", "excluded", "pending"])
        self.assertEqual(rows[1].names, ("settings-pane-profile", "settings-profile"))
        self.assertEqual(rows[2].reason, "opened by the OS share sheet only")

    def test_a_malformed_line_is_refused(self):
        with self.assertRaises(ValueError):
            names.parse_registry("route|/join|onboarding\n")

    def test_an_exclusion_needs_its_reason(self):
        with self.assertRaises(ValueError):
            names.parse_registry("route|/share|auth|exclude:\n")

    def test_the_longest_registered_name_is_the_surface(self):
        rows = names.parse_registry("a|1|x|settings\na|2|y|settings-pane-profile\n")
        parsed = names.parse_name("settings-pane-profile-phone-dark", rows)
        self.assertEqual((parsed.surface, parsed.state, parsed.area), ("settings-pane-profile", "default", "y"))
        parsed = names.parse_name("settings-menu-desktop-light", rows)
        self.assertEqual((parsed.surface, parsed.state, parsed.area), ("settings", "menu", "x"))

    def test_a_double_dash_splits_surface_from_state(self):
        parsed = names.parse_name("voice-call--muted--phone--dark", [])
        self.assertEqual((parsed.surface, parsed.state), ("voice-call", "muted"))

    def test_an_unregistered_name_is_its_own_surface(self):
        parsed = names.parse_name("rail-avatars-phone-dark", [])
        self.assertEqual((parsed.surface, parsed.state, parsed.area), ("rail-avatars", "default", "unregistered"))

    def test_the_real_registry_parses_and_every_name_survives_its_suffixes(self):
        rows = names.load_registry(bundle.DEFAULT_REGISTRY)
        self.assertTrue(rows, "the coverage registry is empty or missing")
        registered = [name for row in rows for name in row.names]
        self.assertEqual([n for n in registered if names.strip_tokens(f"{n}-phone-dark")[0] != n], [])


class BundleCase(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="ui-review-bundle-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.src, self.out = self.root / "src", self.root / "out"
        self.src.mkdir()
        self.registry = self.root / "registry.txt"
        self.registry.write_text("route|/join|auth|onboarding\nroute|/gone|auth|vanished\n")

    def shot(self, name, *, width=390, height=844, brightness="dark", pixels=(8, 4), sidecar=True):
        write_png(self.src / f"{name}.png", *pixels)
        if sidecar:
            body = {"name": name, "test": "test/snapshots/x_test.dart", "description": f"{name} renders",
                    "width": width, "height": height, "brightness": brightness}
            (self.src / f"{name}.json").write_text(json.dumps(body))

    def run_bundle(self, **kwargs):
        return bundle.build_bundle(self.src, self.out, self.registry, SETTINGS, commit="abc123", **kwargs)


class ManifestTest(BundleCase):
    def setUp(self):
        super().setUp()
        self.shot("onboarding-phone-portrait-dark")
        self.shot("onboarding-desktop-light", width=1280, height=800, brightness="light")
        self.shot("onboarding-desktop-200pct-dark", width=1280, height=800)
        self.shot("rail-avatars-phone", brightness="light")

    def test_each_shot_reads_its_viewport_and_theme_from_the_sidecar(self):
        manifest = self.run_bundle()
        by_id = {s["id"]: s for s in manifest["shots"]}
        phone = by_id["onboarding-phone-portrait-dark"]
        self.assertEqual((phone["surface"], phone["state"], phone["viewport"], phone["theme"]),
                         ("onboarding", "default", "phone", "dark"))
        self.assertEqual((phone["width"], phone["height"]), (390, 844))
        self.assertEqual(phone["test"], "client/packages/app/test/snapshots/x_test.dart")
        self.assertEqual(by_id["onboarding-desktop-light"]["viewport"], "desktop")
        self.assertEqual(by_id["onboarding-desktop-200pct-dark"]["state"], "200pct")
        self.assertEqual(by_id["rail-avatars-phone"]["theme"], "light")

    def test_surfaces_group_their_shots_and_name_the_area(self):
        manifest = self.run_bundle()
        surfaces = {s["surface"]: s for s in manifest["surfaces"]}
        self.assertEqual(surfaces["onboarding"]["area"], "auth")
        self.assertEqual(len(surfaces["onboarding"]["shots"]), 3)
        self.assertEqual(surfaces["rail-avatars"]["area"], "unregistered")
        self.assertEqual(manifest["surfaces"][-1]["surface"], "rail-avatars")

    def test_the_manifest_records_the_commit_and_the_source_hash(self):
        manifest = self.run_bundle()
        self.assertEqual(manifest["generated_from_commit"], "abc123")
        shot = next(s for s in manifest["shots"] if s["id"] == "rail-avatars-phone")
        self.assertRegex(shot["sha256"], r"^[0-9a-f]{64}$")

    def test_coverage_names_the_registered_surface_with_no_picture(self):
        cover = self.run_bundle()["coverage"]
        self.assertEqual(cover["missing"], ["vanished"])
        self.assertEqual(cover["unregistered"], ["rail-avatars"])

    def test_a_missing_sidecar_is_guessed_and_warned_about(self):
        self.shot("loose-shot", pixels=(780, 1688), sidecar=False)
        manifest = self.run_bundle()
        shot = next(s for s in manifest["shots"] if s["id"] == "loose-shot")
        self.assertEqual((shot["width"], shot["viewport"]), (390, "phone"))
        self.assertIn("loose-shot: no sidecar, size and theme guessed", manifest["warnings"])

    def test_a_name_that_disagrees_with_the_render_is_warned_about(self):
        self.shot("lying-phone-light", brightness="dark")
        manifest = self.run_bundle()
        self.assertIn("lying-phone-light: named light but rendered dark", manifest["warnings"])

    def test_a_rerun_writes_the_same_bytes(self):
        self.run_bundle()
        first = {p.name: p.read_bytes() for p in self.out.rglob("*") if p.is_file()}
        self.run_bundle(force=True)
        second = {p.name: p.read_bytes() for p in self.out.rglob("*") if p.is_file()}
        self.assertEqual(first, second)

    def test_an_unchanged_picture_is_not_encoded_again(self):
        self.run_bundle()
        with unittest.mock.patch.object(bundle, "encode") as encode:
            self.run_bundle()
        encode.assert_not_called()

    def test_a_removed_picture_leaves_no_image_behind(self):
        self.run_bundle()
        (self.src / "rail-avatars-phone.png").unlink()
        self.run_bundle()
        self.assertFalse((self.out / "shots" / "rail-avatars-phone.webp").exists())


@unittest.skipUnless(bundle.Image, "Pillow is not installed")
class ImageTest(BundleCase):
    def test_a_wide_picture_is_cut_to_the_maximum_and_written_as_webp(self):
        self.shot("wide-desktop-dark", width=1400, height=880, pixels=(2800, 1760))
        shot = self.run_bundle()["shots"][0]
        self.assertEqual((shot["image_width"], shot["image_height"]), (1600, 1006))
        self.assertTrue(shot["file"].endswith(".webp"))
        with bundle.Image.open(self.out / shot["file"]) as image:
            self.assertEqual((image.format, image.width), ("WEBP", 1600))

    def test_a_narrow_picture_keeps_its_size(self):
        self.shot("narrow-phone-dark", pixels=(780, 1688))
        shot = self.run_bundle()["shots"][0]
        self.assertEqual((shot["image_width"], shot["image_height"]), (780, 1688))


class FallbackTest(BundleCase):
    def test_without_pillow_the_png_is_copied(self):
        self.shot("plain-phone-dark")
        with unittest.mock.patch.object(bundle, "Image", None):
            manifest = bundle.build_bundle(self.src, self.out, self.registry, {**SETTINGS, "format": "png"}, commit="c")
        shot = manifest["shots"][0]
        self.assertEqual(shot["file"], "shots/plain-phone-dark.png")
        self.assertEqual((self.out / shot["file"]).read_bytes(), (self.src / "plain-phone-dark.png").read_bytes())
        self.assertEqual((shot["image_width"], shot["image_height"]), (8, 4))


class CommandLineTest(BundleCase):
    def args(self, *extra):
        return ["--src", str(self.src), "--out", str(self.out), "--registry", str(self.registry), "--commit", "c", *extra]

    def test_no_pictures_is_an_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(bundle.main(self.args()), 2)

    def test_check_coverage_fails_on_a_missing_surface(self):
        self.shot("onboarding-phone-dark")
        with unittest.mock.patch("builtins.print"):
            self.assertEqual(bundle.main(self.args("--check-coverage")), 1)
            self.assertEqual(bundle.main(self.args()), 0)


class ScriptTest(unittest.TestCase):
    def listed(self, *args):
        done = subprocess.run(["bash", str(ROOT / "scripts" / "ui-review.sh"), "--list", *args],
                              capture_output=True, text=True, check=True, timeout=60)
        return done.stdout.split()

    def test_every_snapshot_suite_on_disk_is_selected(self):
        on_disk = {
            str(p.relative_to(APP))
            for pattern in ("test/ui_snapshot*test.dart", "test/ui_overlay_snapshot*test.dart", "test/review/ui_review_*test.dart",
                            "test/snapshots/ui_*snapshot*test.dart", "test/snapshots/ui_review_*test.dart")
            for p in APP.glob(pattern)
        }
        self.assertGreater(len(on_disk), 50)
        self.assertEqual(sorted(on_disk - set(self.listed())), [])

    def test_the_main_matrices_are_among_them(self):
        listed = self.listed()
        self.assertIn("test/ui_snapshot_test.dart", listed)
        self.assertIn("test/snapshots/ui_overlay_snapshot_test.dart", listed)

    def test_a_flag_takes_its_value_after_an_equals_sign(self):
        self.assertEqual(self.listed("--concurrency=8", "--out=/nowhere"), self.listed("--concurrency", "8"))

    def test_a_filter_keeps_only_matching_suites(self):
        listed = self.listed("settings", "voice_rail")
        self.assertTrue(listed)
        self.assertTrue(all("settings" in s or "voice_rail" in s for s in listed))


if __name__ == "__main__":
    unittest.main()
