# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""scripts/update-manifest.py: build, sign, verify, against a throwaway key.

The key is generated per run and never leaves the temp dir; the real signing
key lives only in the UPDATE_SIGNING_KEY Actions secret.
"""
import base64
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "update-manifest.py"
REPO = SCRIPT.parent.parent
_spec = importlib.util.spec_from_file_location("update_manifest", SCRIPT)
update_manifest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(update_manifest)
TAG = "client-v0.90.0"


RUN_CWD = None


def run(*args, key=None):
    env = {**os.environ}
    env.pop("UPDATE_SIGNING_KEY", None)
    if key is not None:
        env["UPDATE_SIGNING_KEY"] = key
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        capture_output=True, text=True, env=env, cwd=RUN_CWD,
    )


def new_key():
    return subprocess.run(
        ["openssl", "genpkey", "-algorithm", "ed25519"],
        capture_output=True, text=True, check=True,
    ).stdout


@unittest.skipUnless(shutil.which("openssl"), "openssl is required")
class UpdateManifestTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        global RUN_CWD
        RUN_CWD = self.tmp
        self.assets = self.tmp / "assets"
        self.assets.mkdir()
        (self.assets / "slim-m-client-0.90.0-windows-x64.zip").write_bytes(b"win" * 10)
        (self.assets / "slim-m-client-0.90.0-macos.zip").write_bytes(b"mac" * 10)
        (self.assets / "slim-m-client-0.90.0-linux-amd64.tar.gz").write_bytes(b"lin")
        (self.assets / "SHA256SUMS").write_text("ignored")
        self.key = new_key()
        self.manifest = self.tmp / "manifest.json"
        self.sig = self.tmp / "manifest.json.sig"
        self.pub = run("pubkey", key=self.key).stdout.strip()

    def build(self, *extra):
        source = [] if "--expected" in extra else ["--trust-release-assets"]
        return run("build", "--tag", TAG, "--dir", self.assets, "--repo", "o/r",
                   "--out", "manifest.json", *source, *extra)

    def record(self, *names):
        out = self.tmp / "expected"
        out.mkdir(exist_ok=True)
        done = run("digest", "--out", out, *[self.assets / n for n in names])
        self.assertEqual(done.returncode, 0, done.stderr)
        return out

    def all_names(self):
        return [p.name for p in self.assets.iterdir() if p.name != "SHA256SUMS"]

    def signed(self):
        self.assertEqual(self.build().returncode, 0)
        done = run("sign", "--manifest", self.manifest, "--sig", "manifest.json.sig", key=self.key)
        self.assertEqual(done.returncode, 0, done.stderr)

    def verify(self, *extra, pub=None):
        return run("verify", "--manifest", self.manifest, "--sig", self.sig,
                   "--pubkey", pub or self.pub, *extra)

    def test_build_lists_every_platform_with_hash_and_url(self):
        self.assertEqual(self.build().returncode, 0)
        data = json.loads(self.manifest.read_text())
        self.assertEqual(data["version"], "0.90.0")
        self.assertEqual(sorted(data["artifacts"]), ["linux-x64", "macos", "windows-x64"])
        win = data["artifacts"]["windows-x64"]
        self.assertEqual(win["size"], 30)
        self.assertEqual(len(win["sha256"]), 64)
        self.assertEqual(
            win["url"],
            "https://github.com/o/r/releases/download/client-v0.90.0/"
            "slim-m-client-0.90.0-windows-x64.zip",
        )

    def test_an_attached_apk_is_listed_for_android_and_never_required(self):
        (self.assets / "slim-m-client-android.apk").write_bytes(b"apk" * 4)
        self.assertEqual(self.build().returncode, 0)
        android = json.loads(self.manifest.read_text())["artifacts"]["android"]
        self.assertTrue(android["url"].endswith("/client-v0.90.0/slim-m-client-android.apk"))
        (self.assets / "slim-m-client-android.apk").unlink()
        self.assertEqual(self.build().returncode, 0)

    def test_split_apks_are_listed_per_abi_with_the_old_key_aliasing_arm64(self):
        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            (self.assets / f"slim-m-client-android-{abi}.apk").write_bytes(abi.encode())
        self.assertEqual(self.build().returncode, 0)
        arts = json.loads(self.manifest.read_text())["artifacts"]
        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            self.assertTrue(arts[f"android-{abi}"]["url"].endswith(f"/slim-m-client-android-{abi}.apk"))
        self.assertEqual(arts["android"], arts["android-arm64-v8a"])
        self.signed()
        self.assertEqual(self.verify("--dir", str(self.assets)).returncode, 0)

    def test_build_is_deterministic(self):
        self.build()
        first = self.manifest.read_bytes()
        self.build()
        self.assertEqual(first, self.manifest.read_bytes())

    def test_build_refuses_a_missing_required_platform(self):
        (self.assets / "slim-m-client-0.90.0-windows-x64.zip").unlink()
        done = self.build()
        self.assertEqual(done.returncode, 1)
        self.assertIn("windows-x64", done.stderr)

    def test_a_release_with_windows_and_linux_and_no_macos_zip_signs(self):
        (self.assets / "slim-m-client-0.90.0-macos.zip").unlink()
        self.signed()
        done = self.verify("--dir", self.assets)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("macos", done.stdout)

    def test_macos_is_listed_when_it_is_attached(self):
        self.assertEqual(self.build().returncode, 0)
        self.assertIn("macos", json.loads(self.manifest.read_text())["artifacts"])

    def test_build_from_producer_digests_matches_the_attached_assets(self):
        expected = self.record(*self.all_names())
        done = self.build("--expected", expected)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_swapped_release_asset_is_refused(self):
        expected = self.record(*self.all_names())
        (self.assets / "slim-m-client-0.90.0-windows-x64.zip").write_bytes(b"evil" * 10)
        done = self.build("--expected", expected)
        self.assertEqual(done.returncode, 1)
        self.assertIn("differs from the digest its producer recorded", done.stderr)
        self.assertFalse(self.manifest.exists())

    def test_a_swapped_asset_of_the_same_size_is_refused(self):
        expected = self.record(*self.all_names())
        (self.assets / "slim-m-client-0.90.0-linux-amd64.tar.gz").write_bytes(b"xyz")
        self.assertEqual(self.build("--expected", expected).returncode, 1)

    def test_an_asset_no_producer_recorded_is_refused(self):
        names = [n for n in self.all_names() if "macos" not in n]
        expected = self.record(*names)
        done = self.build("--expected", expected)
        self.assertEqual(done.returncode, 1)
        self.assertIn("no producer recorded", done.stderr)

    def test_build_needs_a_digest_source(self):
        done = run("build", "--tag", TAG, "--dir", self.assets, "--repo", "o/r", "--out", "manifest.json")
        self.assertEqual(done.returncode, 2)

    def dart_keys(self, *keys):
        body = "".join(f"  '{k}',\n" for k in keys)
        path = self.tmp / "update_keys.dart"
        path.write_text(f"/// keys\nconst trustedUpdateKeys = <String>[\n{body}];\n")
        return path

    def test_the_committed_client_keys_are_parsed(self):
        dart = REPO / "client/packages/app/lib/src/desktop/self_update/update_keys.dart"
        keys = update_manifest.client_keys(dart.read_text())
        self.assertTrue(keys)
        self.assertTrue(all(len(base64.b64decode(k)) == 32 for k in keys))

    def test_a_manifest_signed_with_a_client_key_verifies_against_the_dart_keys(self):
        self.signed()
        other = run("pubkey", key=new_key()).stdout.strip()
        dart = self.dart_keys(other, self.pub)
        done = run("verify", "--manifest", self.manifest, "--sig", self.sig, "--keys-dart", dart)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_manifest_signed_with_a_non_client_key_is_rejected(self):
        self.signed()
        client = run("pubkey", key=new_key()).stdout.strip()
        dart = self.dart_keys(client)
        done = run("verify", "--manifest", self.manifest, "--sig", self.sig, "--keys-dart", dart)
        self.assertEqual(done.returncode, 1)
        self.assertIn("does not match any key the client trusts", done.stderr)

    def test_build_tolerates_a_missing_optional_platform(self):
        (self.assets / "slim-m-client-0.90.0-linux-amd64.tar.gz").unlink()
        self.assertEqual(self.build("--require", "windows-x64,macos").returncode, 0)

    def test_the_default_requires_the_linux_tarball(self):
        (self.assets / "slim-m-client-0.90.0-linux-amd64.tar.gz").unlink()
        done = self.build()
        self.assertEqual(done.returncode, 1)
        self.assertIn("linux-x64", done.stderr)

    def test_defer_writes_nothing_and_succeeds_while_a_platform_is_missing(self):
        (self.assets / "slim-m-client-0.90.0-windows-x64.zip").unlink()
        done = self.build("--defer-if-missing")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("deferred", done.stdout)
        self.assertFalse(self.manifest.exists())

    def test_defer_still_builds_when_everything_is_attached(self):
        self.assertEqual(self.build("--defer-if-missing").returncode, 0)
        self.assertIn("linux-x64", json.loads(self.manifest.read_text())["artifacts"])

    def test_defer_does_not_swallow_a_bad_tag(self):
        done = run("build", "--tag", "v1", "--dir", self.assets, "--repo", "o/r",
                   "--out", "manifest.json", "--trust-release-assets", "--defer-if-missing")
        self.assertEqual(done.returncode, 1)

    def test_build_refuses_a_bad_tag(self):
        done = run("build", "--tag", "v1", "--dir", self.assets, "--repo", "o/r",
                   "--out", "manifest.json", "--trust-release-assets")
        self.assertEqual(done.returncode, 1)

    def test_signed_manifest_verifies_with_artifacts(self):
        self.signed()
        done = self.verify("--dir", self.assets)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("ok: 0.90.0", done.stdout)

    def test_pubkey_is_32_raw_bytes(self):
        self.assertEqual(len(base64.b64decode(self.pub)), 32)

    def test_tampered_manifest_is_rejected(self):
        self.signed()
        self.manifest.write_bytes(self.manifest.read_bytes().replace(b"0.90.0", b"0.99.0"))
        done = self.verify()
        self.assertEqual(done.returncode, 1)
        self.assertIn("signature", done.stderr)

    def test_wrong_public_key_is_rejected(self):
        self.signed()
        other = run("pubkey", key=new_key()).stdout.strip()
        self.assertEqual(self.verify(pub=other).returncode, 1)

    def test_corrupt_signature_is_rejected(self):
        self.signed()
        self.sig.write_text(base64.b64encode(b"\0" * 64).decode())
        self.assertEqual(self.verify().returncode, 1)

    def test_truncated_signature_is_rejected(self):
        self.signed()
        self.sig.write_text(base64.b64encode(b"\0" * 10).decode())
        self.assertEqual(self.verify().returncode, 1)

    def test_swapped_artifact_is_rejected(self):
        self.signed()
        (self.assets / "slim-m-client-0.90.0-macos.zip").write_bytes(b"evil" * 10)
        done = self.verify("--dir", self.assets)
        self.assertEqual(done.returncode, 1)
        self.assertIn("macos", done.stderr)

    def test_missing_artifact_is_rejected(self):
        self.signed()
        (self.assets / "slim-m-client-0.90.0-macos.zip").unlink()
        self.assertEqual(self.verify("--dir", self.assets).returncode, 1)

    def test_older_manifest_is_refused_as_a_rollback(self):
        self.signed()
        self.assertEqual(self.verify("--newer-than", "0.89.9").returncode, 0)
        self.assertEqual(self.verify("--newer-than", "0.90.0").returncode, 1)
        self.assertEqual(self.verify("--newer-than", "0.91.0").returncode, 1)

    def sign_custom(self, name):
        data = json.loads(self.manifest.read_text())
        data["artifacts"]["macos"]["url"] = "https://x/y/" + name
        self.manifest.write_text(json.dumps(data))
        done = run("sign", "--manifest", self.manifest, "--sig", "manifest.json.sig", key=self.key)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_unsafe_artifact_names_are_refused_without_reading_outside(self):
        self.build()
        outside = self.tmp / "x"
        outside.write_bytes(b"mac" * 10)
        for name in ("..", "%2e%2e", "a\\b", "x\0y"):
            self.sign_custom(name)
            done = self.verify("--dir", self.assets)
            self.assertEqual(done.returncode, 1, name)
            self.assertNotIn("Traceback", done.stderr)

    def test_absolute_and_traversal_names_are_refused(self):
        self.build()
        for name in ("/etc/passwd", "../x", "sub/../../x"):
            data = json.loads(self.manifest.read_text())
            data["artifacts"]["macos"]["url"] = "https://x/" + name
            self.manifest.write_text(json.dumps(data))
            run("sign", "--manifest", self.manifest, "--sig", "manifest.json.sig", key=self.key)
            done = self.verify("--dir", self.assets)
            self.assertEqual(done.returncode, 1, name)

    def test_traversal_name_is_rejected_by_the_name_check(self):
        spec = importlib.util.spec_from_file_location("um", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for name in ("../x", "/etc/passwd", "..", "", "a/b", "a\\b", "x\0y"):
            with self.assertRaises(mod.ManifestError, msg=name):
                mod.artifact_path(self.assets, name)
        self.assertIsNone(mod.artifact_path(self.assets, "ok.zip"))
        listed = mod.artifact_path(self.assets, "SHA256SUMS")
        self.assertEqual(listed.parent, self.assets.resolve())

    def test_signature_is_checked_before_any_artifact_is_touched(self):
        self.signed()
        data = json.loads(self.manifest.read_text())
        data["artifacts"]["macos"]["url"] = "https://x/../../etc/passwd"
        self.manifest.write_text(json.dumps(data))
        done = self.verify("--dir", self.assets)
        self.assertIn("signature", done.stderr)

    def test_non_regular_file_arguments_are_refused(self):
        self.signed()
        done = run("verify", "--manifest", self.tmp, "--sig", self.sig, "--pubkey", self.pub)
        self.assertEqual(done.returncode, 1)
        done = run("build", "--tag", TAG, "--dir", self.manifest, "--repo", "o/r",
                   "--trust-release-assets", "--out", self.tmp / "nodir" / "m.json")
        self.assertEqual(done.returncode, 1)

    def test_paths_with_directory_components_stay_inside_the_named_directory(self):
        self.signed()
        (self.tmp / "other").mkdir()
        wandering = self.tmp / "other" / ".." / "manifest.json"
        done = run("verify", "--manifest", wandering, "--sig", self.sig, "--pubkey", self.pub)
        self.assertEqual(done.returncode, 0, done.stderr)
        outside = self.tmp / "other" / ".." / ".." / "escaped-" / "m.json"
        done = self.build_to(outside)
        self.assertEqual(done.returncode, 1)
        self.assertFalse(outside.parent.exists())

    def test_output_names_outside_the_allowed_set_are_refused(self):
        before = sorted(p.name for p in self.tmp.iterdir())
        for name in ("has space.json", "semi;colon.json", "..", "other.json"):
            done = self.build_to(self.tmp / name)
            self.assertEqual(done.returncode, 1, name)
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), before)

    def build_to(self, out):
        return run("build", "--tag", TAG, "--dir", self.assets, "--repo", "o/r",
                   "--trust-release-assets", "--out", out)

    def test_sign_without_a_key_fails_cleanly(self):
        self.build()
        done = run("sign", "--manifest", self.manifest, "--sig", "manifest.json.sig")
        self.assertEqual(done.returncode, 1)
        self.assertIn("UPDATE_SIGNING_KEY", done.stderr)
        self.assertFalse(self.sig.exists())


if __name__ == "__main__":
    unittest.main()
